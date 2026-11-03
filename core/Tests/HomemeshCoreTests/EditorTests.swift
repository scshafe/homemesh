import Foundation
import Testing
@testable import HomemeshCore

func wall(_ id: String, _ a: Vec2, _ b: Vec2) -> Wall { Wall(id: id, level: "L0", a: a, b: b, thickness: 0.1, height: 2.5, base_z: 0, material: "drywall", openings: []) }

@Test func endpointBeatsMidpointBeatsWallBeatsGrid() {
    let ws = [wall("w1", Vec2(0, 0), Vec2(4, 0))]
    #expect(Snap.resolve(Vec2(0.03, 0.04), walls: ws, tolerance: 0.1).kind == .endpoint)
    #expect(Snap.resolve(Vec2(2.02, 0.05), walls: ws, tolerance: 0.1).kind == .midpoint)
    #expect(Snap.resolve(Vec2(1.0, 0.07), walls: ws, tolerance: 0.1).kind == .onWall)
    #expect(Snap.resolve(Vec2(1.0, 1.0), walls: ws, tolerance: 0.1).kind == .grid)
    #expect(Snap.resolve(Vec2(0.03, 0.04), walls: ws, tolerance: 0.1).label == "end of wall w1")
}

@Test func drawingSnapsToRightAnglesAndToParallelWithinTolerance() {
    let ws = [wall("w1", Vec2(0, 5), Vec2(3, 5.6))]       // a skewed wall, about 11 degrees
    let h = Snap.resolve(Vec2(3, 0.1), walls: [], tolerance: 0.05, from: Vec2(0, 0))      // 1.9 degrees off horizontal
    #expect(h.kind == .axis)
    #expect(abs(h.point.y) < 1e-9)
    let p = Snap.resolve(Vec2(6, 1.25), walls: ws, tolerance: 0.05, from: Vec2(0, 0))     // along the skewed wall's direction
    #expect(p.kind == .parallel)
    #expect(p.label == "parallel to wall w1")
    #expect(Snap.resolve(Vec2(3, 0.5), walls: [], tolerance: 0.05, from: Vec2(0, 0)).kind == .grid)    // 9 degrees: no direction snap
}

@Test func applyThenInverseGivesTheOriginalAndRedoRepeats() throws {
    let data = try golden("one_floor_box.house")
    var doc = Document(try House.load(data))
    let before = doc.house.walls
    let walls = Draw.trace(points: [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2)], closed: true, level: "L0", material: "drywall", thickness: 0.1, height: 2.5, ids: { doc.nextWallId() })
    #expect(walls.count == 3)
    // ids come from a closure over the live document, so give them distinct names explicitly
    let named = walls.enumerated().map { (i, w) -> Wall in var x = w; x.id = "n\(i)"; return x }
    doc.apply(.group(named.map { .addWall($0) }))
    #expect(doc.house.walls.count == before.count + 3)
    doc.undo()
    #expect(doc.house.walls == before)
    #expect(doc.canRedo)
    doc.redo()
    #expect(doc.house.walls.count == before.count + 3)
    var moved = named[0]; moved.b = Vec2(2.5, 0)
    doc.apply(.replaceWall(old: named[0], new: moved))
    doc.undo()
    #expect(doc.house.walls.first { $0.id == "n0" } == named[0])
    #expect(doc.canRedo)
}
