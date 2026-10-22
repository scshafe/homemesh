"""RoomPlan import (design section 10.1).

Reads the JSON Apple's `CapturedRoom` / `CapturedStructure` encode (and the
wrapper the capture app sends: {"format": "homemesh-capture-1", "rooms": [...]}).
Only geometry is read; the USDZ stays a blob for display.

Facts about the input this module relies on (verify against Apple's current
documentation if a new OS release changes them): surfaces carry `dimensions`
(width, height, depth; depth is 0 for walls) and a 4x4 `transform` in ARKit's
world frame (Y up, metres, column-major: columns 0/1 are the surface's
right/up axes, column 3 its centre), a `category` keyed by kind, and a
`confidence` of low/medium/high.

What a scan does NOT give: wall thickness and material. Walls get the class
defaults (`Defaults`), flagged `thickness_defaulted` / `material_defaulted`, and
the owner (or a blueprint) supplies the truth.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .materials import default_materials
from .model import House, Opening, Prov, Room, Wall

PARALLEL_SIN = math.sin(math.radians(3.0))
CONF = {"low": 0.4, "medium": 0.7, "high": 0.95}


class ImportError_(ValueError):
    pass


@dataclass(frozen=True)
class Defaults:
    thickness: float = 0.1
    material: str = "drywall"
    merge_max_gap: float = 0.6  # two parallel surfaces closer than this are the two faces of one wall
    merge_min_overlap: float = 0.3


@dataclass
class Similarity2D:
    """p' = scale * R(rotation) p + translation (plan metres, rotation in degrees)."""

    scale: float = 1.0
    rotation: float = 0.0
    tx: float = 0.0
    ty: float = 0.0

    def apply(self, p: tuple[float, float]) -> tuple[float, float]:
        c, s = math.cos(math.radians(self.rotation)), math.sin(math.radians(self.rotation))
        return (self.scale * (c * p[0] - s * p[1]) + self.tx, self.scale * (s * p[0] + c * p[1]) + self.ty)


def register(src: list[tuple[float, float]], dst: list[tuple[float, float]], allow_scale: bool = False) -> Similarity2D:
    """Least-squares similarity (Umeyama) taking `src` points onto `dst` (two or more pairs).
    The scale is held at 1 unless `allow_scale`: scans are metric, a scale is a sign of a bad pick."""
    if len(src) != len(dst) or len(src) < 2:
        raise ImportError_("registration needs at least two matching point pairs")
    A, B = np.array(src, float), np.array(dst, float)
    ca, cb = A.mean(axis=0), B.mean(axis=0)
    a, b = A - ca, B - cb
    if float((a**2).sum()) < 1e-12:
        raise ImportError_("the picked points coincide")
    U, S, Vt = np.linalg.svd(b.T @ a)
    d = np.sign(np.linalg.det(U @ Vt)) or 1.0
    R = U @ np.diag([1.0, d]) @ Vt
    scale = float((S * [1.0, d]).sum() / (a**2).sum()) if allow_scale else 1.0
    t = cb - scale * R @ ca
    return Similarity2D(scale, math.degrees(math.atan2(R[1, 0], R[0, 0])), float(t[0]), float(t[1]))


def registration_error(src, dst, sim: Similarity2D) -> float:
    """Largest distance, metres, between a mapped source point and its target."""
    return max(math.hypot(*(np.array(sim.apply(tuple(s))) - np.array(d))) for s, d in zip(src, dst))


# --- parsing -----------------------------------------------------------------------

def _transform(t: Any) -> np.ndarray:
    """Columns as a (4, 4) array whose rows are the columns of the encoded matrix."""
    arr = np.array(t, dtype=float)
    if arr.shape == (16,):
        return arr.reshape(4, 4)
    if arr.shape == (4, 4):
        return arr
    raise ImportError_("unreadable transform")


def _kind(category: Any) -> tuple[str, dict]:
    if isinstance(category, str):
        return category, {}
    if isinstance(category, dict) and len(category) == 1:
        k, v = next(iter(category.items()))
        return k, v if isinstance(v, dict) else {}
    raise ImportError_("unreadable category")


def _confidence(c: Any) -> float:
    key = c if isinstance(c, str) else next(iter(c), "high") if isinstance(c, dict) and c else "high"
    return CONF.get(str(key), 0.7)


@dataclass
class _Surf:
    ident: str
    parent: str | None
    kind: str
    opts: dict
    centre: np.ndarray  # ARKit world (x, y, z)
    axis: np.ndarray  # unit vector along the surface's width, ARKit world
    w: float
    h: float
    conf: float


def _surfaces(room: dict) -> list[_Surf]:
    out = []
    for key in ("walls", "doors", "windows", "openings"):
        for i, s in enumerate(room.get(key, []) or []):
            try:
                t = _transform(s["transform"])
                dims = [float(x) for x in s["dimensions"]]
                kind, opts = _kind(s.get("category", key[:-1]))
            except (KeyError, TypeError, ValueError) as e:
                raise ImportError_(f"{key}[{i}]: {e}") from None
            ax = t[0][:3]
            n = float(np.linalg.norm(ax))
            if n < 1e-6 or dims[0] <= 0 or dims[1] <= 0:
                continue
            out.append(_Surf(str(s.get("identifier", f"{key}{i}")), s.get("parentIdentifier"), kind, opts,
                             t[3][:3].copy(), ax / n, dims[0], dims[1], _confidence(s.get("confidence"))))
    return out


def _plan(p: np.ndarray) -> np.ndarray:
    """ARKit (x, y up, z) to plan (x, y): X = x, Y = -z."""
    return np.array([p[0], -p[2]])


@dataclass
class _W:
    a: np.ndarray
    b: np.ndarray
    bottom: float
    top: float
    conf: float
    ids: list[str]
    thickness: float | None = None


@dataclass
class Report:
    walls: int = 0
    paired_walls: int = 0
    openings: int = 0
    skipped_openings: int = 0
    rooms: int = 0
    replaced: int = 0
    stairs: list = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def _merge(ws: list[_W], d: Defaults) -> list[_W]:
    used: set[int] = set()
    pairs = []
    for i in range(len(ws)):
        for j in range(i + 1, len(ws)):
            ui = (ws[i].b - ws[i].a); li = float(np.linalg.norm(ui))
            uj = (ws[j].b - ws[j].a); lj = float(np.linalg.norm(uj))
            if li < 1e-6 or lj < 1e-6:
                continue
            ui, uj = ui / li, uj / lj
            if abs(ui[0] * uj[1] - ui[1] * uj[0]) > PARALLEL_SIN:
                continue
            gap = float(ui[0] * (ws[j].a[1] - ws[i].a[1]) - ui[1] * (ws[j].a[0] - ws[i].a[0]))
            if abs(gap) > d.merge_max_gap:
                continue
            ti = [float((p - ws[i].a) @ ui) for p in (ws[j].a, ws[j].b)]
            overlap = min(li, max(ti)) - max(0.0, min(ti))
            if overlap >= d.merge_min_overlap and overlap >= 0.5 * min(li, lj):
                pairs.append((overlap, i, j, gap))
    out: list[_W] = []
    for overlap, i, j, gap in sorted(pairs, key=lambda t: -t[0]):
        if i in used or j in used:
            continue
        used |= {i, j}
        ui = (ws[i].b - ws[i].a) / np.linalg.norm(ws[i].b - ws[i].a)
        n = np.array([-ui[1], ui[0]]) * gap  # from line i to line j
        pts = [float((p - ws[i].a) @ ui) for p in (ws[i].a, ws[i].b, ws[j].a, ws[j].b)]
        lo, hi = min(pts), max(pts)
        out.append(_W(ws[i].a + ui * lo + n / 2, ws[i].a + ui * hi + n / 2, min(ws[i].bottom, ws[j].bottom),
                      max(ws[i].top, ws[j].top), min(ws[i].conf, ws[j].conf), ws[i].ids + ws[j].ids,
                      abs(gap) if abs(gap) >= 0.05 else None))
    out += [w for k, w in enumerate(ws) if k not in used]
    return out


def _rooms(data: dict) -> list[dict]:
    if isinstance(data.get("rooms"), list):
        return [r for r in data["rooms"] if isinstance(r, dict)]
    if "walls" in data:
        return [data]
    raise ImportError_("no walls in the capture")


def stair_footprints(data: dict, sim: Similarity2D | None = None) -> list[dict]:
    """Stairs objects RoomPlan found, as plan rectangles: [{"room": index, "polygon": [[x, y] x4], "rise": height m}].
    The footprint is the object's width by depth; `rise` is its height (what RoomPlan measured of the flight)."""
    sim = sim or Similarity2D()
    out = []
    for i, room in enumerate(_rooms(data)):
        for obj in room.get("objects", []) or []:
            try:
                kind, _ = _kind(obj.get("category"))
                if kind != "stairs":
                    continue
                t = _transform(obj["transform"])
                w, h, d = (float(x) for x in obj["dimensions"])
            except (KeyError, TypeError, ValueError, ImportError_):
                continue
            a0, a2 = t[0][:3], t[2][:3]
            n0, n2 = float(np.linalg.norm(a0)), float(np.linalg.norm(a2))
            if n0 < 1e-6 or n2 < 1e-6 or w <= 0 or d <= 0:
                continue
            a0, a2, c = a0 / n0, a2 / n2, t[3][:3]
            corners = [c + a0 * sx * w / 2 + a2 * sz * d / 2 for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
            poly = [sim.apply(tuple(map(float, _plan(p)))) for p in corners]
            out.append({"room": i, "polygon": [[round(x, 4), round(y, 4)] for x, y in poly], "rise": round(h, 3)})
    return out


def retire_room(house: House, data: dict, blob: str, index: int) -> tuple[House, int]:
    """`house` without room `index` of the earlier import of capture `blob` (`data`): its room, and the walls (with
    their openings) whose source surfaces all belong to that room. A wall paired with a face of another room of the
    same scan, or from another scan, is kept. Returns the house and the number of walls removed."""
    rooms = _rooms(data)
    if not 0 <= index < len(rooms):
        return house, 0
    own = {sf.ident[:8] for sf in _surfaces(rooms[index]) if sf.kind == "wall"}
    prefix = f"{blob}#wall/"
    keep, gone = [], 0
    for w in house.walls:
        ref = w.prov.ref or ""
        if ref.startswith(prefix) and set(ref[len(prefix):].split("+")) <= own:
            gone += 1
        else:
            keep.append(w)
    rest = [r for r in house.rooms if (r.prov.ref or "") != f"{blob}#room/{index}"]
    return house.model_copy(update={"walls": keep, "rooms": rest}), gone


def room_names(data: dict) -> list[str]:
    """The names carried by the capture itself (the app's wrapper puts `name` on each room), "" where none."""
    return [str(r.get("name") or "").strip()[:80] for r in _rooms(data)]


def _hull(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def half(seq):
        out: list[tuple[float, float]] = []
        for p in seq:
            while len(out) >= 2 and (out[-1][0] - out[-2][0]) * (p[1] - out[-2][1]) - (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0]) <= 0:
                out.pop()
            out.append(p)
        return out[:-1]

    return half(pts) + half(reversed(pts))


def _area(poly: list[tuple[float, float]]) -> float:
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1]))) / 2


def import_capture(house: House, data: dict, level: str, blob: str, transform: Similarity2D | None = None,
                   defaults: Defaults = Defaults(), names: list[str] | None = None,
                   descriptions: list[str] | None = None) -> tuple[House, Report]:
    """A copy of `house` with the scan's walls and openings on `level`.

    Importing the same blob again replaces what it added before (walls whose
    provenance ref starts with the blob id); everything else is left alone.
    """
    if level not in {lv.id for lv in house.levels}:
        raise ImportError_(f"unknown level {level}")
    rep = Report()
    surfaces = [s for r in _rooms(data) for s in _surfaces(r)]
    walls_s = [s for s in surfaces if s.kind == "wall"]
    if not walls_s:
        raise ImportError_("the capture has no walls")
    sim = transform or Similarity2D()

    raw: list[_W] = []
    for s in walls_s:
        half = s.axis * s.w / 2
        raw.append(_W(_plan(s.centre - half), _plan(s.centre + half), float(s.centre[1] - s.h / 2), float(s.centre[1] + s.h / 2),
                      s.conf, [s.ident]))
    floor_y = min(w.bottom for w in raw)  # the lowest wall base is this level's floor
    merged = _merge(raw, defaults)
    rep.paired_walls = sum(1 for w in merged if len(w.ids) > 1)

    mats = {m.id for m in house.materials}
    extra = [m for m in default_materials() if m.id not in mats and m.id in {defaults.material, "wood-door", "glass"}]
    houses_mats = [*house.materials, *extra]

    kept = [w for w in house.walls if not (w.prov.ref or "").startswith(f"{blob}#")]
    rep.replaced = len(house.walls) - len(kept)
    taken = {w.id for w in kept}
    new: list[Wall] = []
    n = 0
    for w in sorted(merged, key=lambda w: (round(w.a[0], 2), round(w.a[1], 2))):
        while f"w{n + 1}" in taken:
            n += 1
        n += 1
        taken.add(f"w{n}")
        a, b = sim.apply((float(w.a[0]), float(w.a[1]))), sim.apply((float(w.b[0]), float(w.b[1])))
        new.append(Wall(id=f"w{n}", level=level, a=(round(a[0], 4), round(a[1], 4)), b=(round(b[0], 4), round(b[1], 4)),
                        thickness=round(w.thickness * sim.scale, 3) if w.thickness else defaults.thickness,
                        height=round((w.top - w.bottom) * sim.scale, 3), base_z=round(max(0.0, (w.bottom - floor_y) * sim.scale), 3),
                        material=defaults.material, thickness_defaulted=w.thickness is None, material_defaulted=True,
                        prov=Prov(source="scan", ref=f"{blob}#wall/{'+'.join(i[:8] for i in w.ids)}", confidence=w.conf)))
    rep.walls = len(new)

    # doors, windows and openings land on the nearest wall; the same door seen from two rooms is kept once
    kind_map = {"door": ("door", "wood-door"), "window": ("window", "glass"), "opening": ("arch", "air")}
    for s in surfaces:
        if s.kind not in kind_map:
            continue
        c = np.array(sim.apply(tuple(map(float, _plan(s.centre)))))
        best, bd, along = None, 0.45, 0.0
        for w in new:
            ex, ey = w.b[0] - w.a[0], w.b[1] - w.a[1]
            ln = math.hypot(ex, ey)
            t = ((c[0] - w.a[0]) * ex + (c[1] - w.a[1]) * ey) / ln
            dist = abs((c[0] - w.a[0]) * ey - (c[1] - w.a[1]) * ex) / ln
            if 0 <= t <= ln and dist < bd:
                best, bd, along = w, dist, t
        if best is None:
            rep.skipped_openings += 1
            continue
        kind, mat = kind_map[s.kind]
        width, height = s.w * sim.scale, s.h * sim.scale
        wl = math.hypot(best.b[0] - best.a[0], best.b[1] - best.a[1])
        if width > wl:
            rep.skipped_openings += 1
            continue
        offset = min(wl - width, max(0.0, along - width / 2))
        if any(offset < o.offset + o.width and o.offset < offset + width for o in best.openings):
            rep.skipped_openings += 1
            continue
        sill = max(0.0, (float(s.centre[1]) - s.h / 2 - floor_y) * sim.scale - best.base_z)
        best.openings.append(Opening(kind=kind, offset=round(offset, 3), width=round(width, 3), height=round(height, 3), sill=round(sill, 3),
                                     material=mat, state="open" if s.opts.get("isOpen") else "closed",
                                     prov=Prov(source="scan", ref=f"{blob}#{s.kind}/{s.ident[:8]}", confidence=s.conf)))
        rep.openings += 1

    # one Room per scanned room: the outline is the convex hull of its wall ends (an L-shaped room gets
    # its hull until a floor outline is imported), named by the owner (`names`), else by the capture, else "Room N"
    kept_rooms = [r for r in house.rooms if not (r.prov.ref or "").startswith(f"{blob}#")]
    taken_r = {r.id for r in kept_rooms}
    new_rooms: list[Room] = []
    carried = room_names(data)
    n = 0
    for i, r in enumerate(_rooms(data)):
        ends = []
        for sf in _surfaces(r):
            if sf.kind == "wall":
                half = sf.axis * sf.w / 2
                ends += [sim.apply(tuple(map(float, _plan(sf.centre - half)))), sim.apply(tuple(map(float, _plan(sf.centre + half))))]
        poly = _hull(ends)
        if len(poly) < 3 or _area(poly) < 0.5:
            continue
        while f"r{n + 1}" in taken_r:
            n += 1
        n += 1
        taken_r.add(f"r{n}")
        label = (names[i] if names and i < len(names) and names[i].strip() else carried[i]) or f"Room {i + 1}"
        about = (descriptions[i] if descriptions and i < len(descriptions) else "").strip()[:500]
        new_rooms.append(Room(id=f"r{n}", level=level, name=label.strip()[:80], description=about, polygon=[(round(x, 4), round(y, 4)) for x, y in poly],
                              prov=Prov(source="scan", ref=f"{blob}#room/{i}")))
    rep.rooms = len(new_rooms)
    rep.stairs = [{**st, "level": level} for st in stair_footprints(data, sim)]

    rep.notes.append("thickness and material are not measured by a scan: walls carry the class defaults until you set them")
    return house.model_copy(update={"walls": kept + new, "rooms": kept_rooms + new_rooms, "materials": houses_mats}), rep
