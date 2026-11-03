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
