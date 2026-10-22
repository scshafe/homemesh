import json
import os
import tempfile
import unittest

from fastapi.testclient import TestClient

from homemesh import api, diagnostics, seed, store


class DiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST, api.DOOR_ADDR)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
        os.environ[api.DOOR_ADDR] = "testclient"
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

    def test_events_and_crashes_round_trip_through_the_api(self):
        ev = b'{"t": 1, "e": "phase", "to": "running"}\n{"t": 2, "e": "session-error", "code": 7}\n'
        r = self.c.post("/api/diagnostics?device=phone-1&kind=events", content=ev, headers=self.ok)
        self.assertEqual((r.status_code, r.json()["stored"]), (200, True), r.text)
        again = self.c.post("/api/diagnostics?device=phone-1&kind=events", content=ev, headers=self.ok)
        self.assertFalse(again.json()["stored"])   # the same upload twice is stored once
        crash = {"crashDiagnostics": [{"callStackTree": {"callStacks": []}}]}
        self.c.post("/api/diagnostics?device=phone-1&kind=metrickit", content=json.dumps(crash).encode(), headers=self.ok)
        listing = self.c.get("/api/diagnostics", headers=self.ok).json()
        self.assertEqual(sorted(f["kind"] for f in listing), ["events", "metrickit"])
        got = self.c.get(f"/api/diagnostics/phone-1/{listing[0]['name']}", headers=self.ok)
        self.assertEqual(got.status_code, 200)
        self.assertEqual([e["e"] for e in diagnostics.events(10)], ["phase", "session-error"])
        self.assertEqual(diagnostics.latest_crash()["payload"], crash)

    def test_door_and_validation(self):
        self.assertEqual(self.c.post("/api/diagnostics?device=p&kind=events", content=b"{}").status_code, 401)
        for q, body in [("device=../x&kind=events", b"{}"), ("device=p&kind=other", b"{}"),
                        ("device=p&kind=events", b"not json"), ("device=p&kind=metrickit", b"[1"), ("device=p&kind=events", b"")]:
            self.assertEqual(self.c.post(f"/api/diagnostics?{q}", content=body, headers=self.ok).status_code, 422, q)
        self.assertEqual(self.c.get("/api/diagnostics/p/..%2Fx", headers=self.ok).status_code, 404)

    def test_retention_by_age_and_size(self):
        diagnostics.save("p", "events", b'{"t": 1}\n', now=1000)
        diagnostics.save("p", "events", b'{"t": 2}\n', now=1000 + 40 * 86400)   # saving prunes: the first is past 30 days
        self.assertEqual(len(diagnostics.files()), 1)
        old = diagnostics.KEEP_BYTES
        diagnostics.KEEP_BYTES = 20
        try:
            now = 1000 + 40 * 86400
            for i in range(3):
                diagnostics.save("p", "events", json.dumps({"t": 10 + i, "pad": "x" * 10}).encode() + b"\n", now=now + i)
            self.assertLessEqual(sum(f["size"] for f in diagnostics.files()), 40)
            self.assertEqual(diagnostics.events(5)[-1]["t"], 12)   # the newest survives
        finally:
            diagnostics.KEEP_BYTES = old

    def test_cli_prints_without_the_server(self):
        diagnostics.save("p", "events", b'{"t": 5, "e": "x"}\n')
        self.assertEqual(diagnostics.main(["events", "-n", "5"]), 0)
        self.assertEqual(diagnostics.main(["latest-crash"]), 1)   # none stored yet
