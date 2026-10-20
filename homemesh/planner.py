"""The planner (design section 5): candidate spots, search, ranking.

Candidates come from the owner's `allow` zones minus `forbid` zones, honouring
a zone's power requirement. Every candidate's loss map is computed once (cached
in the Context); evaluating an arrangement afterwards is array arithmetic on
those maps. Search per (equipment, node count k):

  * exhaustive over a pruned set of representative spots when C(R, k) is small;
  * otherwise greedy by marginal gain; both finish with swap refinement over
    every candidate (the representatives expanded back to the full set).

Ranking is a vector (coverage, worst zone, cost, node count, robustness), shown
as a Pareto front; the scalar `score` uses the owner's zone weights.
"""

from __future__ import annotations

import itertools
import math
from collections.abc import Callable
from dataclasses import dataclass, field

import numpy as np

from .equipment import Equipment
from .model import House, Zone
from .network import Context, Evaluation, Placement, Policy, ZoneScore, evaluate, zone_scores
from .propagation import _in_polygon

DEFAULT_HEIGHT = 1.5
FORBID_RADIUS = 0.75  # a single-point forbid zone covers this radius


@dataclass(frozen=True)
class PlanConfig:
    gateway_equipment: str = "generic-router-ax"
    equipment: tuple[str, ...] = ()  # shortlist; empty = every mesh_node/extender in the catalogue
    k_max: int = 5  # owner decision D7
    price_ceiling: float | None = None
    policy: Policy = Policy()
    candidate_step: float = 0.5
    gateway_height: float = 1.2
    max_representatives: int = 40
    exhaustive_limit: int = 12_000
    swap_rounds: int = 3
    top_n: int = 5


@dataclass
class Scored:
    equipment: str
    extras: list[Placement]
    score: float  # weighted coverage utility at the median, 0..1
    score_margin: float  # the same at the shadowing margin
    worst: float  # worst demand zone's utility at the median
    cost: float
    valid: bool
    must_ok: bool
    zones: list[ZoneScore]
    evaluation: Evaluation = field(repr=False, default=None)  # type: ignore[assignment]

    @property
    def k(self) -> int:
        return len(self.extras)

    @property
    def stable(self) -> bool:
        """The score survives the margin without losing more than 0.05."""
        return self.score - self.score_margin <= 0.05


# --- candidates ------------------------------------------------------------------

def _inside(pt, zone: Zone) -> bool:
    if len(zone.polygon) >= 3:
        return bool(_in_polygon(np.array([pt]), [tuple(p) for p in zone.polygon])[0])
    return math.hypot(pt[0] - zone.polygon[0][0], pt[1] - zone.polygon[0][1]) <= FORBID_RADIUS


def _powered(house: House, zone: Zone, pt: tuple[float, float]) -> bool:
    if zone.requires == "none":
        return True
    if zone.requires == "outlet":
        return any(o.level == zone.level and math.hypot(o.position[0] - pt[0], o.position[1] - pt[1]) <= 1.5 for o in house.outlets)
    return any(j.poe and j.state != "dead" and j.level == zone.level
               and math.hypot(j.position[0] - pt[0], j.position[1] - pt[1]) <= 0.6 for j in house.jacks)


def candidates(house: House, step: float = 0.5) -> list[Placement]:
    forbids = [z for z in house.zones if z.kind == "forbid"]
    out: dict[tuple, Placement] = {}

    def add(zone: Zone, pt: tuple[float, float]) -> None:
        pt = (round(pt[0], 3), round(pt[1], 3))
        if any(f.level == zone.level and _inside(pt, f) for f in forbids) or not _powered(house, zone, pt):
            return
        for h in zone.heights or [DEFAULT_HEIGHT]:
            out.setdefault((pt, zone.level, h), Placement("", pt, zone.level, h))

    for z in house.zones:
        if z.kind != "allow":
            continue
        if len(z.polygon) < 3:
            add(z, z.polygon[0])
            continue
        xs, ys = [p[0] for p in z.polygon], [p[1] for p in z.polygon]
        gx = np.arange(min(xs) + step / 2, max(xs), step)
        gy = np.arange(min(ys) + step / 2, max(ys), step)
        pts = np.array([(x, y) for x in gx for y in gy]) if len(gx) and len(gy) else np.zeros((0, 2))
        inside = _in_polygon(pts, [tuple(p) for p in z.polygon]) if len(pts) else []
        for pt, ok in zip(pts, inside):
            if ok:
                add(z, (float(pt[0]), float(pt[1])))
        for j in house.jacks:  # a jack inside an allow zone is always a candidate: it may be a wired spot
            if j.level == z.level and _inside(j.position, z):
                add(z, j.position)
    return sorted(out.values(), key=lambda p: (p.level, p.position, p.height))


def representatives(ctx: Context, cands: list[Placement], n: int, keep: set[int] = frozenset()) -> list[int]:
    """Indices of up to n spots that differ most in what they cover (farthest-point on loss signatures)."""
    if len(cands) <= n:
        return list(range(len(cands)))
    ok = np.flatnonzero(ctx.cell_ok)
    sub = ok[:: max(1, len(ok) // 400)]
    sig = np.array([np.minimum(ctx.loss_to_cells(c, "5")[sub], 110.0) for c in cands])
    chosen = list(dict.fromkeys(sorted(keep)))[:n] or [int(np.argmin(sig.mean(axis=1)))]
    dist = np.min([np.linalg.norm(sig - sig[i], axis=1) for i in chosen], axis=0)
    while len(chosen) < n:
        i = int(np.argmax(dist))
        if dist[i] <= 1e-9:
            break
        chosen.append(i)
        dist = np.minimum(dist, np.linalg.norm(sig - sig[i], axis=1))
    return sorted(chosen)


# --- scoring ---------------------------------------------------------------------

def _weights(house: House) -> tuple[list[str], np.ndarray]:
    zs = [z for z in house.zones if z.kind == "demand"]
    return [z.id for z in zs], np.array([max(z.weight, 0.0) for z in zs])


def score(ctx: Context, gateway: Placement, extras: list[Placement], equipment: str, cfg: PlanConfig,
          robust: bool = True) -> Scored:
    """`robust=False` skips the second evaluation at the shadowing margin (search speed); the
    margin fields then repeat the median ones until `search` finalises its kept results."""
    ev = evaluate(ctx, gateway, extras, cfg.policy)
    evm = evaluate(ctx, gateway, extras, cfg.policy, margin=cfg.policy.margin_db) if robust else ev
    zs = zone_scores(ctx, ev, evm, cfg.policy)
    _, w = _weights(ctx.house)
    tot = float(w.sum()) or 1.0
    s = float(sum(wi * z.utility for wi, z in zip(w, zs)) / tot) if zs else 0.0
    sm = float(sum(wi * z.utility_margin for wi, z in zip(w, zs)) / tot) if zs else 0.0
    worst = min((z.utility for z in zs), default=0.0)
    must = all(z.must_met is not False for z in zs)
    valid = ev.valid and (cfg.price_ceiling is None or ev.cost <= cfg.price_ceiling)
    return Scored(equipment, extras, s, sm, worst, ev.cost, valid, must, zs, ev)


def _key(sc: Scored):
    """Sort key, best first: valid, `must` zones met, score, margin score, cheaper."""
    return (not sc.valid, not sc.must_ok, -sc.score, -sc.score_margin, sc.cost)


# --- search ----------------------------------------------------------------------

def _place(c: Placement, equipment: str) -> Placement:
    return Placement(equipment, c.position, c.level, c.height)


def search(ctx: Context, cfg: PlanConfig, catalogue: dict[str, Equipment],
           progress: Callable[[str], None] = lambda _m: None) -> list[Scored]:
    house = ctx.house
    if house.entry is None:
        raise ValueError("the house has no internet entry: the gateway needs somewhere to sit")
    cands = candidates(house, cfg.candidate_step)
    if not cands:
        raise ValueError("no candidate spots: mark at least one allow zone")
    gateway = Placement(cfg.gateway_equipment, house.entry.position, house.entry.level, cfg.gateway_height)
    names = list(cfg.equipment) or sorted(i for i, e in catalogue.items() if e.kind in ("mesh_node", "extender"))
    for n in names:
        if n not in catalogue:
            raise ValueError(f"unknown equipment {n}")

    results: list[Scored] = [score(ctx, gateway, [], cfg.gateway_equipment, cfg)]
    wired_idx = {i for i, c in enumerate(cands) if _near_live_jack(house, c)}
    reps = representatives(ctx, cands, cfg.max_representatives, wired_idx)
    progress(f"{len(cands)} candidate spots, {len(reps)} representatives")

    for name in names:
        for k in range(1, cfg.k_max + 1):
            if math.comb(len(reps), k) <= cfg.exhaustive_limit:
                kept = _exhaustive(ctx, gateway, cands, reps, k, name, cfg)
                how = "exhaustive"
            else:
                kept = _greedy(ctx, gateway, cands, k, name, cfg)
                how = "greedy"
            kept = [_swap(ctx, gateway, cands, sc, cfg) for sc in kept]
            kept.sort(key=_key)
            final = [score(ctx, gateway, sc.extras, sc.equipment, cfg) for sc in _dedupe(kept)[: cfg.top_n]]
            final.sort(key=_key)
            results.extend(final)
            progress(f"{name} k={k}: {how}, best score {final[0].score:.3f}")
    results.sort(key=_key)
    return results


def _near_live_jack(house: House, c: Placement, near: float = 0.6) -> bool:
    return any(j.level == c.level and j.state != "dead" and math.hypot(j.position[0] - c.position[0], j.position[1] - c.position[1]) <= near
               for j in house.jacks)


def _exhaustive(ctx, gateway, cands, reps, k, name, cfg) -> list[Scored]:
    best: list[Scored] = []
    for combo in itertools.combinations(reps, k):
        sc = score(ctx, gateway, [_place(cands[i], name) for i in combo], name, cfg, robust=False)
        sc.evaluation = None  # keep memory flat; re-evaluated for the final top entries
        best.append(sc)
        if len(best) > 200:
            best.sort(key=_key)
            del best[cfg.top_n * 4:]
    best.sort(key=_key)
    return best[: cfg.top_n * 2]


def _greedy(ctx, gateway, cands, k, name, cfg) -> list[Scored]:
    chosen: list[Placement] = []
    for _ in range(k):
        pool = [_place(c, name) for c in cands]
        scored = [(score(ctx, gateway, chosen + [p], name, cfg, robust=False), p) for p in pool if p not in chosen]
        sc, p = min(scored, key=lambda t: _key(t[0]))
        chosen.append(p)
    return [score(ctx, gateway, chosen, name, cfg)]


def _swap(ctx, gateway, cands, sc: Scored, cfg) -> Scored:
    cur = score(ctx, gateway, sc.extras, sc.equipment, cfg, robust=False)
    for _ in range(cfg.swap_rounds):
        improved = False
        for i in range(len(cur.extras)):
            for c in cands:
                p = _place(c, cur.equipment)
                if p in cur.extras:
                    continue
                trial = score(ctx, gateway, cur.extras[:i] + [p] + cur.extras[i + 1:], cur.equipment, cfg, robust=False)
                if _key(trial) < _key(cur):
                    cur, improved = trial, True
        if not improved:
            break
    return cur


def _dedupe(items: list[Scored]) -> list[Scored]:
    seen, out = set(), []
    for sc in items:
        key = tuple(sorted((p.position, p.level, p.height) for p in sc.extras)) + (sc.equipment,)
        if key not in seen:
            seen.add(key)
            out.append(sc)
    return out


def pareto(items: list[Scored]) -> list[Scored]:
    """Arrangements no other valid one beats on (score, worst zone, cost) at once."""
    pool = [s for s in items if s.valid and s.must_ok] or [s for s in items if s.valid]
    front = []
    for a in pool:
        if not any((b.score >= a.score and b.worst >= a.worst and b.cost <= a.cost)
                   and (b.score > a.score or b.worst > a.worst or b.cost < a.cost) for b in pool):
            front.append(a)
    return sorted(front, key=lambda s: (s.cost, -s.score))
