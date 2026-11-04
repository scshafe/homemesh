import Foundation
import Testing
@testable import HomemeshCore

func box() throws -> House { try House.load(golden("one_floor_box.house")) }

func same(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { (a - b).length <= tol }

@Test func movingACornerTakesTheJoinedWallsEndsWithIt() throws {
    let h = try box()
    let out = try #require(WallOps.moveEndpoint(h, wall: "e0", end: 0, to: Vec2(-0.5, 0)))
    #expect(same(out.walls.first { $0.id == "e0" }!.a, Vec2(-0.5, 0)))
    #expect(same(out.walls.first { $0.id == "e3" }!.b, Vec2(-0.5, 0)))       // the west wall ends at the same corner
    let alone = try #require(WallOps.moveEndpoint(h, wall: "e0", end: 0, to: Vec2(-0.5, 0), drag: false))
    #expect(same(alone.walls.first { $0.id == "e3" }!.b, Vec2(0, 0)))
}

@Test func splittingAWallAndMergingItBackRestoresIt() throws {
    let h = try box()
    let partition = h.walls.first { $0.id == "p0" }!       // 8 m long with a door at 3.5 to 4.4
    let halves = try #require(WallOps.split(h, wall: "p0", at: Vec2(5, 2)))
    let a = halves.walls.first { $0.id == "p0" }!, b = halves.walls.first { $0.id != "p0" && $0.a == Vec2(5, 2) }!
    #expect(a.length == 2 && b.length == 6)
    #expect(a.openings.isEmpty && b.openings.count == 1)
    #expect(abs(b.openings[0].offset - 1.5) < 1e-9)          // the door moved with its half: 3.5 - 2
    let back = try #require(WallOps.merge(halves, "p0", b.id))
    let m = back.walls.first { $0.id == "p0" }!
    #expect(same(m.a, partition.a) && same(m.b, partition.b))
    #expect(m.openings.count == 1 && abs(m.openings[0].offset - 3.5) < 1e-9)
    #expect(WallOps.split(h, wall: "p0", at: Vec2(5, 0.05)) == nil, "too close to the end to split")
    #expect(WallOps.merge(h, "e0", "e1") == nil, "walls at a corner do not merge")
}

@Test func gapsBetweenWallEndsAreClosedAndIsolatedOnesLeftAlone() throws {
    var h = try box()
    h.walls[1].a = Vec2(10.1, 0.04)       // the east wall starts a hair off the corner (10, 0)
    h.walls[2].a = Vec2(10, 8)            // untouched
    let (out, n) = WallOps.closeGaps(h, level: "L0", tol: 0.15)
    #expect(n == 1)
    #expect(same(out.walls[0].b, out.walls[1].a))
    let (_, none) = WallOps.closeGaps(h, level: "L0", tol: 0.05)
    #expect(none == 0)
}

@Test func squaringUpTurnsSkewedWallsOntoTheHousesDirections() throws {
    var h = try box()
    let w = h.walls[0]       // south wall 10 m along x
    let a = 2.0 * Double.pi / 180
    h.walls[0].a = Vec2(5 - 5 * cos(a), -5 * sin(a)); h.walls[0].b = Vec2(5 + 5 * cos(a), 5 * sin(a))
    let (out, n) = WallOps.squareUp(h, level: "L0")
    #expect(n == 1)
    #expect(abs(out.walls[0].a.y - out.walls[0].b.y) < 1e-9)
    #expect(abs(out.walls[0].length - w.length) < 1e-9)
}

@Test func openingsLandSnapSlideAndStayClear() throws {
    let h = try box()
    // the partition p0 is 8 m with a door at 3.5..4.4; a window near its middle is moved clear of the door
    let (a, k) = try #require(WallOps.addOpening(h, wall: "p0", kind: "window", along: 4.05))
    let o = a.walls.first { $0.id == "p0" }!.openings[k]
    #expect(o.kind == "window" && o.width == 1.2)
    #expect(a.walls.first { $0.id == "p0" }!.openings.count == 2)
    let ws = a.walls.first { $0.id == "p0" }!.openings
    #expect(ws[0].offset + ws[0].width <= ws[1].offset + 1e-9, "no overlap")
    let (e, ek) = try #require(WallOps.addOpening(h, wall: "e1", kind: "door", along: 0.3))
    #expect(e.walls.first { $0.id == "e1" }!.openings[ek].offset == 0, "snapped to the end")
    #expect(WallOps.addOpening(h, wall: "e0", kind: "window", along: 20)!.0.walls[0].openings[0].offset + 1.2 <= 10 + 1e-9)
    let slid = try #require(WallOps.slideOpening(h, wall: "p0", index: 0, to: 1))
    #expect(abs(slid.walls.first { $0.id == "p0" }!.openings[0].offset - 0.55) < 1e-9)   // its centre is where it was slid to
    let wider = try #require(WallOps.resizeOpening(h, wall: "p0", index: 0, width: 1.4))
    #expect(wider.walls.first { $0.id == "p0" }!.openings[0].width == 1.4)
    #expect(WallOps.resizeOpening(h, wall: "p0", index: 0, width: 0.1) == nil)
    let gone = try #require(WallOps.removeOpening(h, wall: "p0", index: 0))
    #expect(gone.walls.first { $0.id == "p0" }!.openings.isEmpty)
    #expect(gone.validate() == [])
}

@Test func linesTypedAsMeasurementsClose() {
    let pts = WallOps.byNumbers(start: Vec2(1, 1), steps: [(.east, 4), (.north, 3), (.west, 4), (.south, 3)])
    #expect(pts.count == 5)
    #expect(same(pts[4], pts[0], 1e-9))
    let diag = WallOps.byNumbers(start: Vec2(0, 0), steps: [(.angle(45), 2)])
    #expect(abs(diag[1].x - 2.0.squareRoot()) < 1e-9)
}

@Test func anOpenRoomFromThreeWallsGetsItsClosingWall() throws {
    let h = try box()
    let gap = try #require(WallOps.fillGap(h, walls: ["e0", "e1", "e2"]))      // south, east, north: the west side is missing
    #expect(gap.closing.count == 1)
    #expect(gap.outline.count == 4)
    let c = gap.closing[0]
    #expect((same(c.a, Vec2(0, 8)) && same(c.b, Vec2(0, 0))) || (same(c.a, Vec2(0, 0)) && same(c.b, Vec2(0, 8))))
    #expect(c.material == h.walls[0].material && c.level == "L0")
    let closed = try #require(WallOps.fillGap(h, walls: ["e0", "e1", "e2", "e3"]))
    #expect(closed.closing.isEmpty && closed.outline.count == 4)
    #expect(WallOps.fillGap(h, walls: ["e0"]) == nil)
}

@Test func whatIsUnderATouch() throws {
    let h = try box()
    #expect(HitTest.at(Vec2(10.05, 0.05), in: h, level: "L0", tolerance: 0.2) == .vertex(wall: "e1", end: 0) || HitTest.at(Vec2(10.05, 0.05), in: h, level: "L0", tolerance: 0.2) == .vertex(wall: "e0", end: 1))
    #expect(HitTest.at(Vec2(5, 3.9), in: h, level: "L0", tolerance: 0.2) == .opening(wall: "p0", index: 0))
    #expect(HitTest.at(Vec2(5, 1), in: h, level: "L0", tolerance: 0.2) == .wall("p0"))
    #expect(HitTest.at(Vec2(1.05, 0.25), in: h, level: "L0", tolerance: 0.2) == .outlet("o0"))
    #expect(HitTest.at(Vec2(8, 6), in: h, level: "L0", tolerance: 0.2) == .zone("z-office"))
    #expect(HitTest.at(Vec2(2, 4), in: h, level: "L0", tolerance: 0.2) == .zone("z-allow") || HitTest.at(Vec2(2, 4), in: h, level: "L0", tolerance: 0.2) == .room("r0"))
    #expect(HitTest.at(Vec2(50, 50), in: h, level: "L0", tolerance: 0.2) == .none)
}

@Test func everyOperationIsOneUndoableStep() throws {
    var doc = Document(try box())
    let before = doc.house
    doc.perform { WallOps.split($0, wall: "p0", at: Vec2(5, 2)) }
    doc.perform { WallOps.setProperties($0, walls: ["e0", "e1"], thickness: 0.3, material: "concrete") }
    doc.perform { WallOps.split($0, wall: "p0", at: Vec2(5, 0.01)) }      // refused: nothing recorded
    #expect(doc.house.walls.count == before.walls.count + 1)
    #expect(doc.house.walls.first { $0.id == "e0" }!.thickness == 0.3 && doc.house.walls.first { $0.id == "e0" }!.thickness_defaulted == false)
    doc.undo()
    #expect(doc.house.walls.first { $0.id == "e0" }!.thickness == before.walls.first { $0.id == "e0" }!.thickness)
    doc.undo()
    #expect(doc.house.walls == before.walls && !doc.canUndo)
    doc.redo(); doc.redo()
    #expect(doc.house.walls.first { $0.id == "e0" }!.material == "concrete" && !doc.canRedo)
}
