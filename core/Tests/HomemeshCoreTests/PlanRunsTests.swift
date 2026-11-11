import Foundation
import Testing
@testable import HomemeshCore

private func library() throws -> (LocalAPI, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-runs-\(UUID().uuidString)")
    let a = LocalAPI(root: root)
    let scenarios = try JSONSerialization.jsonObject(with: golden("plans")) as! [JObject]
    var house = scenarios[2]["house"] as! JObject
    house["id"] = "box"
    try a.restoreHouse(id: "box", house: JSONSerialization.data(withJSONObject: house), captures: [], blobs: [:])
    return (a, root)
}

private func json(_ d: Data) throws -> JObject { try JSONSerialization.jsonObject(with: d) as! JObject }

private func wait(_ a: LocalAPI, _ job: String) async throws -> JObject {
    for _ in 0..<600 {
        let s = try json(a.handle("GET", "/api/jobs/\(job)"))
        if s["state"] as? String != "running" { return s }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw APIError(500, "the plan did not finish")
}

@Test func aFinishedPlanIsKeptAndAnotherCannotRunAtOnce() async throws {
    let (a, _) = try library()
    var latest = try json(a.handle("GET", "/api/houses/box/plans/latest"))
    #expect(latest["running"] is NSNull && latest["saved"] is NSNull)
    let body = Data(#"{"k_max": 1, "equipment": ["generic-mesh-ax"]}"#.utf8)
    let job = try json(a.handle("POST", "/api/houses/box/plans", body: body))["job"] as! String
    latest = try json(a.handle("GET", "/api/houses/box/plans/latest"))
    #expect(latest["running"] as? String == job)
    #expect(throws: APIError.self) { try a.handle("POST", "/api/houses/box/plans", body: body) }
    let done = try await wait(a, job)
    #expect(done["state"] as? String == "done")
    latest = try json(a.handle("GET", "/api/houses/box/plans/latest"))
    let saved = latest["saved"] as! JObject
    #expect(latest["running"] is NSNull && saved["revision"] is NSNumber && saved["finished"] is String)
    #expect(((saved["result"] as! JObject)["results"] as! [Any]).count == (done["result"] as! JObject)["results"].flatMap { ($0 as! [Any]).count })
}

@Test func aCancelledPlanLeavesTheKeptOneAlone() async throws {
    let (a, _) = try library()
    let quick = Data(#"{"k_max": 1, "equipment": ["generic-mesh-ax"]}"#.utf8)
    let first = try json(a.handle("POST", "/api/houses/box/plans", body: quick))["job"] as! String
    _ = try await wait(a, first)
    let before = try a.handle("GET", "/api/houses/box/plans/latest")
    let long = Data(#"{"k_max": 4, "candidate_step": 0.5}"#.utf8)
    let second = try json(a.handle("POST", "/api/houses/box/plans", body: long))["job"] as! String
    _ = try a.handle("POST", "/api/jobs/\(second)/cancel")
    let end = try await wait(a, second)
    #expect(end["state"] as? String == "error" && end["error"] as? String == "cancelled")
    #expect(try a.handle("GET", "/api/houses/box/plans/latest") == before)
    #expect(throws: APIError.self) { try a.handle("POST", "/api/jobs/nope/cancel") }
}
