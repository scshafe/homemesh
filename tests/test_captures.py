import json
import os
import stat
import tempfile
import unittest

from fastapi.testclient import TestClient

from homemesh import api, captures, seed, store, tokens
from tests.roomplan_synth import two_rooms


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST, api.DOOR_ADDR)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
        os.environ[api.DOOR_ADDR] = "testclient"
        os.environ[api.WEB_DIST] = os.path.join(self._tmp.name, "none")
        seed.main()
        self.c = TestClient(api.create_app())
        self.ok = {"X-Door-User": "o"}

    def tearDown(self):
        for k, v in self._env.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        self._tmp.cleanup()


class TokenTest(Base):
    def test_create_verify_revoke(self):
        t = tokens.create("iphone")
        self.assertTrue(t.startswith("hm_"))
        self.assertEqual(tokens.verify(t), "iphone")
        self.assertIsNone(tokens.verify(t + "x"))
        self.assertIsNone(tokens.verify(None))
        self.assertIsNone(tokens.verify("hm_nope"))
        self.assertNotIn(t, (store.data_dir() / "tokens.json").read_text())  # only the hash is stored
        self.assertEqual(stat.S_IMODE((store.data_dir() / "tokens.json").stat().st_mode), 0o600)
        self.assertTrue(tokens.revoke("iphone"))
        self.assertIsNone(tokens.verify(t))
        self.assertFalse(tokens.revoke("iphone"))

    def test_names_and_duplicates(self):
        tokens.create("a")
        with self.assertRaises(store.StoreError):
            tokens.create("a")
        with self.assertRaises(store.StoreError):
            tokens.create("../x")


class CaptureApiTest(Base):
    url = "/api/houses/synthetic-box/captures"

    def upload(self, headers=None, data=None):
        return self.c.post(self.url + "?name=Ground", content=json.dumps(data or two_rooms()), headers=headers or self.ok)

    def test_upload_list_and_idempotence(self):
        m = self.upload().json()
        self.assertEqual((m["counts"]["walls"], m["counts"]["doors"], m["counts"]["rooms"]), (8, 2, 2))
        again = self.upload().json()
        self.assertEqual(again["blob"], m["blob"])
        self.assertEqual(len(self.c.get(self.url, headers=self.ok).json()), 1)

    def test_bad_uploads(self):
        for body in (b"not json", b"[]", b"{}", json.dumps({"walls": []}).encode()):
            self.assertEqual(self.c.post(self.url, content=body, headers=self.ok).status_code, 422, body)
        self.assertEqual(self.c.post("/api/houses/nope/captures", content=b"{}", headers=self.ok).status_code, 404)

    def test_usdz_attach(self):
        m = self.upload().json()
        r = self.c.post(f"{self.url}/{m['blob']}/usdz", content=b"PK\x03\x04usdz", headers=self.ok)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(captures.get_meta("synthetic-box", m["blob"])["usdz"], r.json()["usdz"])
        self.assertEqual(self.c.post(f"{self.url}/{m['blob']}/usdz", content=b"nope", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(f"{self.url}/{'0' * 64}/usdz", content=b"PK", headers=self.ok).status_code, 422)
        self.assertEqual(self.upload().json()["usdz"], r.json()["usdz"])  # re-upload keeps it

    def test_token_may_upload_but_nothing_else(self):
        t = tokens.create("iphone")
        bearer = {"Authorization": f"Bearer {t}"}
        self.assertEqual(self.upload(bearer).status_code, 200)
        self.assertEqual(self.c.get(self.url, headers=bearer).status_code, 401)  # reading needs the door's login
        self.assertEqual(self.c.get("/api/houses", headers=bearer).status_code, 401)
        self.assertEqual(self.c.put("/api/houses/synthetic-box?expect_revision=1", content=b"{}", headers=bearer).status_code, 401)
        self.assertEqual(self.upload({"Authorization": "Bearer hm_wrong"}).status_code, 401)
        tokens.revoke("iphone")
        self.assertEqual(self.upload(bearer).status_code, 401)

    def test_token_from_the_wrong_peer_is_refused(self):
        t = tokens.create("iphone")
        os.environ[api.DOOR_ADDR] = "10.253.93.10"
        c = TestClient(api.create_app())
        r = c.post(self.url, content=json.dumps(two_rooms()), headers={"Authorization": f"Bearer {t}"})
        self.assertEqual(r.status_code, 403)

    def test_import_preview_and_registration(self):
        m = self.upload().json()
        r = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", headers=self.ok)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertEqual(body["report"]["walls"], 7)
        ids = {w["id"] for w in body["house"]["walls"]}
        self.assertTrue({"w1"} <= ids)
        self.assertEqual(len(store.load("synthetic-box").walls), 5)  # nothing was stored
        reg = {"registration": {"src": [[0, 0], [4, 0]], "dst": [[10, 10], [10, 14]]}}
        r2 = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", content=json.dumps(reg), headers=self.ok).json()
        self.assertAlmostEqual(r2["registration"]["rotation"], 90.0, places=4)
        self.assertLess(r2["registration"]["max_error_m"], 1e-9)
        xs = {round(p[0], 2) for w in r2["house"]["walls"] if w["prov"]["source"] == "scan" for p in (w["a"], w["b"])}
        self.assertEqual(xs, {10.0, 13.0})  # x' = -y + 10 for plan y in -3..0

    def test_import_errors(self):
        m = self.upload().json()
        u = f"{self.url}/{m['blob']}/import"
        self.assertEqual(self.c.post(u + "?level=L9", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(f"{self.url}/{'1' * 64}/import?level=L0", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(u + "?level=L0", content=b"junk", headers=self.ok).status_code, 422)
        bad = {"registration": {"src": [[0, 0]], "dst": [[1, 1]]}}
        self.assertEqual(self.c.post(u + "?level=L0", content=json.dumps(bad), headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(u + "?level=L0").status_code, 401)


if __name__ == "__main__":
    unittest.main()
