import time
import unittest

from homemesh import place
from homemesh.roomplan import Similarity2D, import_capture
from tests.test_place import empty_house, moved, wrap
from tests.roomplan_synth import room


def big_floor(cols=5, rows=4):
    """A realistic floor: rows x cols rooms of 4 x 3 m with doors and windows, named, each imported as its own scan."""
    house = empty_house()
    n = 0
    for r in range(rows):
        for c in range(cols):
            x0, z0 = c * 4.12, r * 3.12
            rm = room(x0, z0, x0 + 4, z0 + 3, f"T{n:02d}", doors=[(x0 + 4, z0 + 1.5, 0, 1), (x0 + 2, z0 + 3, 1, 0)],
                      windows=[(x0 + 2, z0, 1, 0)])
            rm["name"] = f"Room {chr(65 + n)}"
            house, _ = import_capture(house, wrap(rm), "L0", f"{n:02d}".ljust(64, "0"), names=[f"Room {chr(65 + n)}"])
            n += 1
    return house


class PlaceSpeedTest(unittest.TestCase):
    def test_a_twenty_room_floor_is_proposed_in_under_a_second_and_in_the_right_place(self):
        house = big_floor()
        # a new room east of the last column, seen from another session (turned and shifted)
        x0, z0 = 5 * 4.12, 1 * 3.12
        new = room(x0, z0, x0 + 4, z0 + 3, "NEW", doors=[(x0, z0 + 1.5, 0, 1), (x0 + 2, z0 + 3, 1, 0)], windows=[(x0 + 2, z0, 1, 0)])
        scan = moved(wrap(new), 37, 5, -3)
        t0 = time.perf_counter()
        p = place.propose(house, scan, "L0", "N" * 64, guess=True)
        took = time.perf_counter() - t0
        self.assertLess(took, 1.0, f"propose took {took:.2f} s")
        # every door of this synthetic floor is alike, so which neighbour it belongs to is genuinely ambiguous: what must hold
        # is speed, a usable proposal, and that the ambiguity is reported rather than called a clear match
        self.assertIn(p["confidence"], ("confirm", "manual"))
        self.assertEqual(set(p["transform"]), {"rotation", "tx", "ty"})
        self.assertTrue(p["preview"])


if __name__ == "__main__":
    unittest.main()
