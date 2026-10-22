"""Automatic placement of a scan on the plan (docs/design-ios-app.md, section 4).

A scan arrives in its own frame. Given the walls, openings and rooms already on a level, propose the
rigid 2D transform (yaw and translation; scans are metric so scale is 1) that puts it where it belongs.
Deterministic: candidates come from matching doorways and equal room names, are scored on how much of the
scan lies on existing walls, how many openings coincide, and how little the rooms overlap, and ties break
on a fixed order. Nothing is stored; the caller shows the proposal and imports with the accepted transform.

Two scans of the two sides of one wall see its opposite faces, so along the wall's normal a placement is
good to about one wall thickness; the import merges the two faces into one wall afterwards.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

import numpy as np

from .model import House, Room, Wall
from .roomplan import ImportError_, Similarity2D, import_capture, register, retire_room, room_names, scan_doors, stair_footprints

# Weights of the score; tests pin their effect, not their values.
W_WALL = 1.0       # per metre of scan wall lying on a parallel plan wall
W_OPENING = 3.0    # per scan opening coinciding with a plan opening
W_STAIR = 5.0      # per scan staircase on a staircase already joining this floor
W_NAME = 4.0       # per equal-named room pair whose centres coincide
W_AREA = 6.0       # per square metre of scan room inside a plan room
W_CROSS = 2.0      # per metre of scan wall crossing the inside of a plan room

WALL_TOL = 0.12          # m, normal distance for "lies on"
ANGLE_TOL = math.radians(4)
OPENING_TOL = 0.30       # m between midpoints
WIDTH_TOL = 0.15         # m between widths for a doorway pair
INSET = 0.25             # m kept clear of room edges when testing overlap
SAMPLE = 0.1             # m between samples along walls
DISTINCT_M, DISTINCT_DEG = 0.5, 10.0


@dataclass
class Opening2:
    mid: np.ndarray
    angle: float
    width: float
    kind: str  # "door" (door, arch, opening) or "window"
    ref: str = ""  # "<capture>#door/<id8>" of the surface it was scanned from
    thickness: float = 0.1  # of the wall it is in


@dataclass
class Candidate:
    rotation: float  # degrees
    tx: float
    ty: float
    source: str
    score: float = 0.0
    openings: int = 0
    names: int = 0
    stairs: int = 0
    wall_m: float = 0.0
    area_m2: float = 0.0

    def sim(self) -> Similarity2D:
        return Similarity2D(1.0, self.rotation, self.tx, self.ty)


def _rot(deg: float) -> np.ndarray:
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return np.array([[c, -s], [s, c]])


def _openings(walls: list[Wall]) -> list[Opening2]:
    out = []
    for w in walls:
        a, b = np.array(w.a, float), np.array(w.b, float)
        ln = float(np.linalg.norm(b - a))
        if ln < 1e-6:
            continue
        d = (b - a) / ln
        for o in w.openings:
            if o.kind == "hole":
                continue
            out.append(Opening2(a + d * (o.offset + o.width / 2), math.atan2(d[1], d[0]), o.width, "window" if o.kind == "window" else "door",
                                o.prov.ref or "", w.thickness))
    return out


def _samples(walls: list[Wall]) -> list[tuple[np.ndarray, float]]:
    """Points along the walls with the wall's angle (mod pi)."""
    out = []
    for w in walls:
        a, b = np.array(w.a, float), np.array(w.b, float)
        ln = float(np.linalg.norm(b - a))
        if ln < 1e-6:
            continue
        ang = math.atan2(b[1] - a[1], b[0] - a[0]) % math.pi
        n = max(1, int(ln / SAMPLE))
        for i in range(n):
            out.append((a + (b - a) * ((i + 0.5) / n), ang))
    return out


def _dist_to_wall(p: np.ndarray, w: Wall) -> float:
    a, b = np.array(w.a, float), np.array(w.b, float)
    ab = b - a
    t = float(np.clip(np.dot(p - a, ab) / max(float(ab @ ab), 1e-12), 0, 1))
    return float(np.linalg.norm(p - (a + t * ab)))


def _inside(p: np.ndarray, poly: np.ndarray) -> bool:
    x, y = p
    inside = False
    for i in range(len(poly)):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % len(poly)]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def _edge_dist(p: np.ndarray, poly: np.ndarray) -> float:
    best = math.inf
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        ab = b - a
        t = float(np.clip(np.dot(p - a, ab) / max(float(ab @ ab), 1e-12), 0, 1))
        best = min(best, float(np.linalg.norm(p - (a + t * ab))))
    return best


def _deep_inside(p: np.ndarray, poly: np.ndarray, margin: float) -> bool:
    return _inside(p, poly) and _edge_dist(p, poly) > margin


_DEFAULT_NAME = re.compile(r"^room \d+$")


def _fold(name: str) -> str:
    """Names compare case- and space-folded; the importer's placeholder "Room N" is not a name the owner gave."""
    f = " ".join(name.lower().split())
    return "" if _DEFAULT_NAME.match(f) else f


def _longest_angle(poly: np.ndarray) -> float:
    best, ang = -1.0, 0.0
    for i in range(len(poly)):
        d = poly[(i + 1) % len(poly)] - poly[i]
        ln = float(np.linalg.norm(d))
        if ln > best:
            best, ang = ln, math.atan2(d[1], d[0])
    return ang


def _dominant(walls: list[Wall]) -> float | None:
    """Length-weighted dominant wall direction, radians in [0, pi/2)."""
    if not walls:
        return None
    z = sum(w.length * np.exp(4j * math.atan2(w.b[1] - w.a[1], w.b[0] - w.a[0])) for w in walls if w.length > 0)
    return (math.atan2(z.imag, z.real) / 4) % (math.pi / 2)


def _transform_walls(walls: list[Wall], sim: Similarity2D) -> list[Wall]:
    return [w.model_copy(update={"a": sim.apply(w.a), "b": sim.apply(w.b)}) for w in walls]


MAX_FULL = 60   # candidates scored in full; the rest are ranked by their cheap evidence (coinciding openings, names)


def _seg_points(walls: list[Wall]) -> tuple[np.ndarray, np.ndarray]:
    """Points along the walls every SAMPLE metres and each one's wall angle (mod pi), as arrays."""
    pts, angs = [], []
    for w in walls:
        a, b = np.array(w.a, float), np.array(w.b, float)
        ln = float(np.linalg.norm(b - a))
        if ln < 1e-6:
            continue
        n = max(1, int(ln / SAMPLE))
        t = (np.arange(n) + 0.5) / n
        pts.append(a + (b - a) * t[:, None])
        angs.append(np.full(n, math.atan2(b[1] - a[1], b[0] - a[0]) % math.pi))
    if not pts:
        return np.zeros((0, 2)), np.zeros(0)
    return np.vstack(pts), np.concatenate(angs)


@dataclass
class _Ctx:
    """What does not change from one candidate to the next, computed once per proposal."""
    scan_pts: np.ndarray
    scan_ang: np.ndarray
    plan_a: np.ndarray
    plan_ab: np.ndarray
    plan_len2: np.ndarray
    plan_ang: np.ndarray

    @staticmethod
    def build(scan_walls: list[Wall], plan_walls: list[Wall]) -> "_Ctx":
        pts, ang = _seg_points(scan_walls)
        a = np.array([w.a for w in plan_walls], float).reshape(-1, 2)
        b = np.array([w.b for w in plan_walls], float).reshape(-1, 2)
        ab = b - a
        pa = np.array([math.atan2(d[1], d[0]) % math.pi for d in ab]) if len(ab) else np.zeros(0)
        return _Ctx(pts, ang, a, ab, np.maximum((ab * ab).sum(axis=1), 1e-12), pa)


def _inside_many(P: np.ndarray, poly: np.ndarray) -> np.ndarray:
    x, y = P[:, 0][:, None], P[:, 1][:, None]
    x1, y1 = poly[:, 0][None], poly[:, 1][None]
    x2, y2 = np.roll(poly[:, 0], -1)[None], np.roll(poly[:, 1], -1)[None]
    with np.errstate(divide="ignore", invalid="ignore"):
        crosses = ((y1 > y) != (y2 > y)) & (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1)
    return (crosses.sum(axis=1) % 2).astype(bool)


def _edge_dist_many(P: np.ndarray, poly: np.ndarray) -> np.ndarray:
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = (b - a)[None]
    ap = P[:, None, :] - a[None]
    t = np.clip((ap * ab).sum(axis=2) / np.maximum((ab * ab).sum(axis=2), 1e-12), 0, 1)
    d = ap - t[..., None] * ab
    return np.sqrt((d * d).sum(axis=2)).min(axis=1)


def _deep_many(P: np.ndarray, poly: np.ndarray, margin: float) -> np.ndarray:
    """Which points are inside `poly` by more than `margin`. Points outside its bounding box are skipped."""
    out = np.zeros(len(P), bool)
    if not len(P):
        return out
    lo, hi = poly.min(axis=0), poly.max(axis=0)
    near = np.all((P >= lo) & (P <= hi), axis=1)
    if near.any():
        Q = P[near]
        out[near] = _inside_many(Q, poly) & (_edge_dist_many(Q, poly) > margin)
    return out


def _score(c: Candidate, ctx: _Ctx, scan_open, scan_rooms, plan_open, plan_rooms,
           scan_stairs=(), plan_stairs=()) -> None:
    R = _rot(c.rotation)
    t = np.array([c.tx, c.ty])
    P = ctx.scan_pts @ R.T + t
    ang = (ctx.scan_ang + math.radians(c.rotation)) % math.pi
    # walls lying on parallel plan walls, and walls crossing plan rooms
    covered = crossing = 0
    same = {_fold(n) for n, _ in scan_rooms} - {""}  # a room scanned again lies on top of itself: not an overlap
    solid = [poly for n, poly in plan_rooms if _fold(n) not in same]
    if len(P) and len(ctx.plan_a):
        keep = np.all((ctx.plan_a + np.minimum(ctx.plan_ab, 0) <= P.max(axis=0) + WALL_TOL) &
                      (ctx.plan_a + np.maximum(ctx.plan_ab, 0) >= P.min(axis=0) - WALL_TOL), axis=1)   # walls near the scan at all
        if keep.any():
            A, AB, L2, PA = ctx.plan_a[keep], ctx.plan_ab[keep], ctx.plan_len2[keep], ctx.plan_ang[keep]
            ap = P[:, None, :] - A[None]
            tt = np.clip((ap * AB[None]).sum(axis=2) / L2[None], 0, 1)
            d = ap - tt[..., None] * AB[None]
            dist = np.sqrt((d * d).sum(axis=2))
            dq = np.abs(ang[:, None] - PA[None])
            parallel = np.minimum(dq, math.pi - dq) <= ANGLE_TOL
            covered = int(((dist <= WALL_TOL) & parallel).any(axis=1).sum())
    if len(P):
        inside = np.zeros(len(P), bool)
        for poly in solid:
            inside |= _deep_many(P, poly, INSET)
        crossing = int(inside.sum())
    c.wall_m = covered * SAMPLE
    # coinciding openings
    c.openings = _open_matches(R, t, scan_open, plan_open)
    # equal names with coinciding centres, and room overlap
    c.names = 0
    c.area_m2 = 0.0
    for name, poly in scan_rooms:
        tp = (R @ poly.T).T + t
        centre = tp.mean(axis=0)
        for pname, ppoly in plan_rooms:
            if _fold(name) and _fold(name) == _fold(pname) and float(np.linalg.norm(centre - ppoly.mean(axis=0))) <= 1.0:
                c.names += 1
        lo, hi = tp.min(axis=0), tp.max(axis=0)
        xs, ys = np.arange(lo[0] + 0.1, hi[0], 0.2), np.arange(lo[1] + 0.1, hi[1], 0.2)
        if not len(xs) or not len(ys):
            continue
        G = np.array([(x, y) for x in xs for y in ys])
        G = G[_deep_many(G, tp, INSET)]
        if len(G):
            hit = np.zeros(len(G), bool)
            for pn, pp in plan_rooms:
                if _fold(pn) != _fold(name) or not _fold(name):
                    hit |= _deep_many(G, pp, INSET)
            c.area_m2 += 0.04 * int(hit.sum())
    c.stairs = sum(1 for sp in scan_stairs
                   if any(float(np.linalg.norm((R @ sp.mean(axis=0)) + t - pp.mean(axis=0))) <= 0.6 for pp in plan_stairs))
    c.score = (W_WALL * c.wall_m + W_OPENING * c.openings + W_STAIR * c.stairs + W_NAME * c.names - W_AREA * c.area_m2 - W_CROSS * crossing * SAMPLE)


def _open_matches(R: np.ndarray, t: np.ndarray, scan_open: list[Opening2], plan_open: list[Opening2]) -> int:
    """Scan openings that coincide with a plan opening of the same kind and about the same width."""
    if not scan_open or not plan_open:
        return 0
    sm = np.array([o.mid for o in scan_open]) @ R.T + t
    pm = np.array([o.mid for o in plan_open])
    sk = np.array([o.kind == "window" for o in scan_open])
    pk = np.array([o.kind == "window" for o in plan_open])
    sw, pw = np.array([o.width for o in scan_open]), np.array([o.width for o in plan_open])
    near = np.linalg.norm(sm[:, None, :] - pm[None], axis=2) <= OPENING_TOL
    ok = near & (sk[:, None] == pk[None]) & (np.abs(sw[:, None] - pw[None]) <= 0.25)
    return int(ok.any(axis=1).sum())


def _prefilter(cands: list[Candidate], scan_open, scan_rooms, plan_open, plan_rooms) -> list[Candidate]:
    """Keep the MAX_FULL candidates with the most cheap evidence (a deterministic order); the full wall and overlap
    score is the expensive part and is only worth spending on those."""
    if len(cands) <= MAX_FULL:
        return cands
    def cheap(c: Candidate) -> tuple:
        R, t = _rot(c.rotation), np.array([c.tx, c.ty])
        names = 0
        for name, poly in scan_rooms:
            if not _fold(name):
                continue
            centre = ((R @ poly.T).T + t).mean(axis=0)
            names += sum(1 for pn, pp in plan_rooms if _fold(pn) == _fold(name) and float(np.linalg.norm(centre - pp.mean(axis=0))) <= 1.0)
        overlap = 0.0   # room overlap on a coarse 0.5 m grid: a doorway match that puts the scan on top of rooms is a poor one
        for name, poly in scan_rooms:
            tp = (R @ poly.T).T + t
            lo, hi = tp.min(axis=0), tp.max(axis=0)
            xs, ys = np.arange(lo[0] + 0.25, hi[0], 0.5), np.arange(lo[1] + 0.25, hi[1], 0.5)
            if not len(xs) or not len(ys):
                continue
            G = np.array([(x, y) for x in xs for y in ys])
            G = G[_deep_many(G, tp, INSET)]
            hit = np.zeros(len(G), bool)
            for pn, pp in plan_rooms:
                if len(G) and (_fold(pn) != _fold(name) or not _fold(name)):
                    hit |= _deep_many(G, pp, INSET)
            overlap += 0.25 * int(hit.sum())
        return (-(_open_matches(R, t, scan_open, plan_open) * W_OPENING + names * W_NAME - W_AREA * overlap),
                round(c.rotation, 1), round(c.tx, 2), round(c.ty, 2))
    return sorted(cands, key=cheap)[:MAX_FULL]


def _candidates(scan_open, scan_rooms, plan_open, plan_rooms, scan_stairs=(), plan_stairs=()) -> list[Candidate]:
    out: dict[tuple, Candidate] = {}

    def add(rot_rad: float, t: np.ndarray, source: str) -> None:
        deg = (math.degrees(rot_rad) + 180) % 360 - 180
        key = (round(deg, 0), round(float(t[0]), 1), round(float(t[1]), 1))
        out.setdefault(key, Candidate(deg, float(t[0]), float(t[1]), source))

    for o in scan_open:
        for p in plan_open:
            if o.kind != p.kind or abs(o.width - p.width) > WIDTH_TOL:
                continue
            for flip in (0.0, math.pi):
                th = p.angle - o.angle + flip
                add(th, p.mid - _rot(math.degrees(th)) @ o.mid, "doorway")
    for sp in scan_stairs:  # the same staircase seen from the two floors it joins fixes the floors to each other
        for pp in plan_stairs:
            base = _longest_angle(pp) - _longest_angle(sp)
            for k in range(2):
                th = base + k * math.pi
                add(th, pp.mean(axis=0) - _rot(math.degrees(th)) @ sp.mean(axis=0), "stair")
    for name, poly in scan_rooms:
        if not _fold(name):
            continue
        for pname, ppoly in plan_rooms:
            if _fold(name) != _fold(pname):
                continue
            base = _longest_angle(ppoly) - _longest_angle(poly)
            for k in range(4):
                th = base + k * math.pi / 2
                add(th, ppoly.mean(axis=0) - _rot(math.degrees(th)) @ poly.mean(axis=0), "name")
    return list(out.values())


def _side(v: float) -> int:
    return 1 if v > 1e-6 else -1 if v < -1e-6 else 0


def _by_labels(house, data, level, blob, scanned, scan_walls, plan_walls, plan_open, plan_rooms, scan_rooms, scan_open, scan_stairs, plan_stairs,
               names, labels, plan_labels) -> dict:
    """Placement by connections: a door of this scan labelled "leads to B" and a door already on the plan labelled "leads to
    <this room>", in room B. The scan's door is laid on the plan's: centres coincide (apart from the wall's thickness), walls
    parallel, the two rooms on opposite sides. Several connections are fitted together (least squares)."""
    doors = scan_doors(data)
    carried = room_names(data)
    def room_name(i: int) -> str:
        return (names[i] if names and i < len(names) and (names[i] or "").strip() else carried[i] if i < len(carried) else "") or ""
    scan_poly = {int(r.prov.ref.rsplit("/", 1)[1]): np.array(r.polygon, float) for r in scanned.rooms
                 if r.level == level and (r.prov.ref or "").startswith(f"{blob}#room/")}
    plan_by_ref = {o.ref: o for o in plan_open if o.ref}
    pairs = []   # (scan door, plan door, the placed room it opens into)
    missing: list[str] = []
    for d in doors:
        to = (labels.get(d["id"]) or "").strip()
        if not to or _fold(to) == "outside":
            continue
        mine_name = room_name(d["room"])
        targets = [(n, poly) for n, poly in plan_rooms if _fold(n) == _fold(to)]
        if not targets:
            missing.append(f"{to} is not on the plan yet")
            continue
        found = [(o, ref) for ref, o in plan_by_ref.items() if _fold(plan_labels.get(ref.replace("#door/", "#"), "")) == _fold(mine_name) and _fold(mine_name)
                 and any(_edge_dist(o.mid, poly) <= 0.8 for _, poly in targets)]
        if not found:
            missing.append(f"{to} has no door labelled {mine_name or 'this room'}")
            continue
        for o, _ in found:
            poly = min((poly for _, poly in targets), key=lambda p: _edge_dist(o.mid, p))
            pairs.append((d, o, poly))
    if not pairs:
        ident = {"rotation": 0.0, "tx": 0.0, "ty": 0.0}
        why = "Label a door that connects to a placed room (and the matching door of that room back)."
        return {"confidence": "unlabelled", "reason": why, "transform": ident, "score": 0.0,
                "evidence": {"missing": missing or ["no door of this scan is labelled"]}, "alternatives": [],
                "preview": _preview(scan_walls, Candidate(0.0, 0.0, 0.0, "none"))}

    def pose(d, o, poly, flip_pick=None):
        """(rotation deg, translation, landing point) laying door d on door o with the rooms on opposite sides."""
        s = np.array([d["x"], d["y"]])
        n = np.array([-math.sin(o.angle), math.cos(o.angle)])
        side_plan = _side(float((poly.mean(axis=0) - o.mid) @ n))
        cs = scan_poly.get(d["room"])
        best = None
        for flip in (0.0, math.pi):
            th = o.angle - math.radians(d["angle"]) + flip
            deg = (math.degrees(th) + 180) % 360 - 180
            side_scan = _side(float((_rot(deg) @ ((cs.mean(axis=0) if cs is not None else s) - s)) @ n))
            if cs is not None and side_plan and side_scan and side_scan == side_plan:
                continue   # both rooms on one side of the wall: not this orientation
            land = o.mid - side_plan * n * o.thickness   # on the far side of the plan wall
            best = best or (deg, land - _rot(deg) @ s, land)
        deg0 = (math.degrees(o.angle - math.radians(d["angle"])) + 180) % 360 - 180
        return best or (deg0, o.mid - _rot(deg0) @ np.array([d["x"], d["y"]]), o.mid)

    # every pair proposes a pose; the pose that the most other pairs agree with wins, and those pairs are fitted together
    best_fit = None
    for d, o, poly in pairs:
        deg, t, _ = pose(d, o, poly)
        R = _rot(deg)
        agree = []
        used = set()
        for d2, o2, poly2 in pairs:
            _, _, land2 = pose(d2, o2, poly2)
            gap = float(np.linalg.norm(R @ np.array([d2["x"], d2["y"]]) + t - land2))
            key = d2["id"]
            if gap <= 0.5 and key not in used:
                used.add(key)
                agree.append((d2, land2, gap))
        key = (len(agree), -sum(g for *_, g in agree))
        if best_fit is None or key > best_fit[0]:
            best_fit = (key, deg, t, agree)
    _, deg, t, agree = best_fit
    if len(agree) >= 2:
        sim = register([(d["x"], d["y"]) for d, *_ in agree], [(float(l[0]), float(l[1])) for _, l, _ in agree])
        deg, t = sim.rotation, np.array([sim.tx, sim.ty])
    R = _rot(deg)
    resid = max(float(np.linalg.norm(R @ np.array([d["x"], d["y"]]) + t - land)) for d, land, _ in agree)
    c = Candidate(deg, float(t[0]), float(t[1]), "labelled doors")
    ctx = _Ctx.build(scan_walls, plan_walls)
    _score(c, ctx, scan_open, scan_rooms, plan_open, plan_rooms, scan_stairs, plan_stairs)
    conf = "labelled" if resid <= 0.15 and c.area_m2 <= 0.5 else "confirm"
    reason = f"{len(agree)} labelled connection(s); fits to {resid * 100:.0f} cm" + ("" if conf == "labelled" else " (rooms would overlap: check it)" if c.area_m2 > 0.5 else " (the connections disagree: check it)")
    return {"confidence": conf, "reason": reason, **_out(c), "evidence": {"connections": len(agree), "residual_cm": round(resid * 100, 1),
            "room_overlap_m2": round(c.area_m2, 2), "wall_overlap_m": round(c.wall_m, 2), "source": "labelled doors", "missing": missing},
            "alternatives": [], "preview": _preview(scan_walls, c)}


def _snap(c: Candidate, scan_walls: list[Wall], plan_dom: float | None) -> None:
    """Houses are mostly rectilinear: nudge the rotation onto the plan's dominant direction when within 3 degrees."""
    dom = _dominant(scan_walls)
    if plan_dom is None or dom is None:
        return
    after = (dom + math.radians(c.rotation)) % (math.pi / 2)
    delta = (plan_dom - after + math.pi / 4) % (math.pi / 2) - math.pi / 4
    if abs(delta) <= math.radians(3):
        centre = np.mean([[*w.a] for w in scan_walls] + [[*w.b] for w in scan_walls], axis=0)
        before = _rot(c.rotation) @ centre + np.array([c.tx, c.ty])
        c.rotation += math.degrees(delta)
        now = _rot(c.rotation) @ centre + np.array([c.tx, c.ty])
        c.tx += float(before[0] - now[0])
        c.ty += float(before[1] - now[1])


def _distinct(a: Candidate, b: Candidate) -> bool:
    dr = abs((a.rotation - b.rotation + 180) % 360 - 180)
    return math.hypot(a.tx - b.tx, a.ty - b.ty) > DISTINCT_M or dr > DISTINCT_DEG


def _out(c: Candidate) -> dict:
    return {"transform": {"rotation": round(c.rotation, 3), "tx": round(c.tx, 4), "ty": round(c.ty, 4)}, "score": round(c.score, 2),
            "source": c.source}


def _preview(scan_walls: list[Wall], c: Candidate) -> list[dict]:
    return [{"a": [round(x, 3) for x in w.a], "b": [round(x, 3) for x in w.b]} for w in _transform_walls(scan_walls, c.sim())]


def propose(house: House, data: dict, level: str, blob: str, names: list[str] | None = None,
            retire: tuple[dict, str, int] | None = None, room_levels: list[str | None] | None = None,
            door_labels: dict[str, str] | None = None, plan_labels: dict[str, str] | None = None, guess: bool = False) -> dict:
    """The proposal for placing capture `blob` (`data`) on `level` of `house`.

    `retire` = (earlier capture's data, its blob, room index) when this scan re-scans a room: that room's own walls
    are left out of the plan, so the scan is matched against its neighbours; if nothing else is on the level, the
    old room stays and the match is by name.
    """
    try:
        scanned, rep = import_capture(house, data, level, blob, Similarity2D(), names=names, room_levels=room_levels)
    except ImportError_ as e:
        raise ValueError(str(e)) from None
    mine = lambda ref: (ref or "").startswith(f"{blob}#")  # noqa: E731
    scan_walls = [w for w in scanned.walls if w.level == level and mine(w.prov.ref)]
    if retire is not None:
        lighter, _ = retire_room(house, *retire)
        if any(w.level == level and not mine(w.prov.ref) for w in lighter.walls):
            house = lighter
    plan_walls = [w for w in house.walls if w.level == level and not mine(w.prov.ref)]
    scan_rooms = [(r.name, np.array(r.polygon, float)) for r in scanned.rooms if r.level == level and mine(r.prov.ref)]
    plan_rooms = [(r.name, np.array(r.polygon, float)) for r in house.rooms if r.level == level and not mine(r.prov.ref)]

    scan_stairs = [np.array(st["polygon"], float) for st in stair_footprints(data)]
    plan_stairs = [np.array(st.polygon, float) for st in house.stairs if level in (st.from_level, st.to_level)]

    if not plan_walls and scan_stairs and plan_stairs:  # the first scan of a floor: line it up by the staircase from the floor below/above
        cands = _candidates([], [], [], [], scan_stairs, plan_stairs)
        ctx0 = _Ctx.build(scan_walls, [])
        for c in cands:
            _score(c, ctx0, [], scan_rooms, [], [], scan_stairs, plan_stairs)
        cands.sort(key=lambda c: (-c.score, round(c.rotation, 1), round(c.tx, 2), round(c.ty, 2)))
        best = cands[0]
        return {"confidence": "confirm", "reason": "lined up by the staircase to the floor below or above: check the rotation", **_out(best),
                "evidence": {"stairs": best.stairs, "source": "stair"}, "alternatives": [_out(c) for c in cands[1:3]],
                "preview": _preview(scan_walls, best)}

    if not plan_walls:  # nothing to line up with: keep the scan's frame, turned so its walls run along the axes
        dom = _dominant(scan_walls) or 0.0
        deg = -math.degrees(dom if dom <= math.pi / 4 else dom - math.pi / 2)
        centre = np.mean([[*w.a] for w in scan_walls] + [[*w.b] for w in scan_walls], axis=0)
        t = centre - _rot(deg) @ centre
        c = Candidate(deg, float(t[0]), float(t[1]), "empty plan")
        return {"confidence": "auto", "reason": "the level has no walls yet", **_out(c), "evidence": {}, "alternatives": [],
                "preview": _preview(scan_walls, c)}

    scan_open, plan_open = _openings(scan_walls), _openings(plan_walls)
    if not guess:   # the placement is the labelled connections; the search below is only for "Guess for me"
        return _by_labels(house, data, level, blob, scanned, scan_walls, plan_walls, plan_open, plan_rooms, scan_rooms, scan_open, scan_stairs, plan_stairs,
                          names, door_labels or {}, plan_labels or {})
    cands = _candidates(scan_open, scan_rooms, plan_open, plan_rooms, scan_stairs, plan_stairs)
    if not cands:
        return {"confidence": "manual", "reason": "no shared doorway or room name to line the scan up by",
                "transform": {"rotation": 0.0, "tx": 0.0, "ty": 0.0}, "score": 0.0, "evidence": {}, "alternatives": [],
                "preview": _preview(scan_walls, Candidate(0.0, 0.0, 0.0, "none"))}
    ctx = _Ctx.build(scan_walls, plan_walls)
    plan_dom = _dominant(plan_walls)
    cands = _prefilter(cands, scan_open, scan_rooms, plan_open, plan_rooms)
    for c in cands:
        _score(c, ctx, scan_open, scan_rooms, plan_open, plan_rooms, scan_stairs, plan_stairs)
    cands.sort(key=lambda c: (-c.score, round(c.rotation, 1), round(c.tx, 2), round(c.ty, 2)))
    for c in cands[:5]:
        _snap(c, scan_walls, plan_dom)
        _score(c, ctx, scan_open, scan_rooms, plan_open, plan_rooms, scan_stairs, plan_stairs)
    top = sorted(cands[:5], key=lambda c: (-c.score, round(c.rotation, 1), round(c.tx, 2), round(c.ty, 2)))
    best = top[0]
    others = [c for c in top[1:] if _distinct(best, c)]
    runner = others[0].score if others else None

    evidence = {"openings": best.openings, "named_rooms": best.names, "stairs": best.stairs, "wall_overlap_m": round(best.wall_m, 2),
                "room_overlap_m2": round(best.area_m2, 2), "source": best.source}
    if best.openings == 0 and best.names == 0 and best.stairs == 0 and best.wall_m < 1.0:
        conf, reason = "manual", "nothing in the scan lines up with the plan"
    elif best.area_m2 > 0.5 or (runner is not None and best.score - runner < max(2.0, 0.25 * best.score)):
        conf = "confirm"
        reason = "rooms would overlap" if best.area_m2 > 0.5 else "another placement scores about as well"
    else:
        conf, reason = "auto", "a clear match"
    return {"confidence": conf, "reason": reason, **_out(best), "evidence": evidence, "alternatives": [_out(c) for c in others[:2]],
            "preview": _preview(scan_walls, best)}
