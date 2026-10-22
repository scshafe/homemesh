import unittest

from homemesh.materials import default_materials
from homemesh.model import House, Level
from homemesh.roomplan import import_capture, retire_room
from tests.roomplan_synth import room, two_rooms


def house():
    return House(id="h", name="h", synthetic=True, materials=default_materials(),
                 levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)])


def obj(ident, category, w, h, d, x, z, **extra):
    return {"identifier": ident, "category": {category: {}}, "dimensions": [w, h, d],
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, h / 2, z, 1], **extra}


class FurnitureTest(unittest.TestCase):
    def data(self):
        r = room(0, 0, 6, 4, "A")
        r["objects"] = [obj("sofa-1", "sofa", 2.0, 0.9, 1.0, 1.5, 1.0), obj("sink-1", "sink", 0.6, 0.9, 0.5, 5.0, 0.5),
                        obj("shelf-1", "storage", 1.0, 2.0, 0.4, 3.0, 3.6, attributes={"storageType": "shelf"}),
                        obj("stairs-1", "stairs", 1.0, 2.7, 3.0, 4.0, 2.0)]
        return {"format": "homemesh-capture-1", "rooms": [r]}

    def test_objects_become_furniture_with_category_defaults_and_a_room(self):
        h, rep = import_capture(house(), self.data(), "L0", "A" * 64)
        self.assertEqual(rep.furniture, 3)            # the stairs object stays a staircase
        by = {f.category: f for f in h.furniture}
        self.assertTrue(by["sofa"].movable and by["sofa"].movable_default)
        self.assertFalse(by["sink"].movable)
        self.assertEqual(by["storage"].attributes, {"storageType": "shelf"})
        self.assertEqual(by["sofa"].room, h.rooms[0].id)
        self.assertAlmostEqual(by["sofa"].center[0], 1.5, places=2)
        self.assertAlmostEqual(by["sofa"].center[1], -1.0, places=2)   # ARKit z becomes -Y
        self.assertAlmostEqual(by["sofa"].height, 0.9)
        self.assertEqual(h.validate_refs(), [])

    def test_reimport_replaces_and_keeps_names_and_overrides(self):
        h, _ = import_capture(house(), self.data(), "L0", "A" * 64)
        shelf = next(f for f in h.furniture if f.category == "storage")
        edited = [f.model_copy(update={"name": "Built-in shelf", "movable": False, "movable_default": False}) if f.id == shelf.id else f for f in h.furniture]
        h = h.model_copy(update={"furniture": edited})
        h2, rep = import_capture(h, self.data(), "L0", "A" * 64)
        self.assertEqual((rep.furniture, len(h2.furniture)), (3, 3))   # replaced, not doubled
        s2 = next(f for f in h2.furniture if f.category == "storage")
        self.assertEqual((s2.name, s2.movable, s2.movable_default), ("Built-in shelf", False, False))
        self.assertTrue(next(f for f in h2.furniture if f.category == "sofa").movable_default)

    def test_rescanning_a_room_takes_its_furniture_with_it(self):
        data = self.data()
        h, _ = import_capture(house(), data, "L0", "A" * 64)
        h2, _ = retire_room(h, data, "A" * 64, 0)
        self.assertEqual(h2.furniture, [])

    def test_the_rf_model_ignores_furniture(self):
        from homemesh.propagation import level_grid, rssi_map, Tx
        import numpy as np
        h, _ = import_capture(house(), self.data(), "L0", "A" * 64)
        bare = h.model_copy(update={"furniture": []})
        g = level_grid(h, "L0", 1.0, 1.0)
        a = rssi_map(h, Tx((1.0, -1.0), "L0", height=1.8), "5", g)
        b = rssi_map(bare, Tx((1.0, -1.0), "L0", height=1.8), "5", g)
        self.assertTrue(np.allclose(a, b, equal_nan=True))


if __name__ == "__main__":
    unittest.main()
