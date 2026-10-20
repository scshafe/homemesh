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
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
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
