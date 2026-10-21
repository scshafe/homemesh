import XCTest
@testable import HomemeshCapture

final class AuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        // RFC 7636 appendix B
        XCTAssertEqual(Auth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomStringsAreUrlSafeAndDistinct() {
        let a = Auth.randomString(), b = Auth.randomString()
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    private func jwt(exp: Double) -> String {
        let payload = Auth.base64url(try! JSONSerialization.data(withJSONObject: ["exp": exp]))
        return "e30.\(payload).sig"
    }

    func testExpiryAndFreshness() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Auth.expiry(of: jwt(exp: 1_003_600)), Date(timeIntervalSince1970: 1_003_600))
        XCTAssertTrue(Auth.isFresh(jwt(exp: 1_003_600), now: now))
        XCTAssertFalse(Auth.isFresh(jwt(exp: 1_000_060), now: now))  // inside the two-minute margin
        XCTAssertFalse(Auth.isFresh("not a jwt", now: now))
    }
}

final class PendingScanTests: XCTestCase {
    func testTrimmedDropsTrailingSpaceAndNewlines() {
        XCTAssertEqual("espinazo ".trimmed, "espinazo")
        XCTAssertEqual(" \thttps://x \n".trimmed, "https://x")
    }

    func testDefaultNameHasATimestamp() {
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(PendingScan.defaultName(d).hasPrefix("Scan 19"))
    }

    func testSavedScanIsKeptUntilRemoved() throws {
        let p = try PendingScan.save(name: "Test scan", json: Data("{}".utf8), usdz: nil)
        XCTAssertTrue(PendingScan.all().contains { $0.id == p.id && $0.name == "Test scan" })
        XCTAssertEqual(try p.json(), Data("{}".utf8))
        XCTAssertNil(p.usdzURL)
        p.remove()
        XCTAssertFalse(PendingScan.all().contains { $0.id == p.id })
    }
}
