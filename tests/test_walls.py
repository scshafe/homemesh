import math
import unittest

from homemesh.materials import default_materials
from homemesh.model import House, Level
from homemesh.roomplan import import_capture
from tests.roomplan_synth import room, surface


def house(jog_fold=0.3):
    return House(id="h", name="h", synthetic=True, materials=default_materials(), jog_fold=jog_fold,
                 levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)])


def wrap(*rooms):
    return {"format": "homemesh-capture-1", "rooms": list(rooms)}


def lengths(h):
    return sorted(round(w.length, 2) for w in h.walls)


class ProfileTest(unittest.TestCase):
    def test_a_gable_wall_keeps_its_outline_and_a_plain_rectangle_does_not(self):
        r = room(0, 0, 6, 4, "A")
        south = r["walls"][0]
        south["polygonCorners"] = [[-3, -1.25, 0], [3, -1.25, 0], [3, 0.25, 0], [0, 1.25, 0], [-3, 0.25, 0]]   # a pitched top
        r["walls"][1]["polygonCorners"] = [[-2, -1.25, 0], [2, -1.25, 0], [2, 1.25, 0], [-2, 1.25, 0]]       # just a rectangle
        h, rep = import_capture(house(), wrap(r), "L0", "A" * 64)
        self.assertEqual(rep.profile_walls, 1)
        gable = next(w for w in h.walls if w.profile)
        self.assertEqual(len(gable.profile), 5)
        self.assertAlmostEqual(max(p[1] for p in gable.profile), 2.5, places=2)   # the apex reaches the wall's height
        self.assertAlmostEqual(max(p[0] for p in gable.profile), gable.length, places=2)
        self.assertEqual(sum(1 for w in h.walls if w.profile), 1)


class CurveTest(unittest.TestCase):
    def test_a_curved_wall_becomes_chords_that_remember_the_arc(self):
        r = room(0, 0, 6, 4, "A")
        r["walls"][0]["curve"] = {"radius": 4.0, "startAngle": -0.7, "endAngle": 0.7}   # the south wall bows outward
        h, rep = import_capture(house(), wrap(r), "L0", "A" * 64)
        self.assertEqual(rep.curved_walls, 1)
        chords = [w for w in h.walls if w.curve]
        self.assertGreaterEqual(len(chords), 6)
        self.assertLessEqual(len(chords), 12)
        c = chords[0].curve
        self.assertEqual({w.curve.group for w in chords}, {c.group})
        for w in chords:   # every chord end lies on the remembered circle
            for p in (w.a, w.b):
                self.assertAlmostEqual(math.hypot(p[0] - c.cx, p[1] - c.cy), c.radius, places=2)
        ys = [p[1] for w in chords for p in (w.a, w.b)]
        # ARKit z becomes -Y; the south wall is z = 0 and the room lies at z > 0, so the plan bulges to +Y... away from the room
        self.assertGreater(max(ys) - min(ys), 0.2)
        self.assertGreater(max(abs(y) for y in ys), 0.2)

    def test_a_curve_that_cannot_fit_its_chord_stays_straight(self):
        r = room(0, 0, 6, 4, "A")
        r["walls"][0]["curve"] = {"radius": 1.0, "startAngle": 0.0, "endAngle": 1.0}   # radius under half the chord
        h, rep = import_capture(house(), wrap(r), "L0", "A" * 64)
        self.assertEqual((rep.curved_walls, len(h.walls)), (0, 4))


class JogTest(unittest.TestCase):
    def jogged(self):
        """A south wall with a 0.2 m step in the middle: three pieces, the middle one across (z)."""
        r = room(0, 0, 6, 4, "A")
        r["walls"][0:1] = [
            surface("wall", (1.5, 1.25, 0.0), (1, 0), 3.0, 2.5, "A-s1"),
            surface("wall", (3.0, 1.25, 0.1), (0, 1), 0.2, 2.5, "A-jog"),
            surface("wall", (4.5, 1.25, 0.2), (1, 0), 3.0, 2.5, "A-s2"),
        ]
        return wrap(r)

    def test_a_short_jog_is_folded_into_its_neighbours(self):
        h, rep = import_capture(house(), self.jogged(), "L0", "A" * 64)
        self.assertEqual(rep.folded_jogs, 1)
        self.assertEqual(len(h.walls), 5)   # the jog is gone: two south pieces plus east, north, west
        self.assertTrue(all(w.length > 0.3 for w in h.walls))

    def test_the_threshold_is_the_houses(self):
        h, rep = import_capture(house(jog_fold=0.0), self.jogged(), "L0", "A" * 64)
        self.assertEqual((rep.folded_jogs, len(h.walls)), (0, 6))
        h, rep = import_capture(house(jog_fold=0.1), self.jogged(), "L0", "A" * 64)
        self.assertEqual(rep.folded_jogs, 0)   # 0.2 m is not under 0.1

    def test_folded_surfaces_still_belong_to_their_room_when_it_is_rescanned(self):
        from homemesh.roomplan import retire_room
        data = self.jogged()
        h, _ = import_capture(house(), data, "L0", "A" * 64)
        gone_h, gone = retire_room(h, data, "A" * 64, 0)
        self.assertEqual((gone, gone_h.walls), (5, []))


if __name__ == "__main__":
    unittest.main()
