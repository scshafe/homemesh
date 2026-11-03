import Foundation
import Testing
@testable import HomemeshCore

/// An invented two-floor 16 x 12 m house with about 60 walls (the notes' benchmark case).
func benchHouse() -> House {
    func mat(_ id: String, _ l: Double, _ ref: Double) -> Material { Material(id: id, name: id, loss: ["2.4": l, "5": l * 1.3, "6": l * 1.5], ref_thickness: ref, prior_sd: 2, source: "synthetic") }
    var walls: [Wall] = []
    func add(_ id: String, _ level: String, _ a: Vec2, _ b: Vec2, _ m: String, _ t: Double) {
        walls.append(Wall(id: id, level: level, a: a, b: b, thickness: t, height: 2.5, base_z: 0, material: m,
                          openings: [Opening(kind: "door", offset: 0.3, width: 0.9, height: 2, sill: 0, material: "wood", state: "closed")]))
    }
    for (li, lv) in ["L0", "L1"].enumerated() {
        let corners = [Vec2(0, 0), Vec2(16, 0), Vec2(16, 12), Vec2(0, 12)]
        for i in 0..<4 { add("\(lv)e\(i)", lv, corners[i], corners[(i + 1) % 4], "brick", 0.2) }
        for i in 1..<16 { add("\(lv)x\(i)", lv, Vec2(Double(i), 0), Vec2(Double(i) + (i % 2 == 0 ? 0 : 0.01), 12), "drywall", 0.1) }
        for j in 1..<12 { add("\(lv)y\(j)", lv, Vec2(0, Double(j)), Vec2(16, Double(j) + 0.01), "drywall", 0.1) }
        _ = li
    }
    let levels = [Level(id: "L0", name: "G", elevation: 0, height: 2.6, slab: nil),
                  Level(id: "L1", name: "F", elevation: 2.9, height: 2.6, slab: Slab(material: "slab", thickness: 0.3))]
    return House(id: "bench", name: "bench", levels: levels, materials: [mat("brick", 7, 0.2), mat("drywall", 3, 0.1), mat("wood", 3, 0.04), mat("slab", 9, 0.3)],
                 walls: walls, slab_holes: [], stairs: [])
}

#if DEBUG
let isRelease = false
#else
let isRelease = true
#endif

@Test(.enabled(if: isRelease, "timing is only meaningful in a release build: swift test -c release")) func lossMapsAtTheBenchmarkSize() {
    let house = benchHouse()
    let model = PropagationModel(house)
    let grid = Grid(level: "L0", x0: 0, y0: 0, step: 0.5, nx: 32, ny: 24, z: 1.0)    // 768 cells per floor
    let rx = grid.points().map { Vec3($0.x, $0.y, 1.0) } + grid.points().map { Vec3($0.x, $0.y, 3.9) }
    let candidates = 1426
    let clock = ContinuousClock()
    var sink = 0.0
    let t = clock.measure {
        for c in 0..<candidates {
            let tx = Vec3(0.5 + Double(c % 31) * 0.5, 0.5 + Double(c / 31 % 23) * 0.5, c % 2 == 0 ? 1.8 : 4.7)
            for band in Band.allCases { sink += model.pathLoss(tx: tx, rx: rx, band: band)[0] }
        }
    }
    let secs = Double(t.components.seconds) + Double(t.components.attoseconds) * 1e-18
    print("BENCH \(house.walls.count) walls, \(rx.count) cells, \(candidates) candidates x 3 bands: \(secs) s (\(sink))")
    #expect(secs < 60, "the Python build takes about 20 s for 70 walls and 1,536 cells")
}
