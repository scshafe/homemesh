import unittest

from homemesh import fixtures
from homemesh.model import House, Wall
from homemesh.roomplan import Defaults, ImportError_, Similarity2D, import_capture, register, registration_error
from tests.roomplan_synth import room, two_rooms


def empty_house() -> House:
    h = fixtures.long_thin()
    return h.model_copy(update={"walls": [], "zones": [], "entry": None})


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.h, self.rep = import_capture(empty_house(), two_rooms(), "L0", "b" * 64)

    def test_shared_wall_merges_to_one_with_the_measured_thickness(self):
        self.assertEqual(self.rep.walls, 7)  # 8 surfaces, one pair merged
        self.assertEqual(self.rep.paired_walls, 1)
        shared = [w for w in self.h.walls if not w.thickness_defaulted]
        self.assertEqual(len(shared), 1)
        w = shared[0]
        self.assertAlmostEqual(w.thickness, 0.12, places=3)
        self.assertAlmostEqual(w.a[0], 4.06, places=3)
        self.assertAlmostEqual(w.b[0], 4.06, places=3)
        self.assertAlmostEqual(w.length, 3.0, places=3)

    def test_unmeasured_walls_carry_flagged_defaults(self):
        for w in self.h.walls:
            self.assertTrue(w.material_defaulted)
            self.assertEqual(w.prov.source, "scan")
            self.assertTrue(w.prov.ref.startswith("b" * 64 + "#wall/"))
        d = [w for w in self.h.walls if w.thickness_defaulted]
        self.assertEqual({w.thickness for w in d}, {0.1})
        self.assertEqual(len(d), 6)

    def test_heights_and_floor_reference(self):
        for w in self.h.walls:
            self.assertAlmostEqual(w.height, 2.5, places=3)
            self.assertAlmostEqual(w.base_z, 0.0, places=3)

    def test_arkit_z_becomes_minus_plan_y(self):
        ys = sorted({round(p[1], 3) for w in self.h.walls for p in (w.a, w.b)})
        self.assertEqual(ys, [-3.0, 0.0])  # rooms span z 0..3 in ARKit

    def test_door_seen_from_both_rooms_is_kept_once_in_the_right_place(self):
        shared = next(w for w in self.h.walls if not w.thickness_defaulted)
        self.assertEqual(len(shared.openings), 1)
        o = shared.openings[0]
        self.assertEqual((o.kind, o.material, o.state), ("door", "wood-door", "closed"))
        self.assertAlmostEqual(o.offset + o.width / 2, 1.5, places=2)  # door centred at z = 1.5 of 3 m
        self.assertEqual(self.rep.openings, 2)
        self.assertEqual(self.rep.skipped_openings, 1)

    def test_window_sill(self):
        win = [(w, o) for w in self.h.walls for o in w.openings if o.kind == "window"]
        self.assertEqual(len(win), 1)
        o = win[0][1]
        self.assertAlmostEqual(o.sill, 1.5 - 0.6, places=3)
        self.assertEqual(o.material, "glass")

    def test_result_is_a_valid_house(self):
        self.assertEqual(self.h.validate_refs(), [])
        House.model_validate_json(self.h.model_dump_json())

    def test_reimport_replaces_only_its_own_walls(self):
        manual = Wall(id="mine", level="L0", a=(20, 0), b=(25, 0), thickness=0.2, height=2.5, material="brick")
        h = self.h.model_copy(update={"walls": [*self.h.walls, manual]})
        h2, rep = import_capture(h, two_rooms(), "L0", "b" * 64)
        self.assertEqual(rep.replaced, 7)
        self.assertEqual(len(h2.walls), 8)
        self.assertIn("mine", [w.id for w in h2.walls])
        self.assertEqual(len({w.id for w in h2.walls}), 8)

    def test_a_different_blob_adds_alongside(self):
        h2, rep = import_capture(self.h, two_rooms(), "L0", "c" * 64)
        self.assertEqual((rep.replaced, len(h2.walls)), (0, 14))

    def test_nested_transform_encoding_is_read_the_same(self):
        h2, _ = import_capture(empty_house(), two_rooms(nested=True), "L0", "b" * 64)
        self.assertEqual([(w.a, w.b) for w in h2.walls], [(w.a, w.b) for w in self.h.walls])

    def test_open_door_state(self):
        data = two_rooms()
        data["rooms"][0]["doors"][0]["category"] = {"door": {"isOpen": True}}
        data["rooms"][1]["doors"] = []
        h, _ = import_capture(empty_house(), data, "L0", "d" * 64)
        shared = next(w for w in h.walls if not w.thickness_defaulted)
        self.assertEqual(shared.openings[0].state, "open")

    def test_single_room_structure_form_and_arch_opening(self):
        r = room(0, 0, 3, 3, "S")
        h, rep = import_capture(empty_house(), r, "L0", "e" * 64)  # a bare CapturedRoom, no wrapper
        self.assertEqual((rep.walls, rep.paired_walls), (4, 0))

    def test_elevated_scan_uses_its_own_floor(self):
        h, _ = import_capture(empty_house(), {"rooms": [room(0, 0, 3, 3, "U", y0=3.1)]}, "L0", "f" * 64)
        self.assertTrue(all(abs(w.base_z) < 1e-6 for w in h.walls))

    def test_confidence_mapped(self):
        data = {"rooms": [room(0, 0, 3, 3, "C")]}
        data["rooms"][0]["walls"][0]["confidence"] = {"low": {}}
        h, _ = import_capture(empty_house(), data, "L0", "a" * 64)
        self.assertIn(0.4, [w.prov.confidence for w in h.walls])


class ErrorTest(unittest.TestCase):
    def test_errors(self):
        for data, level, frag in [({}, "L0", "no walls"), ({"walls": []}, "L0", "no walls"), (two_rooms(), "L9", "unknown level"),
                                  ({"walls": [{"transform": [1], "dimensions": [1, 1, 0]}]}, "L0", "walls[0]"),
                                  ({"walls": [{"transform": [0] * 16, "dimensions": [0, 0, 0], "category": {"wall": {}}}]}, "L0", "no walls")]:
            with self.assertRaises(ImportError_) as c:
                import_capture(empty_house(), data, level, "a" * 64)
            self.assertIn(frag, str(c.exception))


class RegistrationTest(unittest.TestCase):
    def test_recovers_rotation_and_translation(self):
        truth = Similarity2D(1.0, 30.0, 5.0, -2.0)
        src = [(0, 0), (4, 0), (4, 3), (1, 7)]
        dst = [truth.apply(p) for p in src]
        sim = register(src, dst)
        self.assertAlmostEqual(sim.rotation, 30.0, places=6)
        self.assertAlmostEqual(sim.tx, 5.0, places=6)
        self.assertLess(registration_error(src, dst, sim), 1e-9)

    def test_noisy_picks_report_their_error(self):
        src = [(0, 0), (4, 0), (4, 3)]
        dst = [(10.0, 10.0), (14.05, 10.0), (14.0, 13.08)]
        sim = register(src, dst)
        err = registration_error(src, dst, sim)
        self.assertTrue(0 < err < 0.2)

    def test_reflection_is_not_returned(self):
        sim = register([(0, 0), (1, 0), (0, 1)], [(0, 0), (1, 0), (0, -1)])
        self.assertAlmostEqual(abs(sim.scale), 1.0)  # a proper rotation fitted as well as it can, never a mirror

    def test_needs_two_distinct_pairs(self):
        for src, dst in [([(0, 0)], [(1, 1)]), ([(1, 1), (1, 1)], [(2, 2), (3, 3)]), ([(0, 0), (1, 1)], [(0, 0)])]:
            with self.assertRaises(ImportError_):
                register(src, dst)

    def test_transform_moves_the_imported_walls(self):
        sim = Similarity2D(1.0, 90.0, 10.0, 0.0)
        h, _ = import_capture(empty_house(), {"rooms": [room(0, 0, 4, 3, "R")]}, "L0", "a" * 64, transform=sim)
        xs = sorted({round(p[0], 2) for w in h.walls for p in (w.a, w.b)})
        self.assertEqual(xs, [10.0, 13.0])  # plan y spans -3..0; rotated by 90 deg x' = -y, then +10


if __name__ == "__main__":
    unittest.main()
