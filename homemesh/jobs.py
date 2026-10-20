"""Plan jobs: run the planner in a worker thread, keep progress, store the result.

Results are written under the house's `runs/` directory in the data directory
(derived data: a run can always be recomputed). One worker at a time: a plan
uses every core numpy gives it and the box is shared.
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import store
from .equipment import Equipment, generic_catalogue, generic_clients
from .explain import explain
from .model import House
from .network import Context, Evaluation, Placement, Policy
from .planner import PlanConfig, Scored, pareto, search
from .propagation import level_z


@dataclass
class Job:
    id: str
    house: str
    state: str = "running"  # running | done | error
    progress: list[str] = field(default_factory=list)
    error: str | None = None
    result: dict | None = None
    started: float = field(default_factory=time.time)


_JOBS: dict[str, Job] = {}
_LOCK = threading.Lock()
_POOL = ThreadPoolExecutor(max_workers=1)
EXPLAIN_TOP = 5


def serialise(sc: Scored, ev: Evaluation | None = None) -> dict:
    ev = ev or sc.evaluation
    return {
        "equipment": sc.equipment, "k": sc.k, "score": sc.score, "score_margin": sc.score_margin, "worst": sc.worst,
        "cost": sc.cost, "valid": sc.valid, "must_ok": sc.must_ok, "stable": sc.stable,
        "nodes": [{"equipment": p.equipment, "position": list(p.position), "level": p.level, "height": p.height} for p in sc.extras],
        "zones": [{"zone": z.zone, "utility": z.utility, "utility_margin": z.utility_margin, "mean_rate": z.mean_rate,
                   "frac_target": z.frac_target, "must_met": z.must_met} for z in sc.zones],
        "backhaul": [{"index": n.index, "kind": n.kind, "parent": n.parent, "mbps": None if n.backhaul_mbps == float("inf") else n.backhaul_mbps,
                      "hops": n.hops, "jack": n.jack, "band": n.link_band, "shared": n.shared_radio} for n in ev.nodes] if ev else [],
        "problems": ev.problems if ev else [],
        "jacks_used": ev.jacks_used if ev else [], "jacks_unverified": ev.jacks_unverified if ev else [],
    }


def make_config(req: dict) -> PlanConfig:
    return PlanConfig(
        gateway_equipment=req.get("gateway_equipment", "generic-router-ax"),
        equipment=tuple(req.get("equipment", [])),
        k_max=int(min(max(req.get("k_max", 5), 0), 8)),
        price_ceiling=req.get("price_ceiling"),
        policy=Policy(trust_unknown_jacks=bool(req.get("trust_unknown_jacks", False))),
        candidate_step=float(min(max(req.get("candidate_step", 1.0), 0.25), 3.0)),
    )


def make_context(house: House, req: dict, catalogue: dict[str, Equipment]) -> Context:
    clients = generic_clients()
    client = clients.get(req.get("client", "phone-2x2-ax"))
    if client is None:
        raise ValueError("unknown client")
    return Context(house, catalogue, client, step=float(min(max(req.get("grid", 1.0), 0.25), 2.0)))


def _run(job: Job, house: House, req: dict) -> None:
    try:
        cat = generic_catalogue()
        cfg = make_config(req)
        for name in (cfg.gateway_equipment, *cfg.equipment):
            if name not in cat:
                raise ValueError(f"unknown equipment {name}")
        ctx = make_context(house, req, cat)
        log = job.progress.append
        results = search(ctx, cfg, cat, progress=log)
        front = pareto(results)
        gw = Placement(cfg.gateway_equipment, house.entry.position, house.entry.level, cfg.gateway_height)  # type: ignore[union-attr]
        top = results[:20]
        out = []
        for i, sc in enumerate(top):
            d = serialise(sc)
            d["pareto"] = any(sc is f for f in front)
            if i < EXPLAIN_TOP and i + 1 < len(results):
                log(f"explaining #{i + 1}")
                ex = explain(ctx, gw, sc, results[i + 1], cfg, samples=12)
                d["explanation"] = {"lines": ex.lines, "stability": ex.stability,
                                    "node_contribution": [[n, c] for n, c in ex.node_contribution],
                                    "zones": [{"zone": z.zone, "limiter": z.limiter, "detail": z.detail} for z in ex.zones]}
            out.append(d)
        job.result = {"gateway": {"equipment": gw.equipment, "position": list(gw.position), "level": gw.level, "height": gw.height},
                      "config": {"k_max": cfg.k_max, "equipment": list(cfg.equipment), "client": req.get("client", "phone-2x2-ax"),
                                 "trust_unknown_jacks": cfg.policy.trust_unknown_jacks},
                      "results": out}
        run = Path(store.data_dir()) / "houses" / house.id / "runs"
        run.mkdir(parents=True, exist_ok=True)
        (run / f"{job.id}.json").write_text(json.dumps({"house_revision": house.revision, **job.result}))
        job.state = "done"
    except Exception as e:  # reported to the caller; never logged with house data
        job.error = f"{type(e).__name__}: {e}"
        job.state = "error"


def start(house: House, req: dict) -> Job:
    job = Job(id=uuid.uuid4().hex[:12], house=house.id)
    with _LOCK:
        _JOBS[job.id] = job
        for old in [j for j in _JOBS.values() if j.state != "running" and time.time() - j.started > 3600]:
            _JOBS.pop(old.id, None)
    _POOL.submit(_run, job, house, req)
    return job


def get(job_id: str) -> Job | None:
    return _JOBS.get(job_id)


def rate_map(house: House, req: dict) -> dict:
    """Per-level client-rate grids for a given arrangement (for the comparison view)."""
    from .network import evaluate

    cat = generic_catalogue()
    ctx = make_context(house, req, cat)
    cfg = make_config(req)
    if house.entry is None:
        raise ValueError("the house has no internet entry")
    gw = Placement(cfg.gateway_equipment, house.entry.position, house.entry.level, cfg.gateway_height)
    extras = []
    for n in req.get("nodes", []):
        if n["equipment"] not in cat or n["level"] not in level_z(house):
            raise ValueError("bad node")
        extras.append(Placement(n["equipment"], (float(n["position"][0]), float(n["position"][1])), n["level"], float(n["height"])))
    ev = evaluate(ctx, gw, extras, cfg.policy)
    grids = []
    for gi, g in enumerate(ctx.grids):
        sel = ctx.cell_level == gi
        grids.append({"level": g.level, "x0": g.x0, "y0": g.y0, "step": g.step, "nx": g.nx, "ny": g.ny,
                      "rate": np.where(ctx.cell_ok[sel], ev.rate[sel], np.nan).astype("float32").tolist(),
                      "serving": ev.serving[sel].tolist()})
    return {"grids": grids, "problems": ev.problems}
