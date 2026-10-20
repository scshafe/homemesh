"""CLI: plan a mesh for a house JSON and print the ranking.

    python -m homemesh.plan HOUSE.json [--k-max 5] [--step 0.5] [--equipment ID ...] [--json OUT]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .equipment import generic_catalogue, generic_clients
from .explain import explain
from .model import House
from .network import Context, Placement, Policy
from .planner import PlanConfig, pareto, search

ROOT = Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="homemesh.plan")
    ap.add_argument("house")
    ap.add_argument("--k-max", type=int, default=5)
    ap.add_argument("--grid", type=float, default=1.0, help="receiver grid step, metres")
    ap.add_argument("--step", type=float, default=1.0, help="candidate spot step, metres")
    ap.add_argument("--equipment", nargs="*", default=[])
    ap.add_argument("--client", default="phone-2x2-ax")
    ap.add_argument("--trust-unknown-jacks", action="store_true")
    ap.add_argument("--json", help="write the ranking here (outside the repository)")
    a = ap.parse_args(argv)

    house = House.model_validate_json(Path(a.house).read_text())
    problems = house.validate_refs()
    if problems:
        ap.error("invalid house: " + "; ".join(problems))
    cat, clients = generic_catalogue(), generic_clients()
    ctx = Context(house, cat, clients[a.client], step=a.grid)
    cfg = PlanConfig(equipment=tuple(a.equipment), k_max=a.k_max, candidate_step=a.step,
                     policy=Policy(trust_unknown_jacks=a.trust_unknown_jacks))
    try:
        results = search(ctx, cfg, cat, progress=lambda m: print(m, flush=True))
    except ValueError as e:
        ap.error(str(e))
    front = pareto(results)
    gw = Placement(cfg.gateway_equipment, house.entry.position, house.entry.level, cfg.gateway_height)
    print("\nbest arrangements (score = weighted zone utility, 0..1):")
    for i, r in enumerate(results[:8]):
        pos = ", ".join(f"({p.position[0]:.1f},{p.position[1]:.1f}@{p.level})" for p in r.extras) or "gateway only"
        print(f"{i + 1}. k={r.k} {r.equipment} score {r.score:.3f} (margin {r.score_margin:.3f}) worst {r.worst:.2f} cost {r.cost:.0f}"
              f"{'' if r.valid else ' INVALID'}{'' if r.must_ok else ' MUST-ZONE-UNMET'} [{pos}]")
    print(f"\nPareto front: {len(front)} arrangements")
    if len(results) > 1:
        ex = explain(ctx, gw, results[0], results[1], cfg)
        print("\nwhy #1:")
        for line in ex.lines:
            print(" -", line)
    if a.json:
        out = Path(a.json).resolve()
        if out == ROOT or ROOT in out.parents:
            ap.error("--json must be outside the repository")
        out.write_text(json.dumps([{"equipment": r.equipment, "score": r.score, "score_margin": r.score_margin, "worst": r.worst,
                                    "cost": r.cost, "valid": r.valid, "must_ok": r.must_ok,
                                    "nodes": [{"position": p.position, "level": p.level, "height": p.height} for p in r.extras]}
                                   for r in results], indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
