import base64
import os
import tempfile
import unittest

import numpy as np
from fastapi.testclient import TestClient

from homemesh import api, fixtures, seed, store


class ApiTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST, api.DOOR_ADDR)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
        os.environ[api.DOOR_ADDR] = "testclient"  # the TestClient peer plays the door
        os.environ[api.WEB_DIST] = os.path.join(self._tmp.name, "no-dist")
        seed.main()
        self.c = TestClient(api.create_app())
        self.ok = {"X-Door-User": "owner"}

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()

    def test_summary_levels_and_schema(self):
        rows = self.c.get("/api/houses/summary", headers=self.ok).json()
        self.assertEqual({r["id"] for r in rows}, set(self.c.get("/api/houses", headers=self.ok).json()))
        row = next(r for r in rows if r["id"] == "synthetic-box")
        self.assertEqual(row["levels"], [{"id": "L0", "name": "Ground"}])
        self.assertEqual(self.c.get("/api/houses/summary").status_code, 401)
        h = self.c.post("/api/houses/synthetic-box/levels", json={"name": "First"}, headers=self.ok)
        self.assertEqual(h.status_code, 201, h.text)
        lv = h.json()["levels"][-1]
        self.assertEqual((lv["id"], lv["name"]), ("L1", "First"))
        self.assertAlmostEqual(lv["elevation"], 2.5 + 0.3, places=3)
        self.assertIsNotNone(lv["slab"])
        self.assertEqual(h.json()["revision"], row["revision"] + 1)
        self.assertEqual(self.c.post("/api/houses/synthetic-box/levels", json={"name": " "}, headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post("/api/houses/nope/levels", json={"name": "x"}, headers=self.ok).status_code, 404)
        schema = self.c.get("/api/schema/house", headers=self.ok).json()
        self.assertIn("levels", schema["properties"])

    def test_only_the_door_may_call_api(self):
        os.environ[api.DOOR_ADDR] = "10.253.93.10"
        c = TestClient(api.create_app())
        self.assertEqual(c.get("/api/houses", headers=self.ok).status_code, 403)  # right header, wrong peer
        self.assertEqual(c.get("/api/health").status_code, 200)
        os.environ.pop(api.DOOR_ADDR)
        self.assertEqual(TestClient(api.create_app()).get("/api/houses", headers=self.ok).status_code, 403)  # the default is the door too

    def test_health_open(self):
        self.assertEqual(self.c.get("/api/health").json(), {"ok": True})

    def test_refuses_without_identity(self):
        for path in ("/api/houses", "/api/houses/synthetic-box", "/api/houses/synthetic-box/heatmap?x=1&y=1&level=L0"):
            self.assertEqual(self.c.get(path).status_code, 401, path)

    def test_lists_and_loads(self):
        self.assertEqual(sorted(self.c.get("/api/houses", headers=self.ok).json()), sorted(h().id for h in fixtures.ALL.values()))
        r = self.c.get("/api/houses/synthetic-box", headers=self.ok).json()
        self.assertTrue(r["synthetic"])
        self.assertEqual(self.c.get("/api/houses/nope", headers=self.ok).status_code, 404)
        self.assertEqual(self.c.get("/api/houses/..%2Fx", headers=self.ok).status_code, 404)

    def test_heatmap(self):
        r = self.c.get("/api/houses/synthetic-box/heatmap?x=2&y=2&level=L0&band=5", headers=self.ok).json()
        g = r["grids"][0]
        arr = np.frombuffer(base64.b64decode(g["rssi_f32_b64"]), dtype="<f4")
        self.assertEqual(arr.size, g["nx"] * g["ny"])
        self.assertTrue(np.isfinite(arr).any())
        bad = self.c.get("/api/houses/synthetic-box/heatmap?x=2&y=2&level=L0&band=7", headers=self.ok)
        self.assertEqual(bad.status_code, 422)
        bad = self.c.get("/api/houses/synthetic-box/heatmap?x=2&y=2&level=ZZ", headers=self.ok)
        self.assertEqual(bad.status_code, 422)

    def test_create_edit_conflict(self):
        r = self.c.post("/api/houses", json={"id": "mine", "name": "Mine"}, headers=self.ok)
        self.assertEqual(r.status_code, 201)
        h = r.json()
        self.assertEqual(h["revision"], 1)
        self.assertEqual(self.c.post("/api/houses", json={"id": "mine", "name": "x"}, headers=self.ok).status_code, 409)
        self.assertEqual(self.c.post("/api/houses", json={"id": "../x", "name": "x"}, headers=self.ok).status_code, 422)
        h["name"] = "Renamed"
        r = self.c.put("/api/houses/mine?expect_revision=1", json=h, headers=self.ok)
        self.assertEqual((r.status_code, r.json()["revision"]), (200, 2))
        r = self.c.put("/api/houses/mine?expect_revision=1", json=h, headers=self.ok)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.c.get("/api/houses/mine/revisions", headers=self.ok).json(), [1, 2])

    def test_put_validation(self):
        h = self.c.post("/api/houses", json={"id": "v", "name": "V"}, headers=self.ok).json()
        bad = dict(h, walls=[{"id": "w", "level": "L0", "a": [0, 0], "b": [1, 0], "thickness": 0.1, "height": 2.5, "material": "nope"}])
        self.assertEqual(self.c.put("/api/houses/v?expect_revision=1", json=bad, headers=self.ok).status_code, 422)
        self.assertEqual(self.c.put("/api/houses/v?expect_revision=1", json=dict(h, id="other"), headers=self.ok).status_code, 422)
        self.assertEqual(self.c.put("/api/houses/v?expect_revision=1", json={"junk": 1}, headers=self.ok).status_code, 422)
        self.assertEqual(self.c.put("/api/houses/v?expect_revision=1", json=h).status_code, 401)

    def test_startup_requires_door_or_dev(self):
        del os.environ[api.AUTH_HEADER]
        with self.assertRaises(RuntimeError):
            api.create_app()
        os.environ[api.DEV] = "1"
        api.create_app()

    def test_seed_does_not_overwrite(self):
        h = store.load("synthetic-box")
        store.save(h.model_copy(update={"name": "edited"}), expect_revision=1)
        seed.main()
        self.assertEqual(store.load("synthetic-box").name, "edited")


if __name__ == "__main__":
    unittest.main()


class _PlanBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST, api.DOOR_ADDR)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
        os.environ[api.DOOR_ADDR] = "testclient"  # the TestClient peer plays the door
        os.environ[api.WEB_DIST] = os.path.join(self._tmp.name, "none")
        seed.main()
        self.c = TestClient(api.create_app())
        self.ok = {"X-Door-User": "o"}

    def tearDown(self):
        for k, v in self._env.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        self._tmp.cleanup()

    def wait(self, job):
        import time
        for _ in range(600):
            r = self.c.get(f"/api/jobs/{job}", headers=self.ok).json()
            if r["state"] != "running":
                return r
            time.sleep(0.1)
        self.fail("job did not finish")


class PlanApiTest(_PlanBase):
    def test_catalogue(self):
        r = self.c.get("/api/catalogue", headers=self.ok).json()
        self.assertTrue(r["equipment"] and r["clients"])
        self.assertEqual(self.c.get("/api/catalogue").status_code, 401)

    def test_plan_needs_rules(self):
        r = self.c.post("/api/houses/synthetic-two-floor/plans", json={}, headers=self.ok)
        self.assertEqual(r.status_code, 422)  # no allow zone
        self.assertEqual(self.c.post("/api/houses/synthetic-long/plans", json={}).status_code, 401)

    def test_plan_job_and_ratemap(self):
        r = self.c.post("/api/houses/synthetic-long/plans",
                        json={"k_max": 1, "equipment": ["generic-mesh-tri"], "gateway_equipment": "generic-mesh-tri", "candidate_step": 4, "grid": 2},
                        headers=self.ok)
        self.assertEqual(r.status_code, 202)
        done = self.wait(r.json()["job"])
        self.assertEqual(done["state"], "done", done.get("error"))
        res = done["result"]["results"]
        self.assertTrue(res and res[0]["valid"])
        self.assertIn("explanation", res[0])
        self.assertTrue(any(x["pareto"] for x in res))
        rm = self.c.post("/api/houses/synthetic-long/ratemap",
                         json={"nodes": res[-1]["nodes"], "gateway_equipment": "generic-mesh-tri", "grid": 2}, headers=self.ok).json()
        self.assertEqual(rm["grids"][0]["level"], "L0")
        self.assertEqual(len(rm["grids"][0]["rate"]), rm["grids"][0]["nx"] * rm["grids"][0]["ny"])
        bad = self.c.post("/api/houses/synthetic-long/ratemap", json={"nodes": [{"equipment": "x", "position": [1, 1], "level": "L0", "height": 1}]}, headers=self.ok)
        self.assertEqual(bad.status_code, 422)

    def test_unknown_equipment_is_an_error_state(self):
        r = self.c.post("/api/houses/synthetic-long/plans", json={"equipment": ["nope"]}, headers=self.ok)
        done = self.wait(r.json()["job"])
        self.assertEqual(done["state"], "error")
        self.assertIn("unknown equipment", done["error"])


class CalibrationApiTest(_PlanBase):
    def make(self):
        from tests.test_calibration import house, synth
        h = house()
        h.measurements = synth(h, n=40, bands=("5",))
        return h

    def test_parse_and_calibrate(self):
        h = self.make()
        self.c.post("/api/houses", json={"id": "cal", "name": "cal"}, headers=self.ok)
        csv = "x,y,band,rssi\n1,1,5,-60\n"
        self.assertEqual(self.c.post("/api/houses/cal/measurements/parse", content=csv, headers=self.ok).json()[0]["id"], "m1")
        self.assertEqual(self.c.post("/api/houses/cal/measurements/parse", content="junk", headers=self.ok).status_code, 422)
        r = self.c.post("/api/houses/cal/calibrate", content=h.model_copy(update={"id": "cal"}).model_dump_json(), headers=self.ok)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertIn("5", body["fits"])
        self.assertEqual(body["calibrated"]["calibration"]["n_measurements"]["5"], 40)
        self.assertEqual(self.c.post("/api/houses/cal/calibrate", content=b"", headers=self.ok).json()["fits"], {})
        self.assertEqual(self.c.post("/api/houses/cal/calibrate", content=h.model_copy(update={"id": "other"}).model_dump_json(), headers=self.ok).status_code, 422)  # id mismatch
        self.assertEqual(self.c.post("/api/houses/cal/calibrate", content=b"{}", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post("/api/houses/cal/calibrate", content=b"").status_code, 401)
