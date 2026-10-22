import json
import os
import tempfile
import unittest

from fastapi.testclient import TestClient

from homemesh import api, captures, seed, store
from tests.roomplan_synth import two_rooms
from tests.test_place import moved, wrap


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

    def test_a_bearer_token_is_not_an_identity(self):
        # the door turns a valid bearer token into the identity header; the app never reads Authorization itself
        r = self.upload({"Authorization": "Bearer anything"})
        self.assertEqual(r.status_code, 401)

    def test_rooms_are_imported_and_named(self):
        m = self.upload().json()
        self.assertEqual(m["rooms"], ["", ""])
        r = self.c.put(f"{self.url}/{m['blob']}/rooms", json={"names": ["Kitchen", " Hall "]}, headers=self.ok)
        self.assertEqual(r.json()["rooms"], ["Kitchen", "Hall"])
        self.assertEqual(self.c.put(f"{self.url}/{m['blob']}/rooms", json={"names": ["only one"]}, headers=self.ok).status_code, 422)
        body = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", headers=self.ok).json()
        rooms = [x for x in body["house"]["rooms"] if (x["prov"].get("ref") or "").startswith(m["blob"])]
        self.assertEqual(body["report"]["rooms"], 2)
        self.assertEqual(sorted(x["name"] for x in rooms), ["Hall", "Kitchen"])
        kitchen = next(x for x in rooms if x["name"] == "Kitchen")
        xs = [p[0] for p in kitchen["polygon"]]
        self.assertAlmostEqual(max(xs) - min(xs), 4.0, places=2)
        # a second upload of the same scan keeps the names; importing again replaces rooms, never duplicates them
        self.assertEqual(self.upload().json()["rooms"], ["Kitchen", "Hall"])
        again = self.c.post(f"{self.url}/{m['blob']}/import?level=L0",
                            content=json.dumps({"house": body["house"]}), headers=self.ok).json()
        self.assertEqual(len(again["house"]["rooms"]), len(body["house"]["rooms"]))

    def test_names_carried_by_the_wrapper(self):
        data = two_rooms()
        data["rooms"][0]["name"] = "Study"
        m = self.upload(data=data).json()
        self.assertEqual(m["rooms"], ["Study", ""])
        rooms = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", headers=self.ok).json()["house"]["rooms"]
        names = [x["name"] for x in rooms if (x["prov"].get("ref") or "").startswith(m["blob"])]
        self.assertEqual(sorted(names), ["Room 2", "Study"])

    def test_barometer_reading_is_kept_and_listed_with_the_rooms(self):
        data = two_rooms()
        data["baro"] = {"session": "s1", "rel_m": -2.9, "kpa": 101.2, "at": 1000.0}
        m = self.upload(data=data).json()
        self.assertEqual(m["baro"], data["baro"])
        rooms = self.c.get("/api/houses/synthetic-box/rooms", headers=self.ok).json()
        self.assertTrue(all(r["baro"] == data["baro"] for r in rooms))
        bad = two_rooms()
        bad["baro"] = {"session": "s1", "rel_m": "high"}
        self.assertIsNone(self.upload(data=bad).json()["baro"])

    def test_staircase_summary_floors_and_the_stairs_scan(self):
        from tests.test_stairs import with_stairs
        data = two_rooms()
        with_stairs(data["rooms"][0], 1.0, 1.0, w=1.2, d=4.9, rise=3.3)
        m = self.upload(data=data).json()
        self.assertEqual(m["stairs_found"], [{"rise": 3.3, "width": 1.2, "run": 4.9}])
        lv = self.c.post("/api/houses/synthetic-box/levels", json={"name": "Up"}, headers=self.ok).json()["levels"][-1]["id"]
        bad = self.c.put(f"{self.url}/{m['blob']}/stair", json={"from_level": "L0", "to_level": "L0"}, headers=self.ok)
        self.assertEqual(bad.status_code, 422)
        ok = self.c.put(f"{self.url}/{m['blob']}/stair", json={"from_level": "L0", "to_level": lv}, headers=self.ok)
        self.assertEqual(ok.json()["stair"], {"from_level": "L0", "to_level": lv})
        out = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", headers=self.ok).json()
        self.assertEqual([(s["from_level"], s["to_level"]) for s in out["house"]["stairs"]], [("L0", lv)])
        # a scan made for the stairs: no rooms in the list, no rooms on import, walls kept
        st = self.c.post(self.url + f"?name=Stairs&purpose=stairs&stair_from=L0&stair_to={lv}", content=json.dumps(two_rooms(1)), headers=self.ok)
        self.assertEqual(st.status_code, 200, st.text)
        keys = [r["capture"] for r in self.c.get("/api/houses/synthetic-box/rooms", headers=self.ok).json()]
        self.assertNotIn(st.json()["blob"], keys)
        imp = self.c.post(f"{self.url}/{st.json()['blob']}/import?level=L0", headers=self.ok).json()
        self.assertEqual([r for r in imp["house"]["rooms"] if (r["prov"].get("ref") or "").startswith(st.json()["blob"])], [])
        self.assertTrue(any("no stairs object" in n for n in imp["report"]["notes"]))
        self.assertEqual(self.c.post(self.url + "?purpose=other", content=json.dumps(two_rooms()), headers=self.ok).status_code, 422)

    def test_a_scan_spanning_stories_is_imported_on_each_rooms_floor(self):
        lv = self.c.post("/api/houses/synthetic-box/levels", json={"name": "Up"}, headers=self.ok).json()["levels"][-1]["id"]
        data = two_rooms()
        data["rooms"][0]["story"], data["rooms"][1]["story"] = 0, 1
        data["room_levels"] = ["L0", lv]
        m = self.upload(data=data).json()
        self.assertEqual((m["stories"], m["room_levels"]), ([0, 1], ["L0", lv]))
        rooms = {r["index"]: r for r in self.c.get("/api/houses/synthetic-box/rooms", headers=self.ok).json() if r["capture"] == m["blob"]}
        self.assertEqual((rooms[0]["level"], rooms[1]["level"], rooms[1]["story"]), ("L0", lv, 1))
        out = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", headers=self.ok).json()
        mine = lambda x: (x["prov"].get("ref") or "").startswith(m["blob"])  # noqa: E731
        by_level = {}
        for w in filter(mine, out["house"]["walls"]):
            by_level[w["level"]] = by_level.get(w["level"], 0) + 1
        self.assertEqual(by_level, {"L0": 4, lv: 4})   # four walls each, never merged across the floors
        self.assertEqual(sorted(r["level"] for r in filter(mine, out["house"]["rooms"])), sorted(["L0", lv]))
        self.assertEqual(sorted(f["level"] for f in filter(mine, out["house"]["furniture"])), sorted(["L0", lv]))
        # importing again replaces everything of this scan on both floors
        again = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", json={"house": out["house"]}, headers=self.ok).json()
        self.assertEqual(len([w for w in again["house"]["walls"] if mine(w)]), 8)
        # an unknown floor is refused; moving the whole scan to one floor clears the split
        data["room_levels"] = ["L0", "nope"]
        self.assertEqual(self.upload(data=data).status_code, 422)
        moved = self.c.put(f"{self.url}/{m['blob']}/level", json={"level": "L0"}, headers=self.ok).json()
        self.assertIsNone(moved["room_levels"])

    def test_import_with_a_transform(self):
        m = self.upload().json()
        r = self.c.post(f"{self.url}/{m['blob']}/import?level=L0", content=json.dumps({"transform": {"rotation": 90, "tx": 10, "ty": 20}}),
                        headers=self.ok).json()
        walls = [w for w in r["house"]["walls"] if (w["prov"].get("ref") or "").startswith(m["blob"])]
        self.assertTrue(all(w["a"][0] >= 10 - 4.5 and w["a"][1] >= 20 for w in walls))

    def test_level_is_kept_with_the_capture(self):
        r = self.c.post(self.url + "?name=Basement&level=L0", content=json.dumps(two_rooms()), headers=self.ok)
        self.assertEqual((r.status_code, r.json()["level"], r.json()["name"]), (200, "L0", "Basement"))
        self.assertEqual(self.c.post(self.url + "?level=nope", content=json.dumps(two_rooms()), headers=self.ok).status_code, 422)
        self.assertEqual(self.upload().json()["level"], "L0")  # the same scan again keeps what is known
        self.assertEqual(self.c.get(self.url, headers=self.ok).json()[0]["level"], "L0")

    def test_room_list_descriptions_and_floor_move(self):
        url = "/api/houses/fresh/captures"
        self.c.post("/api/houses", json={"id": "fresh", "name": "Fresh"}, headers=self.ok)
        h = self.c.post("/api/houses/fresh/levels", json={"name": "First"}, headers=self.ok).json()
        m = self.c.post(url + "?level=L0", content=json.dumps(two_rooms()), headers=self.ok).json()
        rooms = self.c.get("/api/houses/fresh/rooms", headers=self.ok).json()
        self.assertEqual([(r["index"], r["placed"], r["level"]) for r in rooms], [(0, None, "L0"), (1, None, "L0")])
        r = self.c.put(f"{url}/{m['blob']}/rooms", json={"names": ["Great room", "Corby"], "descriptions": ["", "boy's room"]}, headers=self.ok)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.c.put(f"{url}/{m['blob']}/rooms", json={"names": ["a", "b"], "descriptions": ["x"]}, headers=self.ok).status_code, 422)
        imp = self.c.post(f"{url}/{m['blob']}/import?level=L0", headers=self.ok).json()["house"]
        self.assertEqual(self.c.put("/api/houses/fresh?expect_revision=%d" % h["revision"], content=json.dumps(imp), headers=self.ok).status_code, 200)
        rooms = self.c.get("/api/houses/fresh/rooms", headers=self.ok).json()
        self.assertEqual([(r["name"], r["description"], bool(r["placed"])) for r in rooms], [("Great room", "", True), ("Corby", "boy's room", True)])
        # the floor of a placed scan moves with its walls and rooms, in one revision
        before = self.c.get("/api/houses/fresh", headers=self.ok).json()["revision"]
        mv = self.c.put(f"{url}/{m['blob']}/level", json={"level": "L1"}, headers=self.ok)
        self.assertEqual((mv.status_code, mv.json()["level"]), (200, "L1"))
        house = self.c.get("/api/houses/fresh", headers=self.ok).json()
        self.assertTrue(all(w["level"] == "L1" for w in house["walls"]))
        self.assertTrue(all(r["level"] == "L1" for r in house["rooms"]))
        self.assertEqual(house["revision"], before + 1)
        self.assertEqual({r["level"] for r in self.c.get("/api/houses/fresh/rooms", headers=self.ok).json()}, {"L1"})
        self.assertEqual(self.c.put(f"{url}/{m['blob']}/level", json={"level": "nope"}, headers=self.ok).status_code, 422)

    def test_rescan_replaces_the_rooms_own_walls_and_keeps_history(self):
        self.c.post("/api/houses", json={"id": "again", "name": "Again"}, headers=self.ok)
        url = "/api/houses/again/captures"
        x = self.c.post(url + "?level=L0", content=json.dumps(two_rooms()), headers=self.ok).json()
        self.c.put(f"{url}/{x['blob']}/rooms", json={"names": ["Great room", "Corby"]}, headers=self.ok)
        imp = self.c.post(f"{url}/{x['blob']}/import?level=L0", headers=self.ok).json()["house"]
        rev = self.c.get("/api/houses/again", headers=self.ok).json()["revision"]
        self.c.put(f"/api/houses/again?expect_revision={rev}", content=json.dumps(imp), headers=self.ok)
        walls_before = len(imp["walls"])
        # Great room scanned again from another start point
        y_data = moved(wrap(two_rooms()["rooms"][0]), 30, 2, 1)
        self.assertEqual(self.c.post(url + "?replaces=nope", content=json.dumps(y_data), headers=self.ok).status_code, 422)
        y = self.c.post(url + f"?level=L0&replaces={x['blob']}:0", content=json.dumps(y_data), headers=self.ok).json()
        self.c.put(f"{url}/{y['blob']}/rooms", json={"names": ["Great room"]}, headers=self.ok)
        p = self.c.post(f"{url}/{y['blob']}/place?level=L0", headers=self.ok).json()
        self.assertEqual(p["confidence"], "auto", p)  # matched against Corby's room through the shared doorway
        r = self.c.post(f"{url}/{y['blob']}/import?level=L0", content=json.dumps({"transform": p["transform"]}), headers=self.ok).json()
        after = r["house"]
        self.assertEqual(len([w for w in after["walls"] if w["prov"]["ref"].startswith(x["blob"])]), 4)  # Corby's three walls and the wall shared with it stay; the room's other three go
        self.assertEqual(len([w for w in after["walls"] if w["prov"]["ref"].startswith(y["blob"])]), 4)
        self.assertEqual(sorted(room["name"] for room in after["rooms"]), ["Corby", "Great room"])
        self.assertTrue(any("replaced the earlier scan" in n for n in r["report"]["notes"]))
        rev = self.c.get("/api/houses/again", headers=self.ok).json()["revision"]
        self.c.put(f"/api/houses/again?expect_revision={rev}", content=json.dumps(after), headers=self.ok)
        rooms = {x_["key"]: x_ for x_ in self.c.get("/api/houses/again/rooms", headers=self.ok).json()}
        self.assertEqual(rooms[f"{x['blob']}:0"]["replaced_by"], f"{y['blob']}:0")
        self.assertIsNone(rooms[f"{y['blob']}:0"]["replaced_by"])
        self.assertEqual(walls_before, 7)  # 3 + 3 exclusive walls and the shared one

    def test_place_endpoint(self):
        self.c.post("/api/houses", json={"id": "fresh", "name": "Fresh"}, headers=self.ok)
        url = "/api/houses/fresh/captures"
        m = self.c.post(url, content=json.dumps(two_rooms()), headers=self.ok).json()
        p = self.c.post(f"{url}/{m['blob']}/place?level=L0", headers=self.ok)
        self.assertEqual(p.status_code, 200, p.text)
        self.assertEqual(p.json()["confidence"], "auto")  # an empty level: nothing to line up with
        self.assertEqual(self.c.post(f"{url}/{m['blob']}/place?level=nope", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(f"{url}/{'0' * 64}/place?level=L0", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(f"{url}/{m['blob']}/place?level=L0").status_code, 401)

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
