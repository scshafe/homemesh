import Foundation
import Testing
@testable import HomemeshCore

/// Drops JSON nulls (the Swift model leaves nil fields out) and blueprint underlays (not part of the standalone app).
func normalised(_ v: Any) -> Any {
    if let d = v as? [String: Any] { return d.filter { !($0.value is NSNull) && $0.key != "underlays" }.mapValues(normalised) }
    if let a = v as? [Any] { return a.map(normalised) }
    return v
}

@Test(arguments: ["one_floor_box", "two_floor_stairwell", "long_thin", "wired_ends"])
func everyFixtureSurvivesDecodeAndEncode(name: String) throws {
    let original = try golden("\(name).house")
    let house = try House.load(original)
    let again = try JSONSerialization.jsonObject(with: try house.encoded())
    let want = try JSONSerialization.jsonObject(with: original)
    #expect((normalised(again) as? NSDictionary) == (normalised(want) as? NSDictionary), "\(name) changed in a round trip")
}

@Test func theFixturesHaveWhatTheyShouldHave() throws {
    let box = try House.load(golden("one_floor_box.house"))
    #expect(box.walls.count == 5 && box.rooms.count == 2 && box.zones.count == 2 && box.outlets.count == 2)
    #expect(box.zones.first { $0.kind == "demand" }?.need?.min_throughput == 300)
    let two = try House.load(golden("two_floor_stairwell.house"))
    #expect(two.stairs.first?.to_level == "L1" && two.levels[1].slab?.material == "slab-wood")
}

@Test(arguments: ["one_floor_box", "two_floor_stairwell", "long_thin", "wired_ends"])
func fixturesAreSound(name: String) throws {
    #expect(try House.load(golden("\(name).house")).validate() == [])
}

@Test func validationNamesWhatIsWrong() throws {
    var h = try House.load(golden("one_floor_box.house"))
    h.walls[0].level = "nowhere"
    h.walls[4].openings[0].offset = 7.5
    h.zones[1].need = nil
    h.outlets.append(h.outlets[0])
    let errs = h.validate()
    #expect(errs.contains("wall e0: unknown level nowhere"))
    #expect(errs.contains("wall p0: opening runs past the wall end"))
    #expect(errs.contains("zone z-office: a demand zone needs `need`"))
    #expect(errs.contains("duplicate outlet id o0"))
}
