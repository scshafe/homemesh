import math
import unittest

from homemesh import place
from homemesh.materials import default_materials
from homemesh.model import House, Level, Slab, Stair
from homemesh.roomplan import import_capture, stair_footprints
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
        p = place.propose(house, upper, "L1", "U" * 64)
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
        p = place.propose(house, wrap(room(0, 0, 4, 3, "B")), "L1", "B" * 64)
        self.assertEqual(p["confidence"], "auto")   # an empty floor with no staircase to go by keeps its frame


if __name__ == "__main__":
    unittest.main()
