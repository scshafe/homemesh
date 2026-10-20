import unittest

import numpy as np

from homemesh import fixtures
from homemesh.equipment import generic_catalogue, generic_clients
from homemesh.explain import explain
from homemesh.model import Need, Outlet, Zone
from homemesh.network import Context, Placement, Policy, evaluate
from homemesh.planner import PlanConfig, candidates, pareto, representatives, score, search
from homemesh.propagation import Params

CAT = generic_catalogue()
CLIENT = generic_clients()["phone-2x2-ax"]
N35 = Params(n={"2.4": 3.5, "5": 3.5, "6": 3.5})
BOX = [(0, 0), (30, 0), (30, 4), (0, 4)]


def house(allow=BOX, forbid=(), **kw):
    h = fixtures.long_thin()
    h.entry.wan_down = 1000.0
    h.zones[0].need.min_throughput = 400.0  # the far end needs more than the gateway gives it
    h.zones = [z for z in h.zones if z.kind == "demand"]
    zs = [Zone(id="a", level="L0", kind="allow", polygon=allow, **kw)]
    zs += [Zone(id=f"f{i}", level="L0", kind="forbid", polygon=list(p)) for i, p in enumerate(forbid)]
    h.zones = zs + h.zones
    return h


class CandidateTest(unittest.TestCase):
    def test_grid_inside_allow_only(self):
        c = candidates(house(allow=[(0, 0), (10, 0), (10, 4), (0, 4)]), step=1.0)
        self.assertTrue(c)
        self.assertTrue(all(0 < p.position[0] < 10 for p in c))

    def test_forbid_removes_spots(self):
        h = house(forbid=[[(4, 0), (6, 0), (6, 4), (4, 4)]])
        c = candidates(h, step=1.0)
        self.assertFalse(any(4 <= p.position[0] <= 6 for p in c))

    def test_outlet_requirement(self):
        h = house(requires="outlet")
        self.assertEqual(candidates(h, 1.0), [])
        h.outlets = [Outlet(id="o", position=(10, 2), level="L0")]
        c = candidates(h, 1.0)
        self.assertTrue(c)
        self.assertTrue(all(abs(p.position[0] - 10) <= 1.5 for p in c))

    def test_single_point_zone_and_heights(self):
        h = house(allow=[(5, 2)], heights=[0.3, 2.2])
        c = candidates(h, 1.0)
        self.assertEqual(sorted(p.height for p in c), [0.3, 2.2])

    def test_jack_inside_allow_zone_is_a_candidate(self):
        h = fixtures.wired_ends()
        h.zones = [Zone(id="a", level="L0", kind="allow", polygon=[(0, 0), (30, 0), (30, 4), (0, 4)])] + [z for z in h.zones if z.kind != "allow"]
        pos = {p.position for p in candidates(h, 5.0)}
        self.assertIn((0.2, 3.0), pos)


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.h = house()
        self.ctx = Context(self.h, CAT, CLIENT, params=N35, step=1.0)
        self.cfg = PlanConfig(equipment=("generic-mesh-tri",), k_max=2, candidate_step=3.0,
                              gateway_equipment="generic-mesh-tri", max_representatives=12)

    def test_more_nodes_do_not_hurt_and_far_zone_gets_better(self):
        res = search(self.ctx, self.cfg, CAT)
        by_k = {}
        for r in res:
            by_k.setdefault(r.k, r)
        self.assertGreaterEqual(by_k[1].score, by_k[0].score)
        self.assertGreaterEqual(by_k[2].score, by_k[1].score)
        self.assertGreater(by_k[1].score, by_k[0].score)

    def test_deterministic(self):
        a = [(r.k, r.score, [p.position for p in r.extras]) for r in search(self.ctx, self.cfg, CAT)]
        b = [(r.k, r.score, [p.position for p in r.extras]) for r in search(self.ctx, self.cfg, CAT)]
        self.assertEqual(a, b)

    def test_best_is_not_beaten_by_any_single_alternative(self):
        res = search(self.ctx, self.cfg, CAT)
        best1 = next(r for r in res if r.k == 1)
        gw = Placement(self.cfg.gateway_equipment, self.h.entry.position, "L0", self.cfg.gateway_height)
        for c in candidates(self.h, self.cfg.candidate_step):
            alt = score(self.ctx, gw, [Placement("generic-mesh-tri", c.position, c.level, c.height)], "generic-mesh-tri", self.cfg)
            self.assertLessEqual(alt.score, best1.score + 1e-9)

    def test_price_ceiling_invalidates(self):
        cfg = PlanConfig(equipment=("generic-mesh-tri",), k_max=1, candidate_step=3.0, gateway_equipment="generic-mesh-tri",
                         max_representatives=8, price_ceiling=200.0)  # gateway 180 + node 180 > 200
        res = search(self.ctx, cfg, CAT)
        self.assertTrue(all(not r.valid for r in res if r.k == 1))
        self.assertTrue(res[0].valid and res[0].k == 0)

    def test_greedy_path_for_large_spaces(self):
        cfg = PlanConfig(equipment=("generic-mesh-tri",), k_max=2, candidate_step=3.0, gateway_equipment="generic-mesh-tri",
                         max_representatives=12, exhaustive_limit=1)
        res = search(self.ctx, cfg, CAT)
        ex = search(self.ctx, self.cfg, CAT)
        self.assertGreater(max(r.score for r in res if r.k == 2), 0.0)
        self.assertGreaterEqual(max(r.score for r in ex if r.k == 2) + 1e-9, 0.0)

    def test_errors_are_clear(self):
        h = fixtures.long_thin()
        h.zones = [z for z in h.zones if z.kind != "allow"]
        with self.assertRaises(ValueError):
            search(Context(h, CAT, CLIENT, step=2.0), self.cfg, CAT)
        h2 = house()
        h2.entry = None
        with self.assertRaises(ValueError):
            search(Context(h2, CAT, CLIENT, step=2.0), self.cfg, CAT)

    def test_pareto_has_no_dominated_member(self):
        res = search(self.ctx, self.cfg, CAT)
        front = pareto(res)
        self.assertTrue(front)
        for a in front:
            for b in front:
                dominated = (b.score >= a.score and b.worst >= a.worst and b.cost <= a.cost) and (
                    b.score > a.score or b.worst > a.worst or b.cost < a.cost)
                self.assertFalse(dominated)

    def test_representatives_include_kept(self):
        cands = candidates(self.h, 1.0)
        reps = representatives(self.ctx, cands, 10, keep={3})
        self.assertIn(3, reps)
        self.assertLessEqual(len(reps), 10)


class ExplainTest(unittest.TestCase):
    def test_explanation_is_grounded(self):
        h = house()
        ctx = Context(h, CAT, CLIENT, params=N35, step=1.0)
        cfg = PlanConfig(equipment=("generic-mesh-tri",), k_max=1, candidate_step=3.0, gateway_equipment="generic-mesh-tri", max_representatives=10)
        res = search(ctx, cfg, CAT)
        gw = Placement(cfg.gateway_equipment, h.entry.position, h.entry.level, cfg.gateway_height)
        ex = explain(ctx, gw, res[0], res[1], cfg, samples=4)
        self.assertEqual(ex.zones[0].zone, "z-far")
        self.assertIn(ex.zones[0].limiter, {"access", "backhaul", "wan", "no signal"})
        self.assertEqual(len(ex.node_contribution), res[0].k)
        if res[0].k:
            self.assertGreaterEqual(ex.node_contribution[0][1], 0.0)
        self.assertTrue(ex.lines)
        self.assertTrue(0.0 <= ex.stability <= 1.0)


if __name__ == "__main__":
    unittest.main()
