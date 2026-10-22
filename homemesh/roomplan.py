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
from .model import House, Opening, Prov, Room, Wall, WallCurve

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
    corners: list[tuple[float, float]] | None = None  # polygonCorners as (x, y) in the surface's frame
    curve: dict | None = None  # RoomPlan's curve: {radius, start, end} (radians)


def _corners(s: dict, w: float, h: float):
    raw = s.get("polygonCorners")
    if not isinstance(raw, list) or len(raw) < 3:
        return None
    try:
        pts = [(float(c[0]), float(c[1])) for c in raw]
    except (TypeError, ValueError, IndexError):
        return None
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    rect = len(pts) == 4 and abs((max(xs) - min(xs)) - w) < 0.05 and abs((max(ys) - min(ys)) - h) < 0.05 \
        and all(min(abs(p[0] - x) for x in (min(xs), max(xs))) < 0.05 and min(abs(p[1] - y) for y in (min(ys), max(ys))) < 0.05 for p in pts)
    return None if rect else pts


def _curve(s: dict):
    c = s.get("curve")
    if not isinstance(c, dict):
        return None
    try:
        r = float(c["radius"])
        a0, a1 = float(c.get("startAngle", 0.0)), float(c.get("endAngle", 0.0))
    except (KeyError, TypeError, ValueError):
        return None
    return {"radius": r, "start": a0, "end": a1} if r > 0 and abs(a1 - a0) > 1e-3 else None


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
                             t[3][:3].copy(), ax / n, dims[0], dims[1], _confidence(s.get("confidence")),
                             _corners(s, dims[0], dims[1]) if key == "walls" else None, _curve(s) if key == "walls" else None))
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
    profile: list[tuple[float, float]] | None = None  # (offset along a to b, height above `bottom`)
    curve: dict | None = None  # {group, cx, cy, radius, a0, a1} in capture plan coordinates


@dataclass
class Report:
    walls: int = 0
    paired_walls: int = 0
    openings: int = 0
    skipped_openings: int = 0
    rooms: int = 0
    replaced: int = 0
    curved_walls: int = 0   # curved walls approximated by chords
    profile_walls: int = 0  # walls kept with a non-rectangular outline
    folded_jogs: int = 0    # tiny jogs folded into their neighbours
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
                      abs(gap) if abs(gap) >= 0.05 else None, None, ws[i].curve or ws[j].curve))
        new = out[-1]
        src = ws[i] if ws[i].profile else ws[j]
        if src.profile:   # the outline of one face, re-measured along the merged wall
            su = (src.b - src.a) / np.linalg.norm(src.b - src.a)
            nu = (new.b - new.a) / np.linalg.norm(new.b - new.a)
            new.profile = [(float((src.a + su * x - new.a) @ nu), y + src.bottom - new.bottom) for x, y in src.profile]
    out += [w for k, w in enumerate(ws) if k not in used]
    return out


def _chords(s: _Surf, centroid: np.ndarray, a: np.ndarray, b: np.ndarray, bottom: float, top: float) -> list[_W] | None:
    """A curved wall as chords of about 0.5 m (at most 12). The chord a-b is the surface's width; the arc bulges away from
    the room's centre. None when the curve does not fit the chord."""
    r = s.curve["radius"] if s.curve else 0.0
    c = float(np.linalg.norm(b - a))
    if r <= c / 2 + 1e-6 or c < 0.2:
        return None
    mid, u = (a + b) / 2, (b - a) / c
    nrm = np.array([-u[1], u[0]])
    if float((mid - centroid) @ nrm) < 0:
        nrm = -nrm
    half = math.asin(c / 2 / r)
    centre = mid - nrm * math.sqrt(r * r - c * c / 4)
    a0 = math.atan2(*(a - centre)[::-1])
    a1 = math.atan2(*(b - centre)[::-1])
    sweep = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi   # the short way round
    n = max(2, min(12, math.ceil(r * abs(sweep) / 0.5)))
    pts = [centre + r * np.array([math.cos(a0 + sweep * k / n), math.sin(a0 + sweep * k / n)]) for k in range(n + 1)]
    group = s.ident[:8]
    cv = {"group": group, "cx": float(centre[0]), "cy": float(centre[1]), "radius": float(r),
          "a0": math.degrees(a0), "a1": math.degrees(a0 + sweep)}
    return [_W(pts[k], pts[k + 1], bottom, top, s.conf, [s.ident], None, None, cv) for k in range(n)] if half > 0 else None


def _scaled_profile(w: _W, sim: Similarity2D):
    if not w.profile:
        return None
    length = float(np.linalg.norm(w.b - w.a))
    height = w.top - w.bottom
    pts = [(round(min(length, max(0.0, x)) * sim.scale, 3), round(min(height, max(0.0, y)) * sim.scale, 3)) for x, y in w.profile]
    return pts if len(pts) >= 3 else None


def _fold_jogs(ws: list[_W], thr: float) -> tuple[list[_W], int]:
    """Fold walls shorter than `thr` that sit between two other walls into those walls: the neighbours meet at the
    intersection of their lines when it is within twice the jog of the jog's ends, else at the jog's midpoint."""
    ws = list(ws)
    folded = 0
    tol = 0.06
    changed = True
    while changed and thr > 0:
        changed = False
        for si, sw in enumerate(ws):
            if sw.curve is not None or float(np.linalg.norm(sw.b - sw.a)) >= thr:
                continue
            near_a = [(k, 0) if float(np.linalg.norm(w.a - sw.a)) < tol else (k, 1) for k, w in enumerate(ws)
                      if k != si and (float(np.linalg.norm(w.a - sw.a)) < tol or float(np.linalg.norm(w.b - sw.a)) < tol)]
            near_b = [(k, 0) if float(np.linalg.norm(w.a - sw.b)) < tol else (k, 1) for k, w in enumerate(ws)
                      if k != si and (float(np.linalg.norm(w.a - sw.b)) < tol or float(np.linalg.norm(w.b - sw.b)) < tol)]
            if len(near_a) != 1 or len(near_b) != 1 or near_a[0][0] == near_b[0][0]:
                continue
            (ka, ea), (kb, eb) = near_a[0], near_b[0]
            A, B = ws[ka], ws[kb]
            if A.curve is not None or B.curve is not None:
                continue
            mid = (sw.a + sw.b) / 2
            j = mid
            da, db = A.b - A.a, B.b - B.a
            den = da[0] * db[1] - da[1] * db[0]
            if abs(den) > 1e-6 * float(np.linalg.norm(da) * np.linalg.norm(db)):
                t = ((B.a[0] - A.a[0]) * db[1] - (B.a[1] - A.a[1]) * db[0]) / den
                p = A.a + da * t
                if float(np.linalg.norm(p - mid)) <= 2 * thr + float(np.linalg.norm(sw.b - sw.a)):
                    j = p
            if ea == 0:
                A.a = j.copy()
            else:
                A.b = j.copy()
            if eb == 0:
                B.a = j.copy()
            else:
                B.b = j.copy()
            A.ids = A.ids + sw.ids
            A.profile = B.profile = None   # their ends moved: the outline no longer fits
            ws.pop(si)
            folded += 1
            changed = True
            break
    return ws, folded


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
            out.append({"room": i, "polygon": [[round(x, 4), round(y, 4)] for x, y in poly], "rise": round(h, 3), "width": round(w, 3), "run": round(d, 3)})
    return out


def scan_footprint(data: dict, sim: Similarity2D | None = None) -> list[list[float]]:
    """The convex hull of all the scan's wall ends in plan coordinates: a staircase's footprint when RoomPlan found no
    stairs object in a scan made for the stairs."""
    sim = sim or Similarity2D()
    ends = []
    for r in _rooms(data):
        for sf in _surfaces(r):
            if sf.kind == "wall":
                half = sf.axis * sf.w / 2
                ends += [sim.apply(tuple(map(float, _plan(sf.centre - half)))), sim.apply(tuple(map(float, _plan(sf.centre + half))))]
    return [[round(x, 4), round(y, 4)] for x, y in _hull(ends)]


def apply_stair(house: House, data: dict, blob: str, meta: dict, sim: Similarity2D | None, found: list[dict], notes: list[str]) -> House:
    """The staircase the owner said this scan holds (`meta["stair"]` = from/to floors), added to `house` as a Stair
    (replacing the one an earlier import of this scan made). Its footprint is the biggest stairs object RoomPlan found
    (`found`, already in placed coordinates), else, for a scan made for the stairs, the scan's footprint. The measured
    rise refines the floor-to-floor height."""
    from . import stack
    from .model import Stair
    st = meta.get("stair")
    if not st:
        return house
    ids = {lv.id for lv in house.levels}
    a, b = st.get("from_level"), st.get("to_level")
    if a not in ids or b not in ids or a == b:
        return house
    rise = None
    if found:
        best = max(found, key=lambda f: f.get("width", 0) * f.get("run", 0))
        poly, rise = best["polygon"], best.get("rise")
        notes.append(f"staircase from the stairs object RoomPlan found (rises {rise:.2f} m)")
    elif meta.get("purpose") == "stairs":
        poly = scan_footprint(data, sim)
        notes.append("RoomPlan found no stairs object in this scan: the scan's footprint is used as the staircase")
    else:
        return house
    if len(poly) < 3:
        return house
    keep = [s for s in house.stairs if not (s.prov.ref or "").startswith(f"{blob}#stair")]
    n = len(keep)
    while f"s{n + 1}" in {s.id for s in keep}:
        n += 1
    new = Stair(id=f"s{n + 1}", from_level=a, to_level=b, polygon=[tuple(p) for p in poly], void=True, prov=Prov(source="scan", ref=f"{blob}#stair"))
    house = house.model_copy(update={"stairs": [*keep, new]})
    return stack.with_rise(house, a, b, rise) if rise else house


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
                   descriptions: list[str] | None = None, make_rooms: bool = True) -> tuple[House, Report]:
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
    for r in _rooms(data):   # per room: a curved wall bulges away from its own room's centre
        rs = [s for s in _surfaces(r) if s.kind == "wall"]
        cen = np.mean([_plan(s.centre) for s in rs], axis=0) if rs else np.zeros(2)
        for s in rs:
            half = s.axis * s.w / 2
            a, b = _plan(s.centre - half), _plan(s.centre + half)
            bottom, top = float(s.centre[1] - s.h / 2), float(s.centre[1] + s.h / 2)
            chords = _chords(s, cen, a, b, bottom, top) if s.curve else None
            if chords:
                raw += chords
                rep.curved_walls += 1
                continue
            w = _W(a, b, bottom, top, s.conf, [s.ident])
            if s.corners:
                w.profile = [(min(s.w, max(0.0, x + s.w / 2)), min(s.h, max(0.0, y + s.h / 2))) for x, y in s.corners]
                rep.profile_walls += 1
            raw.append(w)
    floor_y = min(w.bottom for w in raw)  # the lowest wall base is this level's floor
    merged = _merge(raw, defaults)
    rep.paired_walls = sum(1 for w in merged if len(w.ids) > 1)
    merged, rep.folded_jogs = _fold_jogs(merged, house.jog_fold)

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
                        profile=_scaled_profile(w, sim),
                        curve=WallCurve(group=w.curve["group"], cx=round(sim.apply((w.curve["cx"], w.curve["cy"]))[0], 4),
                                        cy=round(sim.apply((w.curve["cx"], w.curve["cy"]))[1], 4), radius=round(w.curve["radius"] * sim.scale, 4),
                                        a0=round(w.curve["a0"] + sim.rotation, 3), a1=round(w.curve["a1"] + sim.rotation, 3)) if w.curve else None,
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
    for i, r in enumerate(_rooms(data) if make_rooms else []):
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
