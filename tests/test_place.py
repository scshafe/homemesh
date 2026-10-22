import copy
import math
import unittest

import numpy as np

from homemesh import place
from homemesh.materials import default_materials
from homemesh.model import House, Level
from homemesh.roomplan import Similarity2D, import_capture
from tests.roomplan_synth import room, two_rooms


def moved(data, yaw_deg, dx, dz):
    """The same capture seen from another session: rotated about the vertical axis and shifted (ARKit x, z)."""
    out = copy.deepcopy(data)
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    for r in out["rooms"]:
        for key in ("walls", "doors", "windows", "openings"):
            for surf in r.get(key, []):
                t = surf["transform"]
                ux, uz, cx, cy, cz = t[0], t[2], t[12], t[13], t[14]
                nux, nuz = c * ux + s * uz, -s * ux + c * uz
                ncx, ncz = c * cx + s * cz + dx, -s * cx + c * cz + dz
                surf["transform"] = [nux, 0, nuz, 0, 0, 1, 0, 0, -nuz, 0, nux, 0, ncx, cy, ncz, 1]
    return out


def empty_house():
    return House(id="h", name="h", synthetic=True, levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)],
                 materials=default_materials())


def wrap(*rooms):
    return {"format": "homemesh-capture-1", "rooms": list(rooms)}


def centres(house, blob):
    return sorted(((w.a[0] + w.b[0]) / 2, (w.a[1] + w.b[1]) / 2) for w in house.walls if (w.prov.ref or "").startswith(blob))


def worst_gap(a, b):
    return max(min(math.hypot(p[0] - q[0], p[1] - q[1]) for q in b) for p in a)


class PlaceTest(unittest.TestCase):
    def setUp(self):
        both = two_rooms()["rooms"]
        self.a, self.b = both
        self.house, _ = import_capture(empty_house(), wrap(self.a), "L0", "A" * 64)  # room A is on the plan
        self.truth, _ = import_capture(empty_house(), wrap(self.b), "L0", "B" * 64)   # where B really is

    def placed(self, data, **kw):
        p = place.propose(self.house, data, "L0", "B" * 64, **kw, guess=True)
        h, _ = import_capture(self.house, data, "L0", "B" * 64, Similarity2D(1.0, **{k: p["transform"][k] for k in ("rotation", "tx", "ty")}))
        return p, h

    def test_second_room_found_by_the_shared_doorway(self):
        for yaw, dx, dz in [(0, 0, 0), (37, 5, -3), (90, -2, 4), (200, 1, 1), (-75, 8, 8)]:
            with self.subTest(yaw=yaw):
                p, h = self.placed(wrap(moved(wrap(self.b), yaw, dx, dz)["rooms"][0]))
                self.assertEqual(p["confidence"], "auto", p)
                self.assertGreaterEqual(p["evidence"]["openings"], 1)
                # the two sides of the shared wall are one wall thickness (0.12 m) apart in the doorway match
                self.assertLessEqual(worst_gap(centres(h, "B" * 64), centres(self.truth, "B" * 64)), 0.14)

    def labelled_house(self):
        house, _ = import_capture(empty_house(), wrap(self.a), "L0", "A" * 64, names=["Kitchen"])
        scan = wrap(moved(wrap(self.b), 37, 5, -3)["rooms"][0])
        # Kitchen's door says it leads to Pantry (the scan's room); the scan's door says it leads to Kitchen
        return house, scan, {"A" * 64 + "#A-door0": "Pantry"}

    def test_labelled_connection_is_the_placement(self):
        house, scan, plan_labels = self.labelled_house()
        p = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"], door_labels={"B-door0": "kitchen"}, plan_labels=plan_labels)
        self.assertEqual(p["confidence"], "labelled", p)
        self.assertEqual(p["evidence"]["connections"], 1)
        h, _ = import_capture(house, scan, "L0", "B" * 64, Similarity2D(1.0, **{k: p["transform"][k] for k in ("rotation", "tx", "ty")}))
        # the rooms are on opposite sides of the shared wall (no half-turn ambiguity) and the walls are one thickness apart
        self.assertLessEqual(worst_gap(centres(h, "B" * 64), centres(self.truth, "B" * 64)), 0.14)
        self.assertEqual(sum(1 for w in h.walls if (w.prov.ref or "").startswith("B" * 64)), 4)

    def test_without_both_labels_there_is_no_search_and_it_says_what_is_missing(self):
        house, scan, plan_labels = self.labelled_house()
        none = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"])
        self.assertEqual(none["confidence"], "unlabelled")
        self.assertIn("Label a door", none["reason"])
        self.assertEqual(none["transform"], {"rotation": 0.0, "tx": 0.0, "ty": 0.0})
        self.assertTrue(none["preview"])
        one_way = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"], door_labels={"B-door0": "Kitchen"})   # Kitchen's door is not labelled back
        self.assertEqual(one_way["confidence"], "unlabelled")
        self.assertTrue(any("no door labelled Pantry" in m for m in one_way["evidence"]["missing"]))
        elsewhere = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"], door_labels={"B-door0": "Garage"}, plan_labels=plan_labels)
        self.assertTrue(any("Garage is not on the plan" in m for m in elsewhere["evidence"]["missing"]))
        outside = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"], door_labels={"B-door0": "Outside"}, plan_labels=plan_labels)
        self.assertEqual(outside["confidence"], "unlabelled")
        # "Guess for me" is the old search
        self.assertEqual(place.propose(house, scan, "L0", "B" * 64, guess=True)["confidence"], "auto")

    def test_two_connections_are_fitted_together_and_report_their_residual(self):
        a = room(0, 0, 4, 3, "A", doors=[(4.0, 1.0, 0, 1), (4.0, 2.2, 0, 1)])
        b = room(4.12, 0, 8.12, 3, "B", doors=[(4.12, 1.0, 0, 1), (4.12, 2.2, 0, 1)])
        house, _ = import_capture(empty_house(), wrap(a), "L0", "A" * 64, names=["Kitchen"])
        scan = wrap(moved(wrap(b), 20, 2, 3)["rooms"][0])
        plan_labels = {"A" * 64 + "#A-door0": "Pantry", "A" * 64 + "#A-door1": "Pantry"}
        p = place.propose(house, scan, "L0", "B" * 64, names=["Pantry"], door_labels={"B-door0": "Kitchen", "B-door1": "Kitchen"}, plan_labels=plan_labels)
        self.assertEqual(p["evidence"]["connections"], 2, p)
        self.assertLessEqual(p["evidence"]["residual_cm"], 15)
        self.assertEqual(p["confidence"], "labelled")

    def test_rotation_is_snapped_to_the_plan(self):
        p, _ = self.placed(wrap(moved(wrap(self.b), 37.0, 2, 2)["rooms"][0]))
        self.assertAlmostEqual(p["transform"]["rotation"] % 90, (-37) % 90, delta=0.6)

    def test_no_shared_doorway_or_name_means_manual(self):
        bare_a = room(0, 0, 4, 3, "A")
        bare_b = moved(wrap(room(10, 0, 14, 3, "B")), 20, 3, 3)["rooms"][0]
        house, _ = import_capture(empty_house(), wrap(bare_a), "L0", "A" * 64)
        p = place.propose(house, wrap(bare_b), "L0", "B" * 64, guess=True)
        self.assertEqual(p["confidence"], "manual")
        self.assertEqual(p["transform"], {"rotation": 0.0, "tx": 0.0, "ty": 0.0})
        self.assertEqual(len(p["preview"]), 4)  # the app still shows the scan so it can be dragged into place

    def test_same_room_scanned_again_is_found_by_name(self):
        a2 = moved(wrap(self.a), 90, 3, 3)["rooms"][0]
        a2["name"] = "Kitchen"
        named = copy.deepcopy(self.a)
        named["name"] = "Kitchen"
        house, _ = import_capture(empty_house(), wrap(named), "L0", "A" * 64)
        p = place.propose(house, wrap(a2), "L0", "B" * 64, guess=True)
        self.assertGreaterEqual(p["evidence"]["named_rooms"], 1)
        self.assertIn(p["confidence"], ("auto", "confirm"))
        h, _ = import_capture(house, wrap(a2), "L0", "B" * 64, Similarity2D(1.0, **p["transform"]))
        self.assertLessEqual(worst_gap(centres(h, "B" * 64), centres(house, "A" * 64)), 0.1)

    def test_empty_plan_keeps_the_frame_and_squares_it_up(self):
        p = place.propose(empty_house(), wrap(moved(wrap(self.b), 20, 0, 0)["rooms"][0]), "L0", "B" * 64, guess=True)
        self.assertEqual(p["confidence"], "auto")
        self.assertEqual(len(p["preview"]), 4)
        self.assertAlmostEqual(p["transform"]["rotation"] % 90, (-20) % 90, delta=0.6)

    def test_identical_rooms_are_not_silently_chosen(self):
        # two identical rooms side by side: a scan of "another" one has two equally good places
        c1 = room(0, 0, 4, 3, "C1", doors=[(4.0, 1.5, 0, 1)])
        c2 = room(8, 0, 12, 3, "C2", doors=[(8.0, 1.5, 0, 1)])
        house, _ = import_capture(empty_house(), wrap(c1, c2), "L0", "A" * 64)
        probe = moved(wrap(room(0, 0, 4, 3, "P", doors=[(4.0, 1.5, 0, 1)])), 0, 30, 30)["rooms"][0]
        p = place.propose(house, wrap(probe), "L0", "B" * 64, guess=True)
        self.assertNotEqual(p["confidence"], "auto", p)

    def test_deterministic(self):
        d = wrap(moved(wrap(self.b), 37, 5, -3)["rooms"][0])
        self.assertEqual(place.propose(self.house, d, "L0", "B" * 64, guess=True), place.propose(self.house, d, "L0", "B" * 64, guess=True))


if __name__ == "__main__":
    unittest.main()
