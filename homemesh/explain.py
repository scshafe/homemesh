"""Deterministic explanation of a planner result (design 5.5).

Everything is computed from the numbers (no language model in the loop, so it
cannot invent a reason): per-zone limiting factor, each node's leave-one-out
contribution, the comparison with the runner-up, and the rank stability when
the material losses move within their prior uncertainty.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

import numpy as np

from .network import Context, Evaluation, Placement, Policy, evaluate
from .planner import PlanConfig, Scored, score
from .propagation import explain_point, level_z


@dataclass
class ZoneNote:
    zone: str
    mean_rate: float
    frac_target: float
    utility: float
    limiter: str  # no signal | access | backhaul | wan
    detail: str


@dataclass
class Explanation:
    zones: list[ZoneNote]
    node_contribution: list[tuple[int, float]]  # (node index, score drop when removed)
    vs_runner_up: list[str]
    stability: float | None  # share of material draws in which this arrangement still beats the runner-up
    depends_on_jacks: list[str]
    lines: list[str] = field(default_factory=list)


def _zone_note(ctx: Context, ev: Evaluation, zone, nodes: list[Placement], target_default: float, cfg: PlanConfig) -> ZoneNote:
    m = ctx.zone_mask(zone) & ctx.cell_ok
    target = (zone.need.min_throughput if zone.need else None) or target_default
    if not m.any():
        return ZoneNote(zone.id, 0.0, 0.0, 0.0, "no signal", "the zone covers no receiver cell")
    rate = ev.rate[m]
    mean, frac = float(rate.mean()), float((rate >= target).mean())
    if mean <= 0:
        return ZoneNote(zone.id, mean, frac, 0.0, "no signal", "no node reaches this zone")
    # who serves most of the zone, and what limits it
    serving = ev.serving[m]
    node = int(np.bincount(serving[serving >= 0]).argmax())
    nr = ev.nodes[node]
    backhaul_limited = float(ev.limited_by[m].mean()) > 0.5
    wan = ctx.house.entry.wan_down if ctx.house.entry and ctx.house.entry.wan_down else None
    if backhaul_limited:
        if wan is not None and abs(nr.backhaul_mbps - wan) < 1e-6:
            return ZoneNote(zone.id, mean, frac, 0.0, "wan", f"capped by the internet plan ({wan:.0f} Mbit/s)")
        how = (f"wired through jack {nr.jack}" if nr.kind == "wired"
               else "the gateway itself" if nr.kind == "gateway"
               else f"{nr.hops} wireless hop(s) to the gateway on {nr.link_band} GHz"
               + (", sharing that radio with clients" if nr.shared_radio else ""))
        return ZoneNote(zone.id, mean, frac, 0.0, "backhaul", f"node {node} is limited by its backhaul ({nr.backhaul_mbps:.0f} Mbit/s): {how}")
    # access limited: the biggest wall/slab term between the serving node and the zone's median cell
    idx = np.flatnonzero(m)
    cell = ctx.cells[idx[np.argsort(rate)[len(rate) // 2]]]
    p = nodes[node]
    tx = (p.position[0], p.position[1], level_z(ctx.house)[p.level] + p.height)
    terms = explain_point(ctx.house, tx, (float(cell[0]), float(cell[1]), float(cell[2])), "5")
    mats = {w.id: w.material for w in ctx.house.walls}
    if terms:
        kind, ident, db = terms[0]
        what = f"wall {ident} ({mats.get(ident, '?')})" if kind == "wall" else f"the floor slab of level {ident}"
        detail = f"node {node}: signal limited by distance and {what}, {db:.1f} dB at 5 GHz, the largest obstruction"
    else:
        detail = f"node {node}: signal limited by distance (no walls between)"
    return ZoneNote(zone.id, mean, frac, 0.0, "access", detail)


def _perturbed(ctx: Context, rng: np.random.Generator) -> Context:
    """A context whose material losses moved by a draw within each material's prior spread."""
    h = copy.deepcopy(ctx.house)
    for mat in h.materials:
        d = rng.normal(0.0, mat.prior_sd)
        mat.loss = {b: max(0.0, v + d) for b, v in mat.loss.items()}
    g = ctx.grids[0] if ctx.grids else None
    return Context(h, ctx.catalogue, ctx.client, ctx.params, step=g.step if g else 0.5,
                   rx_height=(g.z - level_z(h)[g.level]) if g else 1.0)


def explain(ctx: Context, gateway: Placement, best: Scored, runner_up: Scored | None, cfg: PlanConfig,
            samples: int = 20, seed: int = 0) -> Explanation:
    ev = best.evaluation
    nodes = [gateway, *best.extras]
    target_default = cfg.policy.floor_mbps
    zone_notes = []
    scored = {z.zone: z for z in best.zones}
    for z in ctx.house.zones:
        if z.kind != "demand":
            continue
        n = _zone_note(ctx, ev, z, nodes, target_default, cfg)
        n.utility = scored[z.id].utility if z.id in scored else 0.0
        zone_notes.append(n)

    contrib = []
    for i in range(len(best.extras)):
        without = best.extras[:i] + best.extras[i + 1:]
        contrib.append((i + 1, best.score - score(ctx, gateway, without, best.equipment, cfg).score))

    vs: list[str] = []
    if runner_up is not None:
        ru = {z.zone: z for z in runner_up.zones}
        for z in best.zones:
            r = ru.get(z.zone)
            if r is None:
                continue
            d = z.utility - r.utility
            if abs(d) >= 0.02:
                vs.append(f"zone {z.zone}: {'wins' if d > 0 else 'loses'} by {abs(d) * 100:.0f} points of utility")
        dc = best.cost - runner_up.cost
        vs.append(f"cost {'+' if dc >= 0 else '-'}{abs(dc):.0f} against the runner-up")

    stability = None
    if runner_up is not None:
        rng = np.random.default_rng(seed)
        wins = 0
        for _ in range(samples):
            c2 = _perturbed(ctx, rng)
            a = score(c2, gateway, best.extras, best.equipment, cfg)
            b = score(c2, gateway, runner_up.extras, runner_up.equipment, cfg)
            wins += a.score >= b.score
        stability = wins / samples

    lines = []
    for n in zone_notes:
        met = "target met" if n.frac_target >= 0.99 else f"{n.frac_target * 100:.0f}% of cells at target"
        lines.append(f"{n.zone}: {n.mean_rate:.0f} Mbit/s mean, {met}; {n.detail}")
    for i, d in contrib:
        lines.append(f"node {i}: removing it costs {d * 100:.1f} points of score")
    lines += vs
    if stability is not None:
        lines.append(f"rank stability: still ahead of the runner-up in {stability * 100:.0f}% of material-loss draws")
    if ev.jacks_unverified:
        lines.append("depends on jacks not yet verified live: " + ", ".join(ev.jacks_unverified))
    return Explanation(zone_notes, contrib, vs, stability, list(ev.jacks_used), lines)
