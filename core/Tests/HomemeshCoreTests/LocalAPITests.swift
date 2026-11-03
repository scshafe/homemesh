import Foundation
import Testing
@testable import HomemeshCore

@Test func theInProcessAPIAnswersARecordedPythonSessionTheSame() throws {
    let log = try JSONSerialization.jsonObject(with: golden("api_session")) as! [JObject]
    #expect(log.count >= 50)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-api-\(UUID().uuidString)")
    let ticks = Ticks()
    let api = LocalAPI(root: root, now: { 1_700_000_000 + ticks.next() })
    var lastJobPath: String?
    for (n, rec) in log.enumerated() {
        let method = rec["method"] as! String
        var path = rec["path"] as! String
        if rec["poll"] as? Bool == true, let p = lastJobPath { path = p }
        let tag = "#\(n) \(method) \(path.prefix(70))"
        let body = (rec["body"] as? String).map { Data($0.utf8) } ?? Data()
        let want = rec["status"] as! Int
        var status = 200
        var got: Data?
        do {
            got = try api.handle(method, path, body: body)
            if rec["poll"] as? Bool == true {   // a plan job runs in the background: ask until it is done
                var tries = 0
                while tries < 600, let o = try JSONSerialization.jsonObject(with: got!) as? JObject, o["state"] as? String == "running" { Thread.sleep(forTimeInterval: 0.1); got = try api.handle(method, lastJobPath ?? path); tries += 1 }
            }
            if method == "POST", path.hasSuffix("/plans"), let o = try JSONSerialization.jsonObject(with: got!) as? JObject, let j = o["job"] as? String { lastJobPath = "/api/jobs/\(j)" }
        } catch let e as APIError { status = e.status; got = try JSONSerialization.data(withJSONObject: ["detail": e.detail]) }
        let expectedOK = (200..<300).contains(want)
        #expect(status == (expectedOK ? 200 : want), "\(tag): status \(status) vs \(want)")
        guard let got else { continue }
        if let response = rec["response"], !(response is NSNull) {
            let g = try JSONSerialization.jsonObject(with: got, options: [.fragmentsAllowed])
            if let d = firstDifference(withoutCollinearPoints(g), withoutCollinearPoints(response), tol: 2e-4, ignore: ["at", "score", "stability", "lines", "detail", "job"]) { Issue.record("\(tag): \(d)") }
        } else if let bytes = rec["bytes"] as? Int { #expect(got.count == bytes, "\(tag): \(got.count) bytes vs \(bytes)") }
    }
}

/// A room outline with a vertex on a straight run is the same outline: floating-point noise decides whether the hull keeps it.
func withoutCollinearPoints(_ v: Any) -> Any {
    if let d = v as? [String: Any] {
        var out = d.mapValues(withoutCollinearPoints)
        if let poly = d["polygon"] as? [[Double]], poly.count > 3, d["id"] is String, d["name"] is String { out["polygon"] = simplified(poly) }
        return out
    }
    if let a = v as? [Any] { return a.map(withoutCollinearPoints) }
    return v
}

func simplified(_ p: [[Double]]) -> [[Double]] {
    var pts = p
    var changed = true
    while changed && pts.count > 3 {
        changed = false
        for i in 0..<pts.count {
            let a = pts[(i + pts.count - 1) % pts.count], b = pts[i], c = pts[(i + 1) % pts.count]
            if abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) < 1e-6 { pts.remove(at: i); changed = true; break }
        }
    }
    return pts
}

/// A clock that moves one second per reading, as the recorded session's did.
final class Ticks: @unchecked Sendable {
    private var n = 0.0
    private let lock = NSLock()
    func next() -> Double { lock.withLock { n += 1; return n } }
}

@Test func aHouseCopiedFromElsewhereOpensAsItWas() throws {
    // Build a house in one library, copy it (document, scan indexes, blobs) into another through restoreHouse, and compare.
    let a = LocalAPI(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-from-\(UUID().uuidString)"))
    let b = LocalAPI(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-to-\(UUID().uuidString)"))
    _ = try a.handle("POST", "/api/houses", body: Data(#"{"id": "demo", "name": "Demo"}"#.utf8))
    let log = try JSONSerialization.jsonObject(with: golden("api_session")) as! [JObject]
    let up = log.first { ($0["path"] as? String)?.hasPrefix("/api/houses/demo/captures?name=Kitchen") == true }!
    let meta = try JSONSerialization.jsonObject(with: a.handle("POST", up["path"] as! String, body: Data((up["body"] as! String).utf8))) as! JObject
    let digest = meta["blob"] as! String
    let house = try a.handle("GET", "/api/houses/demo")
    let metas = try JSONSerialization.jsonObject(with: a.handle("GET", "/api/houses/demo/captures")) as! [Any]
    let blob = try a.handle("GET", "/api/houses/demo/blobs/\(digest)")
    try b.restoreHouse(id: "demo", house: house, captures: try metas.map { try JSONSerialization.data(withJSONObject: $0) }, blobs: [digest: blob])
    #expect(try b.counts(of: "demo") == a.counts(of: "demo"))
    #expect(try b.handle("GET", "/api/houses/demo/captures/\(digest)/doors") == a.handle("GET", "/api/houses/demo/captures/\(digest)/doors"))
    #expect(throws: APIError.self) { try b.restoreHouse(id: "demo", house: house, captures: [], blobs: [:]) }
    #expect(throws: APIError.self) { try b.restoreHouse(id: "other", house: house, captures: [], blobs: [:]) }
    #expect(throws: APIError.self) { try b.restoreHouse(id: "bad", house: house, captures: [], blobs: ["0".padding(toLength: 64, withPad: "0", startingAt: 0): Data("x".utf8)]) }
}
