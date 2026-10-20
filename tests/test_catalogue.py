import json
import tempfile
import unittest
from pathlib import Path

from homemesh import catalogue

ITEM = {"id": "vendor-x", "name": "Vendor X", "kind": "mesh_node", "system": "v",
        "radios": [{"band": "5", "chains": 2, "max_width": 80, "tx_dbm": 23, "ant_gain_dbi": 4, "standard": "ax", "assumed": True}],
        "ports": [{"rate": 1000}], "price": 0}


def write(d: Path, name: str, data) -> None:
    (d / name).write_text(json.dumps(data))


class LayerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo, self.owner = Path(self.tmp.name, "repo"), Path(self.tmp.name, "owner")
        self.repo.mkdir(), self.owner.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_shipped_repository_catalogue_loads_and_every_entry_has_a_source(self):
        cat = catalogue.load(owner_dir=Path(self.tmp.name, "none"))
        self.assertIn("generic-mesh-tri", cat.equipment)
        for i, o in cat.origin.items():
            if o == "repo":
                item = cat.equipment.get(i) or cat.clients[i]
                self.assertTrue(item.sources, i)

    def test_layers_and_origin(self):
        write(self.repo, "a.json", {"equipment": [{**ITEM, "sources": ["https://example.com/spec"]}]})
        write(self.owner, "mine.json", {"equipment": [{**ITEM, "id": "mine", "price": 99}]})
        cat = catalogue.load(self.owner, self.repo)
        self.assertEqual((cat.origin["generic-router-ax"], cat.origin["vendor-x"], cat.origin["mine"]), ("generic", "repo", "owner"))
        self.assertEqual(cat.equipment["mine"].price, 99)

    def test_owner_overrides_repo_on_a_clash(self):
        write(self.repo, "a.json", {"equipment": [{**ITEM, "sources": ["https://example.com/spec"]}]})
        write(self.owner, "mine.json", {"equipment": [{**ITEM, "price": 77, "sources": ["measured by the owner"]}]})
        cat = catalogue.load(self.owner, self.repo)
        self.assertEqual((cat.equipment["vendor-x"].price, cat.origin["vendor-x"]), (77, "owner"))

    def test_public_entry_without_a_source_is_refused_private_is_not(self):
        write(self.repo, "a.json", {"equipment": [ITEM]})
        with self.assertRaises(catalogue.CatalogueError) as c:
            catalogue.load(self.owner, self.repo)
        self.assertIn("names no source", str(c.exception))
        (self.repo / "a.json").unlink()
        write(self.owner, "mine.json", {"equipment": [ITEM]})
        self.assertIn("vendor-x", catalogue.load(self.owner, self.repo).equipment)

    def test_errors_name_the_file(self):
        for data in ({"equipment": [{"id": "x"}]}, {"surprise": 1}, [1],
                     {"equipment": [{**ITEM, "sources": ["u"]}, {**ITEM, "sources": ["u"]}]}):
            write(self.repo, "bad.json", data)
            with self.assertRaises(catalogue.CatalogueError) as c:
                catalogue.load(self.owner, self.repo)
            self.assertIn("bad.json", str(c.exception))
        (self.repo / "bad.json").write_text("not json")
        with self.assertRaises(catalogue.CatalogueError):
            catalogue.load(self.owner, self.repo)

    def test_describe_marks_assumed(self):
        d = catalogue.describe(catalogue.load(self.owner, self.repo))
        self.assertTrue(all(e["assumed"] for e in d["equipment"] if e["origin"] == "generic"))
        self.assertTrue(d["clients"])


if __name__ == "__main__":
    unittest.main()
