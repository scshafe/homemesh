import Foundation
import Testing
@testable import HomemeshCore

private func library() -> LocalAPI {
    LocalAPI(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-pkg-\(UUID().uuidString)"))
}

/// A library with one house that has a scan (and so a stored file), built from the recorded synthetic session.
private func house(in a: LocalAPI) throws -> String {
    _ = try a.handle("POST", "/api/houses", body: Data(#"{"id": "demo", "name": "Demo"}"#.utf8))
    let log = try JSONSerialization.jsonObject(with: golden("api_session")) as! [JObject]
    let up = log.first { ($0["path"] as? String)?.hasPrefix("/api/houses/demo/captures?name=Kitchen") == true }!
    let meta = try JSONSerialization.jsonObject(with: a.handle("POST", up["path"] as! String, body: Data((up["body"] as! String).utf8))) as! JObject
    return meta["blob"] as! String
}

private func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).homemesh") }

@Test func aHouseTravelsAsOneFileAndComesBackTheSame() throws {
    let a = library(), b = library()
    let digest = try house(in: a)
    let file = tempFile()
    let out = try HousePackage.export(house: "demo", from: a, to: file)
    #expect(out.differences.isEmpty)
    #expect(out.files == 3)   // the document, the scan's index, its stored file
    let back = try HousePackage.importPackage(from: file, into: b)
    #expect(back.id == "demo" && back.differences.isEmpty)
    #expect(try b.counts(of: "demo") == a.counts(of: "demo"))
    #expect(try b.handle("GET", "/api/houses/demo/captures/\(digest)/doors") == a.handle("GET", "/api/houses/demo/captures/\(digest)/doors"))
    #expect(try b.handle("GET", "/api/houses/demo") == a.handle("GET", "/api/houses/demo"))
    #expect(throws: APIError.self) { try HousePackage.importPackage(from: file, into: b) }   // never overwrites
}

@Test func aDamagedOrCutShortFileIsRefusedAndLeavesNothing() throws {
    let a = library()
    _ = try house(in: a)
    let file = tempFile()
    try HousePackage.export(house: "demo", from: a, to: file)
    let whole = try Data(contentsOf: file)

    let cut = tempFile()
    try whole.prefix(whole.count - 40).write(to: cut)
    let b = library()
    #expect(throws: APIError.self) { try HousePackage.importPackage(from: cut, into: b) }
    #expect(b.houseIds().isEmpty)

    var flipped = whole
    flipped[flipped.count / 2] ^= 0xff   // somewhere in the middle: a stored file or the scan index
    let bad = tempFile()
    try flipped.write(to: bad)
    #expect(throws: APIError.self) { try HousePackage.importPackage(from: bad, into: b) }
    #expect(b.houseIds().isEmpty)
    #expect(throws: APIError.self) { try HousePackage.verify(bad) }

    let notOurs = tempFile()
    try Data("hello".utf8).write(to: notOurs)
    #expect(throws: APIError.self) { try HousePackage.verify(notOurs) }
}
