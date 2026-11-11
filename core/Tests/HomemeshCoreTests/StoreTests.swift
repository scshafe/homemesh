import Foundation
import Testing
@testable import HomemeshCore

func tempStore(keep: Int = 20) -> HouseStore {
    HouseStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-test-\(UUID().uuidString)"), keep: keep)
}

@Test func sha256KnownVectors() {
    #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let long = Data(String(repeating: "a", count: 1000).utf8)
    #expect(SHA256.hex(long) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
}

@Test func saveCountsRevisionsAndRefusesAStaleOne() throws {
    let s = tempStore()
    let house = try House.load(golden("one_floor_box.house"))
    let r1 = try s.save(house, expect: nil)
    #expect(r1.revision == 1)
    let r2 = try s.save(r1, expect: 1)
    #expect(r2.revision == 2)
    #expect(throws: StoreError.conflict(have: 2, got: 1)) { try s.save(r1, expect: 1) }
    #expect(try s.load().revision == 2)
    #expect(s.revisions() == [1, 2])
}

@Test func anInvalidHouseIsNotWritten() throws {
    let s = tempStore()
    var house = try House.load(golden("one_floor_box.house"))
    house.walls[0].level = "nowhere"
    #expect(throws: StoreError.self) { try s.save(house, expect: nil) }
    #expect(!s.exists)
}

@Test func oldRevisionsArePrunedAndUndoRestoresAnEarlierOne() throws {
    let s = tempStore(keep: 3)
    var h = try s.save(try House.load(golden("one_floor_box.house")), expect: nil)
    for i in 1...5 { h.name = "v\(i)"; h = try s.save(h, expect: h.revision) }
    #expect(s.revisions() == [4, 5, 6])
    let back = try s.restore(revision: 4, expect: 6)
    #expect(back.name == "v3" && back.revision == 7)
    #expect(try s.load().name == "v3")
}

@Test func blobsAreContentAddressed() throws {
    let s = tempStore()
    let d = try s.putBlob(Data("scan".utf8))
    #expect(d == SHA256.hex(Data("scan".utf8)))
    #expect(try s.putBlob(Data("scan".utf8)) == d)
    #expect(try s.blob(d) == Data("scan".utf8))
    #expect(throws: StoreError.badId("blob id")) { try s.blob("../house.json") }
    #expect(throws: StoreError.missing("blob")) { try s.blob(String(repeating: "0", count: 64)) }
}

// Format version 1 as first shipped (a frozen copy: scripts/golden never rewrites it). It must keep opening as the model grows.
@Test func aFormatOneHouseStillOpens() throws {
    let data = try golden("frozen_v1.house")
    let h = try House.load(lenient: data)
    #expect(h.schema_version == 1 && !h.walls.isEmpty)
    let s = tempStore()
    try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
    try data.write(to: s.root.appendingPathComponent("house.json"))
    #expect(try s.load().id == h.id)
}

@Test func aHouseFromANewerAppIsRefusedPlainly() throws {
    var o = try JSONSerialization.jsonObject(with: golden("frozen_v1.house")) as! JObject
    o["schema_version"] = House.schemaVersion + 1
    #expect(throws: ImportError.self) { try House.load(lenient: JSONSerialization.data(withJSONObject: o)) }
}

@Test func migrationStepsRunInOrder() throws {
    let steps: [Int: @Sendable (JObject) -> JObject] = [1: { var o = $0; o["name"] = ($0["name"] as! String) + "+1"; return o }, 2: { var o = $0; o["name"] = ($0["name"] as! String) + "+2"; return o }]
    let o = try JSONSerialization.jsonObject(with: golden("frozen_v1.house")) as! JObject
    let up = try Migrations.upgrade(o, to: 3, steps: steps)
    #expect((up["name"] as! String).hasSuffix("+1+2") && up["schema_version"] as? Int == 3)
    #expect(throws: ImportError.self) { try Migrations.upgrade(o, to: 3, steps: [:]) }
    #expect(Migrations.steps.isEmpty && House.schemaVersion == 1)
}

@Test func aHouseThatCannotBeReadIsListedAndExportedNotHidden() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-bad-\(UUID().uuidString)")
    let a = LocalAPI(root: root)
    _ = try a.handle("POST", "/api/houses", body: Data(#"{"id": "mine", "name": "Mine"}"#.utf8))
    let file = root.appendingPathComponent("houses/mine/house.json")
    let damaged = Data(#"{"id": "mine", "schema_version": 99}"#.utf8)
    try damaged.write(to: file)
    let rows = try JSONSerialization.jsonObject(with: a.handle("GET", "/api/houses/summary")) as! [JObject]
    #expect(rows.count == 1 && rows[0]["id"] as? String == "mine" && (rows[0]["unreadable"] as? String)?.contains("newer") == true)
    #expect(throws: APIError.self) { try a.handle("GET", "/api/houses/mine") }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).homemesh")
    let r = try HousePackage.export(house: "mine", from: a, to: out)
    #expect(r.id == "mine" && r.differences.isEmpty)
    #expect(try Data(contentsOf: file) == damaged)   // nothing was touched
}
