import unittest

import numpy as np

from homemesh import fixtures
from homemesh.equipment import generic_catalogue, generic_clients
from homemesh.model import Entry, House, Level, Wall
from homemesh.materials import default_materials
from homemesh.propagation import Params
from homemesh.network import Context, Placement, Policy, evaluate, link_rate, path_rate, wired_at, zone_scores

CAT = generic_catalogue()
CLIENT = generic_clients()["phone-2x2-ax"]
GW = Placement("generic-router-ax", (0.5, 2.0), "L0", 1.2)


N35 = Params(n={"2.4": 3.5, "5": 3.5, "6": 3.5})  # indoor-ish exponent so a 30 m house is not covered from one end


def ctx(house, step=1.0):
    return Context(house, CAT, CLIENT, params=N35, step=step)


def rate_at(c: Context, ev, x, y):
    i = np.argmin(np.hypot(c.cells[:, 0] - x, c.cells[:, 1] - y))
    return float(ev.rate[i])


class GatewayOnly(unittest.TestCase):
    def test_rate_falls_with_distance_and_is_deterministic(self):
        c = ctx(fixtures.long_thin())
        a = evaluate(c, GW, [])
        b = evaluate(c, GW, [])
        self.assertTrue(np.array_equal(a.rate, b.rate))
        self.assertGreater(rate_at(c, a, 2.5, 2), rate_at(c, a, 28.5, 2))
        self.assertTrue(a.valid)
        self.assertEqual([n.kind for n in a.nodes], ["gateway"])

    def test_cost_is_sum_of_prices(self):
        c = ctx(fixtures.long_thin())
        ev = evaluate(c, GW, [Placement("generic-mesh-ax", (15, 2), "L0")])
        self.assertEqual(ev.cost, 120 + 100)


class Wireless(unittest.TestCase):
    def test_relay_improves_far_end(self):
        c = ctx(fixtures.long_thin())
        gw_tri = Placement("generic-mesh-tri", (0.5, 2.0), "L0", 1.2)
        mid = Placement("generic-mesh-tri", (20, 2), "L0")
        base = evaluate(c, gw_tri, [])
        ev = evaluate(c, gw_tri, [mid])
        n = ev.nodes[1]
        self.assertEqual((n.kind, n.parent, n.hops), ("wireless", 0, 1))
        self.assertGreater(n.backhaul_mbps, 0)
        self.assertGreater(rate_at(c, ev, 27.5, 2), rate_at(c, base, 27.5, 2))

    def test_dedicated_radio_beats_shared_near_the_node(self):
        c = ctx(fixtures.long_thin())
        shared = evaluate(c, GW, [Placement("generic-mesh-ax", (14, 2), "L0")])
        gw_tri = Placement("generic-mesh-tri", (0.5, 2.0), "L0", 1.2)  # a dedicated link needs the same system at both ends
        dedicated = evaluate(c, gw_tri, [Placement("generic-mesh-tri", (14, 2), "L0")])
        self.assertTrue(shared.nodes[1].shared_radio)
        self.assertFalse(dedicated.nodes[1].shared_radio)
        self.assertGreater(rate_at(c, dedicated, 14.5, 2), rate_at(c, shared, 14.5, 2))

    def test_unreachable_node_is_a_problem(self):
        walls = [Wall(id=f"w{i}", level="L0", a=(i * 100.0, 0), b=(i * 100.0, 5), thickness=0.2, height=2.5, material="brick") for i in range(4)]
        h = House(id="far", name="far", synthetic=True, levels=[Level(id="L0", name="g", elevation=0, height=2.5)],
                  materials=default_materials(), walls=walls, entry=Entry(position=(1, 2), level="L0"))
        c = Context(h, CAT, CLIENT, params=N35, step=50.0)
        ev = evaluate(c, Placement("generic-router-ax", (1, 2), "L0"), [Placement("generic-mesh-ax", (2000, 2), "L0")])
        self.assertFalse(ev.valid)
        self.assertEqual(ev.nodes[1].kind, "disconnected")

    def test_hop_limit(self):
        c = ctx(fixtures.long_thin())
        chain = [Placement("generic-mesh-tri", (x, 2), "L0") for x in (8, 16, 24, 29)]
        ev = evaluate(c, GW, chain[:3])
        self.assertTrue(all(n.hops <= 3 for n in ev.nodes))

    def test_system_node_limit(self):
        c = ctx(fixtures.long_thin())
        many = [Placement("generic-mesh-ax", (2 + i * 3, 2), "L0") for i in range(6)]  # 7 nodes with the gateway
        ev = evaluate(c, GW, many)
        self.assertTrue(any("at most 6" in p for p in ev.problems))


class Wired(unittest.TestCase):
    def test_live_jack_makes_a_wired_node(self):
        h = fixtures.wired_ends()
        near = Placement("generic-mesh-ax", (0.3, 3.0), "L0")
        w = wired_at(h, near, trust_unknown=False)
        self.assertEqual((w[1], w[2]), ("j0", True))
        self.assertEqual(w[0], 1000.0)  # cat6 2500, switch port 1000

    def test_unknown_jack_dead_in_base_alive_in_variant(self):
        h = fixtures.wired_ends()
        far = Placement("generic-mesh-ax", (29.7, 1.0), "L0")
        self.assertIsNone(wired_at(h, far, trust_unknown=False))
        w = wired_at(h, far, trust_unknown=True)
        self.assertEqual((w[1], w[2]), ("j1", False))

    def test_wired_far_node_beats_wireless_relay_and_reports_the_jack(self):
        h = fixtures.wired_ends()
        c = ctx(h)
        far = Placement("generic-mesh-ax", (29.7, 1.0), "L0")
        base = evaluate(c, GW, [far])
        var = evaluate(c, GW, [far], Policy(trust_unknown_jacks=True))
        self.assertEqual(base.nodes[1].kind, "wireless")
        self.assertEqual(var.nodes[1].kind, "wired")
        self.assertEqual(var.jacks_unverified, ["j1"])
        self.assertEqual(var.nodes[1].hops, 0)
        self.assertGreater(rate_at(c, var, 28.5, 2), rate_at(c, base, 28.5, 2))

    def test_measured_rate_overrides_type(self):
        h = fixtures.wired_ends()
        h.jacks[0].measured_rate = 300.0
        w = wired_at(h, Placement("generic-mesh-ax", (0.3, 3.0), "L0"), False)
        self.assertEqual(w[0], 300.0)

    def test_jack_without_switch_chain_is_unusable(self):
        h = fixtures.wired_ends()
        h.jacks[0].switch = None
        self.assertIsNone(wired_at(h, Placement("generic-mesh-ax", (0.3, 3.0), "L0"), True))

    def test_wan_caps_wired_backhaul(self):
        h = fixtures.wired_ends()
        h.entry.wan_down = 200.0
        ev = evaluate(ctx(h), GW, [Placement("generic-mesh-ax", (0.3, 3.0), "L0")])
        self.assertEqual(ev.nodes[1].backhaul_mbps, 200.0)
        self.assertLessEqual(float(ev.rate.max()), 200.0 + 1e-6)


class PathRate(unittest.TestCase):
    def setUp(self):
        self.c = ctx(fixtures.long_thin())

    def test_single_hop_and_empty(self):
        a, b = Placement("generic-mesh-ax", (0, 2), "L0"), Placement("generic-mesh-ax", (5, 2), "L0")
        self.assertEqual(path_rate(self.c, [(a, b, 400.0, "5")]), 400.0)
        self.assertEqual(path_rate(self.c, []), float("inf"))

    def test_adjacent_hops_halve(self):
        p = [Placement("generic-mesh-ax", (x, 2), "L0") for x in (0, 5, 10)]
        r = path_rate(self.c, [(p[0], p[1], 400.0, "5"), (p[1], p[2], 400.0, "5")])
        self.assertAlmostEqual(r, 200.0)

    def test_different_bands_do_not_share(self):
        p = [Placement("generic-mesh-ax", (x, 2), "L0") for x in (0, 5, 10)]
        r = path_rate(self.c, [(p[0], p[1], 400.0, "5"), (p[1], p[2], 300.0, "2.4")])
        self.assertAlmostEqual(r, 300.0)

    def test_far_apart_hops_do_not_share(self):
        p = [Placement("generic-mesh-ax", (x, 2), "L0") for x in (0, 1, 2, 3)]
        far = [Placement("generic-mesh-ax", (x, 2), "L0") for x in (0, 1, 29, 30)]
        r_near = path_rate(self.c, [(p[0], p[1], 400.0, "5"), (p[2], p[3], 400.0, "5")])
        self.assertAlmostEqual(r_near, 200.0)
        from homemesh import network
        old, network.CARRIER_SENSE_LOSS_DB = network.CARRIER_SENSE_LOSS_DB, 60.0
        self.addCleanup(setattr, network, "CARRIER_SENSE_LOSS_DB", old)
        r_far = path_rate(self.c, [(far[0], far[1], 400.0, "5"), (far[2], far[3], 400.0, "5")])
        self.assertGreater(r_far, 200.0)

    def test_link_rate_falls_with_distance(self):
        pol = Policy()
        a = Placement("generic-mesh-ax", (1, 2), "L0")
        near = link_rate(self.c, a, Placement("generic-mesh-ax", (4, 2), "L0"), pol)
        far = link_rate(self.c, a, Placement("generic-mesh-ax", (25, 2), "L0"), pol)
        self.assertGreater(near[0], far[0] if far else 0)


class Zones(unittest.TestCase):
    def test_utility_and_must(self):
        h = fixtures.long_thin()
        c = ctx(h)
        gw_only = evaluate(c, GW, [])
        zs = zone_scores(c, gw_only, evaluate(c, GW, [], margin=6.0))
        z = zs[0]
        self.assertEqual(z.zone, "z-far")
        self.assertTrue(0.0 <= z.utility_margin <= z.utility <= 1.0)
        with_relay = evaluate(c, GW, [Placement("generic-mesh-tri", (24, 2), "L0")])
        z2 = zone_scores(c, with_relay, evaluate(c, GW, [Placement("generic-mesh-tri", (24, 2), "L0")], margin=6.0))[0]
        self.assertGreaterEqual(z2.utility, z.utility)

    def test_must_flag(self):
        h = fixtures.one_floor_box()
        c = ctx(h, 0.5)
        gw = Placement("generic-router-ax", (0.5, 0.5), "L0")
        zs = zone_scores(c, evaluate(c, gw, []), evaluate(c, gw, [], margin=6.0))
        self.assertIn(zs[0].must_met, (True, False))


if __name__ == "__main__":
    unittest.main()
