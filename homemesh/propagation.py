"""Multi-wall-and-floor path loss (design section 3, COST 231 multi-wall style).

    PL = PL0(f) + 10 n log10(d) + sum(wall losses) + sum(slab losses)
    PL0(f) = 20 log10(f_MHz) - 27.56                      (free space at 1 m)

Walls are counted from the real geometry: every wall prism the 3D segment from
transmitter to receiver crosses costs its material's loss, scaled by thickness
over the material's reference thickness and by incidence (effective thickness
t / max(cos(theta), cos 70 deg)). A crossing inside an opening costs the
opening's material instead (an `air` opening or an open door costs nothing).
Slabs are charged where the segment crosses a level boundary outside every
slab hole and open stairwell.

Median path loss only; no fading, no interference (those are the callers').
"""

from __future__ import annotations

import math
from collections.abc import Iterator
from dataclasses import dataclass, field

import numpy as np

from .model import Band, House, Material, Wall

BAND_MHZ: dict[str, float] = {"2.4": 2437.0, "5": 5500.0, "6": 6200.0}
_COS_MAX_INCIDENCE = math.cos(math.radians(70.0))
_EPS = 1e-9


@dataclass(frozen=True)
class Params:
    """Per-band model parameters; the calibration (M7) fits these."""

    n: dict[str, float] = field(default_factory=lambda: {"2.4": 2.0, "5": 2.0, "6": 2.0})
    # calibration: dB added to every path loss in the band (clutter, device and body loss, antenna error)
    extra_loss: dict[str, float] = field(default_factory=lambda: {"2.4": 0.0, "5": 0.0, "6": 0.0})


@dataclass(frozen=True)
class Tx:
    position: tuple[float, float]
    level: str
    height: float = 1.8  # above the level's floor
    power_dbm: float = 20.0
    gain_dbi: float = 3.0


@dataclass(frozen=True)
class Grid:
    level: str
    x0: float
    y0: float
    step: float
    nx: int
    ny: int
    z: float  # absolute receiver height

    def points(self) -> np.ndarray:
        xs = self.x0 + (np.arange(self.nx) + 0.5) * self.step
        ys = self.y0 + (np.arange(self.ny) + 0.5) * self.step
        gx, gy = np.meshgrid(xs, ys)
        return np.stack([gx.ravel(), gy.ravel()], axis=1)


def free_space_1m(band: Band) -> float:
    return 20.0 * math.log10(BAND_MHZ[band]) - 27.56


def _mat(house: House) -> dict[str, Material]:
    return {m.id: m for m in house.materials}


def _loss(mats: dict[str, Material], mid: str, band: str) -> float:
    return 0.0 if mid == "air" else mats[mid].loss[band]


def _ref(mats: dict[str, Material], mid: str) -> float:
    return 1.0 if mid == "air" else mats[mid].ref_thickness


def level_z(house: House) -> dict[str, float]:
    return {lv.id: lv.elevation for lv in house.levels}


def _cross(ax, ay, bx, by):
    return ax * by - ay * bx


def _in_polygon(pts: np.ndarray, poly: list[tuple[float, float]]) -> np.ndarray:
    x, y = pts[:, 0], pts[:, 1]
    inside = np.zeros(len(pts), dtype=bool)
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if y1 == y2:
            continue
        hit = ((y1 > y) != (y2 > y)) & (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1)
        inside ^= hit
    return inside


def _slab_holes(house: House, level: str) -> list[list[tuple[float, float]]]:
    polys = [h.polygon for h in house.slab_holes if h.level == level]
    polys += [s.polygon for s in house.stairs if s.void and s.to_level == level]
    return polys


def _walk(house: House, tx: tuple[float, float, float], rx: np.ndarray, band: Band):
    """Yield (kind, element id, [(material id, loss dB per receiver), ...]) for every wall and
    slab the segment tx-rx crosses, with the loss split by the material that causes it (a wall's
    own material, and each opening's material where the ray passes through the opening)."""
    mats = _mat(house)
    elev = level_z(house)
    n = len(rx)
    t2 = np.array(tx[:2])
    d = rx[:, :2] - t2  # (N, 2)
    dlen = np.hypot(d[:, 0], d[:, 1])
    dz = rx[:, 2] - tx[2]

    for w in house.walls:
        floor = elev[w.level]
        z_lo, z_hi = floor + w.base_z, floor + w.base_z + w.height
        ax, ay = w.a
        ex, ey = w.b[0] - ax, w.b[1] - ay
        wlen = math.hypot(ex, ey)
        if wlen == 0:
            continue
        denom = _cross(d[:, 0], d[:, 1], ex, ey)
        ok = np.abs(denom) > _EPS
        safe = np.where(ok, denom, 1.0)
        px, py = ax - t2[0], ay - t2[1]
        s = _cross(px, py, ex, ey) / safe  # along the ray
        u = _cross(px, py, d[:, 0], d[:, 1]) / safe  # along the wall
        z = tx[2] + s * dz
        hit = ok & (s > _EPS) & (s < 1 - _EPS) & (u >= 0) & (u <= 1) & (z >= z_lo) & (z <= z_hi)
        if not hit.any():
            continue
        # incidence: angle between the ray and the wall normal
        with np.errstate(invalid="ignore", divide="ignore"):
            cos_t = np.abs((d[:, 0] * -ey + d[:, 1] * ex) / (np.where(dlen > 0, dlen, 1.0) * wlen))
        cos_t = np.clip(cos_t, _COS_MAX_INCIDENCE, 1.0)
        wall_db = _loss(mats, w.material, band) * (w.thickness / cos_t) / _ref(mats, w.material)
        along = u * wlen
        zrel = z - floor
        remaining = hit.copy()
        parts: list[tuple[str, np.ndarray]] = []
        for o in w.openings:
            inside = remaining & (along >= o.offset) & (along <= o.offset + o.width) & (zrel >= o.sill) & (zrel <= o.sill + o.height)
            if inside.any():
                op_db = 0.0 if o.state == "open" else _loss(mats, o.material, band)
                if op_db:
                    parts.append((o.material, np.where(inside, op_db, 0.0)))
                remaining &= ~inside
        parts.insert(0, (w.material, np.where(remaining, wall_db, 0.0)))
        if any(arr.any() for _, arr in parts):
            yield "wall", w.id, parts

    # slabs: each level boundary the segment crosses, outside every hole
    for lv in house.levels:
        if lv.slab is None:
            continue
        zb = lv.elevation
        crossing = (tx[2] - zb) * (rx[:, 2] - zb) < 0
        if not crossing.any():
            continue
        with np.errstate(invalid="ignore", divide="ignore"):
            s = np.where(crossing, (zb - tx[2]) / np.where(dz != 0, dz, 1.0), 0.0)
        pts = t2 + s[:, None] * d
        in_hole = np.zeros(n, dtype=bool)
        for poly in _slab_holes(house, lv.id):
            in_hole |= _in_polygon(pts, poly)
        db = _loss(mats, lv.slab.material, band) * lv.slab.thickness / _ref(mats, lv.slab.material)
        loss = np.where(crossing & ~in_hole, db, 0.0)
        if loss.any():
            yield "slab", lv.id, [(lv.slab.material, loss)]


def terms(house: House, tx: tuple[float, float, float], rx: np.ndarray, band: Band) -> Iterator[tuple[str, str, np.ndarray]]:
    """Yield (kind, element id, loss in dB per receiver) for every wall and slab
    that costs something. `tx` is (x, y, z) absolute; `rx` is (N, 3) absolute.
    Only the sum is physical; the pieces are what the planner explains.
    """
    for kind, ident, parts in _walk(house, tx, rx, band):
        total = parts[0][1]
        for _, arr in parts[1:]:
            total = total + arr
        yield kind, ident, total


def exposures(house: House, tx: tuple[float, float, float], rx: np.ndarray, band: Band) -> dict[str, np.ndarray]:
    """Per material, how many reference-thickness units of it each segment tx-rx crosses.

    Path loss is linear in the material losses: loss = sum_m exposure_m * L_m. This is what
    calibration regresses on. Computed by running the same geometry with every loss set to 1 dB.
    """
    unit = house.model_copy(update={"materials": [m.model_copy(update={"loss": {b: 1.0 for b in m.loss}}) for m in house.materials]})
    out: dict[str, np.ndarray] = {}
    for _, _, parts in _walk(unit, tx, rx, band):
        for mid, arr in parts:
            out[mid] = out.get(mid, 0.0) + arr
    return out


def path_loss(house: House, tx: tuple[float, float, float], rx: np.ndarray, band: Band, params: Params = Params()) -> np.ndarray:
    """Total path loss in dB from absolute point `tx` to each row of `rx` (N, 3)."""
    d = np.sqrt(((rx - np.array(tx)) ** 2).sum(axis=1))
    total = free_space_1m(band) + params.extra_loss[band] + 10.0 * params.n[band] * np.log10(np.maximum(d, 1.0))
    for _, _, loss in terms(house, tx, rx, band):
        total = total + loss
    return total


def explain_point(house: House, tx: tuple[float, float, float], rx: tuple[float, float, float], band: Band, params: Params = Params()) -> list[tuple[str, str, float]]:
    """Largest-first list of (kind, id, dB) for one transmitter/receiver pair."""
    r = np.array([rx])
    out = [(k, i, float(v[0])) for k, i, v in terms(house, tx, r, band)]
    return sorted(out, key=lambda t: -t[2])


def level_grid(house: House, level: str, step: float = 0.5, rx_height: float = 1.0) -> Grid:
    ws = [w for w in house.walls if w.level == level]
    xs = [p[0] for w in ws for p in (w.a, w.b)]
    ys = [p[1] for w in ws for p in (w.a, w.b)]
    if not xs:
        raise ValueError(f"level {level} has no walls to bound a grid")
    x0, y0 = min(xs), min(ys)
    nx = max(1, math.ceil((max(xs) - x0) / step))
    ny = max(1, math.ceil((max(ys) - y0) / step))
    return Grid(level, x0, y0, step, nx, ny, level_z(house)[level] + rx_height)


def _near_wall(pts: np.ndarray, w: Wall) -> np.ndarray:
    a = np.array(w.a)
    e = np.array(w.b) - a
    ee = float(e @ e)
    t = np.clip(((pts - a) @ e) / ee, 0.0, 1.0) if ee else np.zeros(len(pts))
    dist = np.hypot(*(pts - (a + t[:, None] * e)).T)
    return dist < w.thickness / 2


def grid_mask(house: House, grid: Grid) -> np.ndarray:
    """True where a receiver may sit: inside the house's bounds, not inside a wall."""
    pts = grid.points()
    bad = np.zeros(len(pts), dtype=bool)
    for w in house.walls:
        if w.level == grid.level:
            bad |= _near_wall(pts, w)
    return ~bad


def rssi_map(house: House, tx: Tx, band: Band, grid: Grid, params: Params = Params()) -> np.ndarray:
    """Median RSSI (dBm) over `grid`, shape (ny, nx); NaN inside walls."""
    pts = grid.points()
    rx = np.column_stack([pts, np.full(len(pts), grid.z)])
    tz = level_z(house)[tx.level] + tx.height
    loss = path_loss(house, (tx.position[0], tx.position[1], tz), rx, band, params)
    rssi = tx.power_dbm + tx.gain_dbi - loss
    rssi = np.where(grid_mask(house, grid), rssi, np.nan)
    return rssi.reshape(grid.ny, grid.nx).astype(np.float32)
