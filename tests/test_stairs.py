import math
import unittest

from homemesh import place
from homemesh.materials import default_materials
from homemesh.model import House, Level, Slab, Stair
from homemesh.roomplan import apply_stair, import_capture, stair_footprints
from tests.roomplan_synth import room
from tests.test_place import moved, wrap


def with_stairs(r, cx, cz, w=1.0, d=3.0, rise=2.7, axis=(1, 0)):
    """A stairs object (ARKit x, z centre; w across, d long) in a synthetic room."""
    ux, uz = axis
    r["objects"].append({"identifier": "st", "category": {"stairs": {}}, "dimensions": [w, rise, d],
                         "transform": [ux, 0, uz, 0, 0, 1, 0, 0, -uz, 0, ux, 0, cx, 1.0, cz, 1]})
    return r


def two_level_house():
    return House(id="h", name="h", synthetic=True, materials=default_materials(),
                 levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5),
                         Level(id="L1", name="First", elevation=2.8, height=2.5, slab=Slab(material="slab-wood", thickness=0.3))])


def centroid(poly):
    return sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly)


class StairsTest(unittest.TestCase):
    def test_footprint_of_a_stairs_object(self):
        data = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5, w=1.0, d=3.0, axis=(0, 1)))
        (st,) = stair_footprints(data)
        xs, ys = [p[0] for p in st["polygon"]], [p[1] for p in st["polygon"]]
        self.assertAlmostEqual(max(xs) - min(xs), 3.0, places=2)   # d runs along the object's z axis; here its axis is turned
        self.assertAlmostEqual(max(ys) - min(ys), 1.0, places=2)
        self.assertAlmostEqual(st["rise"], 2.7)

    def test_import_suggests_the_stairs_in_plan_coordinates(self):
        data = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5))
        h, rep = import_capture(two_level_house(), data, "L0", "A" * 64)
        self.assertEqual(len(rep.stairs), 1)
        self.assertEqual(rep.stairs[0]["level"], "L0")
        cx, cy = centroid(rep.stairs[0]["polygon"])
        self.assertAlmostEqual((cx, cy), (2.0, -1.5), places=2)  # ARKit z becomes -Y
        self.assertEqual(h.stairs, [])                           # suggested, not saved

    def test_first_scan_of_a_floor_is_lined_up_by_the_staircase(self):
        house = two_level_house()
        lower = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5))
        house, rep = import_capture(house, lower, "L0", "A" * 64)
        poly = [tuple(p) for p in rep.stairs[0]["polygon"]]
        house = house.model_copy(update={"stairs": [Stair(id="s1", from_level="L0", to_level="L1", polygon=poly)]})
        # the upper floor, scanned in another session: its own room, the stairs at its own place and turn
        upper = moved(wrap(with_stairs(room(10, 10, 15, 14, "U"), 11.5, 12.0)), 53, 4, -2)
        p = place.propose(house, upper, "L1", "U" * 64, guess=True)
        self.assertEqual(p["confidence"], "confirm")
        self.assertEqual(p["evidence"]["stairs"], 1)
        t = p["transform"]
        scan_stair = stair_footprints(upper)[0]["polygon"]
        c = centroid(scan_stair)
        th = math.radians(t["rotation"])
        placed = (math.cos(th) * c[0] - math.sin(th) * c[1] + t["tx"], math.sin(th) * c[0] + math.cos(th) * c[1] + t["ty"])
        self.assertAlmostEqual(placed[0], centroid(poly)[0], places=1)
        self.assertAlmostEqual(placed[1], centroid(poly)[1], places=1)

    def test_no_stairs_no_stair_candidates(self):
        house = two_level_house()
        p = place.propose(house, wrap(room(0, 0, 4, 3, "B")), "L1", "B" * 64, guess=True)
        self.assertEqual(p["confidence"], "auto")   # an empty floor with no staircase to go by keeps its frame


if __name__ == "__main__":
    unittest.main()


class ApplyStairTest(unittest.TestCase):
    def house(self):
        h = two_level_house()
        return h

    def test_a_scan_with_a_staircase_and_floors_adds_the_stair_and_refines_the_height(self):
        data = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5, rise=3.1))
        meta = {"stair": {"from_level": "L0", "to_level": "L1"}}
        h, rep = import_capture(self.house(), data, "L0", "A" * 64)
        notes = []
        h = apply_stair(h, data, "A" * 64, meta, None, rep.stairs, notes)
        (st,) = h.stairs
        self.assertEqual((st.from_level, st.to_level, st.prov.ref), ("L0", "L1", "A" * 64 + "#stair"))
        lv = {x.id: x for x in h.levels}
        self.assertAlmostEqual(lv["L0"].height, 3.1 - 0.3, places=2)
        self.assertEqual(lv["L0"].height_source, "stair")
        self.assertAlmostEqual(lv["L1"].elevation - lv["L0"].elevation, 3.1, places=2)   # floor to floor is the measured rise
        self.assertTrue(any("rises 3.10 m" in n for n in notes))
        # importing again replaces the stair, never doubles it
        h = apply_stair(h, data, "A" * 64, meta, None, rep.stairs, [])
        self.assertEqual(len(h.stairs), 1)

    def test_without_the_floors_nothing_is_added(self):
        data = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5))
        h, rep = import_capture(self.house(), data, "L0", "A" * 64)
        self.assertEqual(apply_stair(h, data, "A" * 64, {}, None, rep.stairs, []).stairs, [])

    def test_a_stairs_scan_without_a_stairs_object_uses_its_footprint_and_says_so(self):
        data = wrap(room(0, 0, 4, 2, "A"))
        meta = {"stair": {"from_level": "L0", "to_level": "L1"}, "purpose": "stairs"}
        h, rep = import_capture(self.house(), data, "L0", "A" * 64, make_rooms=False)
        self.assertEqual(h.rooms, [])
        notes = []
        h = apply_stair(h, data, "A" * 64, meta, None, rep.stairs, notes)
        self.assertEqual(len(h.stairs), 1)
        self.assertGreaterEqual(len(h.stairs[0].polygon), 3)
        self.assertTrue(any("no stairs object" in n for n in notes))
        self.assertEqual({x.id: x.height for x in h.levels}["L0"], 2.5)   # no rise measured: heights stay


class RiseFeedsHeightsTest(unittest.TestCase):
    def test_measured_rises_set_the_floor_to_floor_heights_below_and_above_ground(self):
        from homemesh.model import Level
        h = House(id="h", name="h", synthetic=True, materials=default_materials(),
                  levels=[Level(id="B", name="Basement", elevation=-2.8, height=2.5, below_ground=True),
                          Level(id="G", name="Ground", elevation=0.0, height=2.5, slab=Slab(material="slab-wood", thickness=0.3)),
                          Level(id="U", name="Guest", elevation=2.8, height=2.5, slab=Slab(material="slab-wood", thickness=0.3))])
        for rise, a, b in ((2.714, "B", "G"), (3.34, "G", "U")):
            data = wrap(with_stairs(room(0, 0, 6, 4, "A"), 2.0, 1.5, rise=rise))
            tmp, rep = import_capture(h, data, a, "A" * 64)
            h = apply_stair(h, data, f"{a}" * 64, {"stair": {"from_level": a, "to_level": b}}, None, rep.stairs, [])
        e = {x.id: x.elevation for x in h.levels}
        self.assertAlmostEqual(e["B"], -2.714, places=2)
        self.assertAlmostEqual(e["U"], 3.34, places=2)
        self.assertAlmostEqual(e["G"], 0.0)

    def test_the_bottom_end_is_the_one_nearer_the_scans_door(self):
        data = wrap(with_stairs(room(0, 0, 6, 4, "A", doors=[(0.2, 1.5, 0, 1)]), 3.0, 1.5, w=1.0, d=3.0, axis=(0, 1)))
        h, rep = import_capture(two_level_house(), data, "L0", "A" * 64)
        h = apply_stair(h, data, "A" * 64, {"stair": {"from_level": "L0", "to_level": "L1"}}, None, rep.stairs, [])
        low = h.stairs[0].low
        self.assertIsNotNone(low)
        self.assertLess(low[0], 3.0)   # the west end, toward the door at x = 0.2
        none_h, rep2 = import_capture(two_level_house(), wrap(with_stairs(room(0, 0, 6, 4, "B"), 3.0, 1.5, d=3.0)), "L0", "B" * 64)
        none_h = apply_stair(none_h, wrap(with_stairs(room(0, 0, 6, 4, "B"), 3.0, 1.5, d=3.0)), "B" * 64,
                             {"stair": {"from_level": "L0", "to_level": "L1"}}, None, rep2.stairs, [])
        self.assertIsNone(none_h.stairs[0].low)   # no door: it is not guessed
