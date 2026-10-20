import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from homemesh import fixtures, store
from homemesh.model import House, Need, Zone
from homemesh.schema import house_schema

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures"


class FixtureTest(unittest.TestCase):
    def test_all_sound_and_synthetic(self):
        for name, fn in fixtures.ALL.items():
            with self.subTest(name):
                h = fn()
                self.assertTrue(h.synthetic)
                self.assertEqual(h.validate_refs(), [])

    def test_committed_fixtures_match_generator(self):
        with tempfile.TemporaryDirectory() as d:
            fixtures.write_all(Path(d))
            for name in fixtures.ALL:
                self.assertEqual((Path(d) / f"{name}.json").read_text(), (FIXTURES / f"{name}.json").read_text(), name)
        self.assertEqual({p.stem for p in FIXTURES.glob("*.json")}, set(fixtures.ALL))

    def test_committed_fixtures_roundtrip(self):
        for p in FIXTURES.glob("*.json"):
            h = House.model_validate_json(p.read_text())
            self.assertTrue(h.synthetic, p.name)


class ValidationTest(unittest.TestCase):
    def test_dangling_references_reported(self):
        h = fixtures.wired_ends()
        h.walls[0].material = "nope"
        h.jacks[0].switch = "ghost"
        errs = h.validate_refs()
        self.assertTrue(any("unknown material nope" in e for e in errs))
        self.assertTrue(any("unknown switch ghost" in e for e in errs))

    def test_demand_zone_needs_need(self):
        with self.assertRaises(ValueError):
            Zone(id="z", level="L0", kind="demand", polygon=[(0, 0)])
        with self.assertRaises(ValueError):
            Zone(id="z", level="L0", kind="allow", polygon=[(0, 0)], need=Need())

    def test_unknown_field_rejected(self):
        data = json.loads(fixtures.long_thin().model_dump_json())
        data["surprise"] = 1
        with self.assertRaises(ValueError):
            House.model_validate(data)

    def test_opening_past_wall_end(self):
        h = fixtures.one_floor_box()
        h.walls[-1].openings[0].offset = 7.9
        self.assertTrue(any("past the wall end" in e for e in h.validate_refs()))

    def test_schema_exports(self):
        s = house_schema()
        self.assertIn("walls", s["properties"])
        json.dumps(s)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._old = os.environ.get(store.ENV)
        os.environ[store.ENV] = self._tmp.name

    def tearDown(self):
        if self._old is None:
            os.environ.pop(store.ENV, None)
        else:
            os.environ[store.ENV] = self._old
        self._tmp.cleanup()

    def test_refuses_without_env(self):
        del os.environ[store.ENV]
        with self.assertRaises(store.StoreError):
            store.data_dir()

    def test_refuses_inside_repo(self):
        os.environ[store.ENV] = str(ROOT / "data")
        with self.assertRaises(store.StoreError):
            store.data_dir()

    def test_refuses_relative(self):
        os.environ[store.ENV] = "relative/dir"
        with self.assertRaises(store.StoreError):
            store.data_dir()

    def test_revisions_and_conflict(self):
        h = fixtures.one_floor_box()
        v1 = store.save(h)
        self.assertEqual(v1.revision, 1)
        v2 = store.save(v1, expect_revision=1)
        self.assertEqual(v2.revision, 2)
        with self.assertRaises(store.Conflict):
            store.save(v1, expect_revision=1)
        with self.assertRaises(store.Conflict):
            store.save(h)  # new-house save over an existing one
        self.assertEqual(store.load(h.id).revision, 2)
        self.assertEqual(store.load(h.id, revision=1).revision, 1)
        self.assertEqual(store.list_houses(), [h.id])

    def test_invalid_house_not_saved(self):
        h = fixtures.one_floor_box()
        h.walls[0].material = "nope"
        with self.assertRaises(store.StoreError):
            store.save(h)
        self.assertEqual(store.list_houses(), [])

    def test_bad_ids_rejected(self):
        for bad in ("../x", "a/b", "", ".hidden"):
            with self.assertRaises(store.StoreError):
                store.load(bad)

    def test_blobs_content_addressed(self):
        h = store.save(fixtures.long_thin())
        d = store.put_blob(h.id, b"hello")
        self.assertEqual(d, store.put_blob(h.id, b"hello"))
        self.assertEqual(store.get_blob(h.id, d), b"hello")
        with self.assertRaises(store.StoreError):
            store.get_blob(h.id, "../../house.json")


class HygieneTest(unittest.TestCase):
    """No house data in the tree (design 2.6): forbidden extensions, big files."""

    FORBIDDEN = {".usdz", ".usd", ".usda", ".usdc", ".obj", ".ply", ".e57", ".las", ".laz", ".glb", ".gltf",
                 ".mov", ".mp4", ".m4v", ".heic", ".heif", ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".dng",
                 ".raw", ".dwg", ".dxf", ".pdf"}
    ALLOW_UNDER = ("docs/",)
    MAX_BYTES = 512 * 1024

    def tracked(self):
        out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
        return [p for p in out.decode().split("\0") if p and (ROOT / p).exists()]

    def test_no_forbidden_files(self):
        for p in self.tracked():
            if p.startswith(self.ALLOW_UNDER):
                continue
            self.assertNotIn(Path(p).suffix.lower(), self.FORBIDDEN, p)
            self.assertLess((ROOT / p).stat().st_size, self.MAX_BYTES, p)
            self.assertFalse(p.startswith("data/"), p)

    def test_json_fixtures_declare_synthetic(self):
        for p in self.tracked():
            if p.startswith("tests/fixtures/") and p.endswith(".json"):
                self.assertTrue(json.loads((ROOT / p).read_text()).get("synthetic") is True, p)


if __name__ == "__main__":
    unittest.main()
