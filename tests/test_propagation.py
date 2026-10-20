import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

from homemesh import fixtures, sim
from homemesh.materials import default_materials
from homemesh.model import House, Level, Opening, Slab, SlabHole, Stair, Wall
from homemesh.propagation import (
    Params, Tx, explain_point, free_space_1m, grid_mask, level_grid, path_loss, rssi_map,
)


def house(walls=(), levels=None, **kw) -> House:
    return House(id="t", name="t", synthetic=True,
                 levels=levels or [Level(id="L0", name="g", elevation=0.0, height=2.5)],
                 materials=default_materials(), walls=list(walls), **kw)


def wall(id="w", a=(5, -5), b=(5, 5), t=0.1, mat="drywall", level="L0", **kw) -> Wall:
    return Wall(id=id, level=level, a=a, b=b, thickness=t, height=2.5, material=mat, **kw)


def pl(h, tx, rx, band="2.4", params=Params()):
    return float(path_loss(h, tx, np.array([rx]), band, params)[0])


class FreeSpaceTest(unittest.TestCase):
    def test_pl0_values(self):
        self.assertAlmostEqual(free_space_1m("2.4"), 20 * math.log10(2437) - 27.56)

    def test_ten_metres_n2(self):
        h = house()
        expect = free_space_1m("2.4") + 20.0
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1)), expect, places=6)

    def test_min_distance_one_metre(self):
        h = house()
        self.assertAlmostEqual(pl(h, (0, 0, 1), (0.1, 0, 1)), free_space_1m("2.4"), places=6)

    def test_exponent_param(self):
        h = house()
        p = Params(n={"2.4": 3.0, "5": 2.0, "6": 2.0})
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1), params=p), free_space_1m("2.4") + 30.0, places=6)


class WallTest(unittest.TestCase):
    def test_one_wall_costs_material_loss(self):
        h = house([wall()])
        base = pl(house(), (0, 0, 1), (10, 0, 1))
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1)) - base, 3.0, places=6)
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1), "5") - pl(house(), (0, 0, 1), (10, 0, 1), "5"), 4.0, places=6)

    def test_thickness_scales(self):
        h = house([wall(t=0.2)])
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1)) - pl(house(), (0, 0, 1), (10, 0, 1)), 6.0, places=6)

    def test_oblique_incidence_scales_and_caps(self):
        base = pl(house(), (0, 0, 1), (10, 10, 1))
        # 45 degrees: loss / cos 45
        got = pl(house([wall()]), (0, 0, 1), (10, 10, 1)) - base
        self.assertAlmostEqual(got, 3.0 / math.cos(math.radians(45)), places=6)
        # grazing: capped at cos 70
        h = house([wall(a=(5, -50), b=(5, 50))])
        tx, rx = (4.99, 0, 1), (5.01, 40, 1)
        got = pl(h, tx, rx) - pl(house(), tx, rx)
        self.assertAlmostEqual(got, 3.0 / math.cos(math.radians(70)), places=6)

    def test_wall_not_between_costs_nothing(self):
        h = house([wall()])
        self.assertAlmostEqual(pl(h, (0, 0, 1), (4, 0, 1)), pl(house(), (0, 0, 1), (4, 0, 1)))
        self.assertAlmostEqual(pl(h, (6, 0, 1), (10, 0, 1)), pl(house(), (6, 0, 1), (10, 0, 1)))

    def test_ray_over_wall_height_costs_nothing(self):
        h = house([wall()])
        self.assertAlmostEqual(pl(h, (0, 0, 3.5), (10, 0, 3.5)), pl(house(), (0, 0, 3.5), (10, 0, 3.5)))

    def test_two_walls_add(self):
        h = house([wall("a"), wall("b", a=(7, -5), b=(7, 5), mat="brick", t=0.2)])
        self.assertAlmostEqual(pl(h, (0, 0, 1), (10, 0, 1)) - pl(house(), (0, 0, 1), (10, 0, 1)), 3.0 + 7.0, places=6)

    def test_parallel_ray_along_wall_ignored(self):
        h = house([wall()])
        self.assertAlmostEqual(pl(h, (5, -3, 1), (5, 3, 1)), pl(house(), (5, -3, 1), (5, 3, 1)))


class OpeningTest(unittest.TestCase):
    def door(self, state="closed", mat="wood-door"):
        # wall along y from -5 to 5; door spans 4..5 m along the wall => y in [-1, 0]
        return wall(openings=[Opening(kind="door", offset=4.0, width=1.0, height=2.0, material=mat, state=state)])

    def test_opening_beats_wall(self):
        h = house([self.door()])
        base = pl(house(), (0, -0.5, 1), (10, -0.5, 1))
        through_door = pl(h, (0, -0.5, 1), (10, -0.5, 1)) - base
        self.assertAlmostEqual(through_door, 3.0, places=6)  # wooden door unit loss
        h2 = house([wall(mat="brick", t=0.2, openings=self.door().openings)])
        self.assertAlmostEqual(pl(h2, (0, -0.5, 1), (10, -0.5, 1)) - base, 3.0, places=6)
        through_wall = pl(h2, (0, 3, 1), (10, 3, 1)) - pl(house(), (0, 3, 1), (10, 3, 1))
        self.assertAlmostEqual(through_wall, 7.0, places=6)

    def test_above_door_is_wall(self):
        h = house([wall(mat="brick", t=0.2, openings=self.door().openings)])
        self.assertAlmostEqual(pl(h, (0, -0.5, 2.3), (10, -0.5, 2.3)) - pl(house(), (0, -0.5, 2.3), (10, -0.5, 2.3)), 7.0, places=6)

    def test_open_door_and_air_free(self):
        for h in (house([self.door("open")]), house([self.door(mat="air")])):
            self.assertAlmostEqual(pl(h, (0, -0.5, 1), (10, -0.5, 1)), pl(house(), (0, -0.5, 1), (10, -0.5, 1)))


class SlabTest(unittest.TestCase):
    levels = [Level(id="L0", name="g", elevation=0.0, height=2.6),
              Level(id="L1", name="f", elevation=2.9, height=2.6, slab=Slab(material="slab-wood", thickness=0.3))]

    def test_one_slab(self):
        h = house(levels=self.levels)
        got = pl(h, (0, 0, 1), (4, 0, 3.9)) - pl(house(), (0, 0, 1), (4, 0, 3.9))
        self.assertAlmostEqual(got, 9.0, places=6)
        self.assertAlmostEqual(pl(h, (0, 0, 3.5), (4, 0, 3.9)), pl(house(), (0, 0, 3.5), (4, 0, 3.9)))

    def test_symmetric(self):
        h = house(levels=self.levels)
        self.assertAlmostEqual(pl(h, (0, 0, 1), (4, 0, 3.9)), pl(h, (4, 0, 3.9), (0, 0, 1)))

    def test_hole_free_and_stair_void(self):
        poly = [(3, -1), (5, -1), (5, 1), (3, 1)]
        for kw in ({"slab_holes": [SlabHole(id="h", level="L1", polygon=poly)]},
                   {"stairs": [Stair(id="s", from_level="L0", to_level="L1", polygon=poly)]}):
            h = house(levels=self.levels, **kw)
            # crossing at x = (2.9-1)/(3.9-1)*... pick the point so the crossing lies in the hole
            tx, rx = (3.0, 0, 1.0), (5.0, 0, 3.9)
            s = (2.9 - 1.0) / (3.9 - 1.0)
            self.assertTrue(3 < 3 + s * 2 < 5)
            self.assertAlmostEqual(pl(h, tx, rx), pl(house(), tx, rx))
            # same endpoints shifted so the crossing is outside the hole pays the slab
            tx2, rx2 = (-6.0, 0, 1.0), (-4.0, 0, 3.9)
            self.assertAlmostEqual(pl(h, tx2, rx2) - pl(house(), tx2, rx2), 9.0, places=6)


class ExplainTest(unittest.TestCase):
    def test_terms_largest_first(self):
        h = house([wall("a"), wall("b", a=(7, -5), b=(7, 5), mat="brick", t=0.2)])
        e = explain_point(h, (0, 0, 1), (10, 0, 1), "2.4")
        self.assertEqual([(k, i) for k, i, _ in e], [("wall", "b"), ("wall", "a")])
        self.assertAlmostEqual(sum(v for *_, v in e), 10.0, places=6)


class MapTest(unittest.TestCase):
    def test_map_shape_mask_and_values(self):
        h = fixtures.one_floor_box()
        g = level_grid(h, "L0", 0.5)
        self.assertEqual((g.nx, g.ny), (20, 16))
        m = rssi_map(h, Tx((2.5, 4.0), "L0"), "5", g)
        self.assertEqual(m.shape, (16, 20))
        mask = grid_mask(h, g).reshape(16, 20)
        self.assertTrue(np.isnan(m[~mask]).all())
        self.assertFalse(np.isnan(m[mask]).any())
        self.assertTrue(mask.any())

    def test_stronger_near_than_far_and_wall_step(self):
        h = fixtures.one_floor_box()
        g = level_grid(h, "L0", 0.5)
        m = rssi_map(h, Tx((2.5, 4.0), "L0"), "2.4", g)
        near, far = m[8, 4], m[8, 18]
        self.assertGreater(near, far)

    def test_two_floor_upper_floor_weaker_except_stairwell(self):
        h = fixtures.two_floor_stairwell()
        g1 = level_grid(h, "L1", 0.5)
        g0 = level_grid(h, "L0", 0.5)
        tx = Tx((1.0, 3.0), "L0", height=1.8)
        up = rssi_map(h, tx, "5", g1)
        down = rssi_map(h, tx, "5", g0)
        self.assertLess(np.nanmean(up), np.nanmean(down))

    def test_deterministic(self):
        h = fixtures.wired_ends()
        g = level_grid(h, "L0", 1.0)
        a = rssi_map(h, Tx((1, 2), "L0"), "6", g)
        b = rssi_map(h, Tx((1, 2), "L0"), "6", g)
        self.assertTrue(np.array_equal(a, b, equal_nan=True))


class CliTest(unittest.TestCase):
    def test_writes_grids(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(__file__).parent / "fixtures" / "one_floor_box.json"
            self.assertEqual(sim.main([str(src), d, "--tx", "2", "2", "L0", "--band", "5"]), 0)
            self.assertTrue((Path(d) / "L0-5.npy").exists())
            self.assertTrue((Path(d) / "meta.json").exists())

    def test_refuses_output_in_repo(self):
        src = Path(__file__).parent / "fixtures" / "one_floor_box.json"
        with self.assertRaises(SystemExit):
            sim.main([str(src), str(Path(__file__).parent.parent / "out"), "--tx", "2", "2", "L0"])


if __name__ == "__main__":
    unittest.main()
