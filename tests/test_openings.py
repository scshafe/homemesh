import unittest

from homemesh.materials import default_materials
from homemesh.model import House, Level, Opening, Wall
from homemesh.roomplan import clamp_openings, import_capture
from tests.roomplan_synth import room, surface


def house():
    return House(id="h", name="h", synthetic=True, materials=default_materials(),
                 levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)])


def opening(offset, width):
    return Opening(kind="arch", offset=offset, width=width, height=2.0, sill=0.0, material="air")


class ClampTest(unittest.TestCase):
    def test_the_prod_case_an_arch_ending_a_hair_past_a_rounded_wall(self):
        w = Wall(id="w82", level="L0", a=(2.5306, 1.334), b=(4.0315, 2.0285), thickness=0.1, height=2.5, material="drywall",
                 openings=[opening(0.682, 0.972)])
        self.assertAlmostEqual(w.length, 1.654, places=3)
        out, trimmed, dropped = clamp_openings([w])
        o = out[0].openings[0]
        self.assertLessEqual(o.offset + o.width, out[0].length)
        self.assertEqual(dropped, 0)
        self.assertAlmostEqual(o.offset + o.width, 1.654, places=2)   # trimmed by under a millimetre, not moved

    def test_an_opening_wider_than_its_wall_is_trimmed_and_a_sliver_is_dropped(self):
        w = Wall(id="w1", level="L0", a=(0, 0), b=(1.0, 0), thickness=0.1, height=2.5, material="drywall",
                 openings=[opening(0.0, 1.4)])
        out, trimmed, dropped = clamp_openings([w])
        self.assertEqual((trimmed, dropped), (1, 0))
        self.assertAlmostEqual(out[0].openings[0].width, 1.0, places=3)
        s = Wall(id="w2", level="L0", a=(0, 0), b=(0.2, 0), thickness=0.1, height=2.5, material="drywall", openings=[opening(0.0, 0.9)])
        out, trimmed, dropped = clamp_openings([s])
        self.assertEqual((dropped, out[0].openings), (1, []))

    def test_an_import_with_a_door_at_the_very_end_of_a_wall_validates(self):
        r = room(0, 0, 1.6543, 3, "A")
        r["doors"] = [surface("door", (1.6543 - 0.486, 1.0, 0.0), (1, 0), 0.972, 2.0, "A-edge", {"isOpen": False})]
        h, rep = import_capture(house(), {"format": "homemesh-capture-1", "rooms": [r]}, "L0", "A" * 64)
        self.assertEqual(h.validate_refs(), [])
        for w in h.walls:
            for o in w.openings:
                self.assertLessEqual(o.offset + o.width, w.length + 1e-9)

    def test_validator_tolerates_a_millimetre_and_no_more(self):
        w = Wall(id="w", level="L0", a=(0, 0), b=(2, 0), thickness=0.1, height=2.5, material="drywall", openings=[opening(1.0, 1.0005)])
        self.assertEqual(house().model_copy(update={"walls": [w]}).validate_refs(), [])
        w2 = w.model_copy(update={"openings": [opening(1.0, 1.01)]})
        self.assertTrue(house().model_copy(update={"walls": [w2]}).validate_refs())


if __name__ == "__main__":
    unittest.main()
