import Foundation
import Testing
@testable import HomemeshCore

/// A deterministic generator for synthetic scans (no system randomness: the tests must repeat).
struct Lcg { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double { let u = max(next(), 1e-12), v = next(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) } }

/// Rooms of a cols x rows grid, each 4 x 3 m, every neighbour pair joined by a doorway in the shared wall.
/// Each scan lives in its own random frame and sees its doors with `sigma` metres and `headingDeg` degrees of noise.
func gridScans(cols: Int, rows: Int, sigma: Double, headingDeg: Double, seed: UInt64) -> (truth: [Pose], connections: [Connection], manhattan: [Double?]) {
    var rng = Lcg(s: seed)
    let w = 4.0, h = 3.0
    var truth: [Pose] = [], frames: [Pose] = []          // truth: scan frame -> plan; frames: the same with the scan's noise
    for r in 0..<rows { for c in 0..<cols {
        // the room's centre is the scan origin; the plan position is the room centre; the scan is turned arbitrarily
        let ang = rng.next() * 2 * .pi
        truth.append(Pose(angle: ang, t: Vec2(Double(c) * (w + 0.1) + w / 2, Double(r) * (h + 0.1) + h / 2)))
        frames.append(truth.last!)
    } }
    func doorRef(_ i: Int, plan: Vec2, normalPlan: Vec2) -> DoorRef {
        let p = truth[i]
        let back = Pose(angle: -p.angle, t: Vec2(0, 0))
        let local = back.apply(plan - p.t)
        let n = back.rotate(normalPlan)
        let noise = Vec2(rng.gauss() * sigma, rng.gauss() * sigma)
        let tilt = rng.gauss() * headingDeg * .pi / 180
        let nn = Pose(angle: tilt, t: Vec2(0, 0)).rotate(n)
        return DoorRef(scan: i, at: local + noise, normal: nn)
    }
    var conns: [Connection] = []
    for r in 0..<rows { for c in 0..<cols {
        let i = r * cols + c
        if c + 1 < cols {   // door in the wall between i and i+1 (east of i)
            let y = Double(r) * (h + 0.1) + h / 2, x = Double(c) * (w + 0.1) + w
            conns.append(Connection(a: doorRef(i, plan: Vec2(x, y), normalPlan: Vec2(1, 0)), b: doorRef(i + 1, plan: Vec2(x + 0.1, y), normalPlan: Vec2(-1, 0)), gap: 0.1))
        }
        if r + 1 < rows {
            let x = Double(c) * (w + 0.1) + w / 2, y = Double(r) * (h + 0.1) + h
            conns.append(Connection(a: doorRef(i, plan: Vec2(x, y), normalPlan: Vec2(0, 1)), b: doorRef(i + cols, plan: Vec2(x, y + 0.1), normalPlan: Vec2(0, -1)), gap: 0.1))
        }
    } }
    // each scan's dominant wall direction in its own frame: the plan's axes seen through the scan's turn, with wall-fit noise
    let man: [Double?] = truth.map { -$0.angle + rng.gauss() * 0.3 * .pi / 180 }
    return (truth, conns, man)
}

/// How far each placed scan's centre lies from the truth after the best rigid motion of the whole layout (the map's own
/// orientation and position are arbitrary; only the layout's shape matters to a plan).
func centreErrors(_ result: LayoutResult, truth: [Pose]) -> [Double] {
    let items = result.poses.sorted { $0.key < $1.key }
    let est = items.map { $0.value.apply(Vec2(0, 0)) }, tru = items.map { truth[$0.key].apply(Vec2(0, 0)) }
    let n = Double(est.count)
    let ce = Vec2(est.map(\.x).reduce(0, +) / n, est.map(\.y).reduce(0, +) / n), ct = Vec2(tru.map(\.x).reduce(0, +) / n, tru.map(\.y).reduce(0, +) / n)
    var sxx = 0.0, sxy = 0.0   // 2D Procrustes: the rotation that best turns est onto tru
    for (e, t) in zip(est, tru) { let a = e - ce, b = t - ct; sxx += a.x * b.x + a.y * b.y; sxy += a.x * b.y - a.y * b.x }
    let rot = Pose(angle: atan2(sxy, sxx), t: Vec2(0, 0))
    return zip(est, tru).map { (rot.apply($0 - ce) + ct - $1).length }
}

@Test func twoRoomsJoinExactlyWithoutNoise() {
    let (truth, conns, _) = gridScans(cols: 2, rows: 1, sigma: 0, headingDeg: 0, seed: 1)
    let res = Layout.solve(scans: 2, connections: conns)
    #expect(res.unplaced.isEmpty)
    #expect(res.maxResidual < 1e-6)
    #expect(centreErrors(res, truth: truth).max()! < 1e-6)
}

@Test func aGridOfRoomsStaysWithinHalfAMetreWithLabelNoise() {
    var worstCentre = 0.0, worstResidual = 0.0
    for seed in 1...20 {
        let (truth, conns, _) = gridScans(cols: 4, rows: 3, sigma: 0.08, headingDeg: 1.0, seed: UInt64(seed))
        let res = Layout.solve(scans: 12, connections: conns)
        #expect(res.unplaced.isEmpty)
        worstCentre = max(worstCentre, centreErrors(res, truth: truth).max()!)
        worstResidual = max(worstResidual, res.maxResidual)
    }
    print("LAYOUT 4x3 grid, 8 cm label noise, 1 degree heading noise, 20 seeds: worst centre error \(worstCentre) m, worst residual \(worstResidual) m")
    #expect(worstCentre < 0.5)
    #expect(worstResidual < 0.5)
}

@Test func loopsTightenAChain() {
    var chainWorst = 0.0, gridWorst = 0.0
    for seed in 1...20 {
        let (t1, c1, m1) = gridScans(cols: 8, rows: 1, sigma: 0.08, headingDeg: 1.0, seed: UInt64(seed))
        chainWorst = max(chainWorst, centreErrors(Layout.solve(scans: 8, connections: c1), truth: t1).max()!)
        let (t2, c2, m2) = gridScans(cols: 4, rows: 2, sigma: 0.08, headingDeg: 1.0, seed: UInt64(seed))
        gridWorst = max(gridWorst, centreErrors(Layout.solve(scans: 8, connections: c2), truth: t2).max()!)
    }
    print("LAYOUT 8 rooms: chain worst centre error \(chainWorst) m, the same rooms as a 4x2 grid with loops \(gridWorst) m")
    #expect(chainWorst < 0.8)
    #expect(gridWorst <= chainWorst)
}

@Test func aScanWithoutAConnectionIsReportedNotGuessed() {
    let (_, conns, _) = gridScans(cols: 2, rows: 1, sigma: 0, headingDeg: 0, seed: 1)
    let res = Layout.solve(scans: 3, connections: conns)
    #expect(res.unplaced == [2])
}

/// Worst centre error over seeds for a layout shape, with and without the right-angle prior.
func drift(cols: Int, rows: Int, headingDeg: Double, sigma: Double, prior: Bool) -> Double {
    var worst = 0.0
    for seed in 1...20 {
        let (t, c, m) = gridScans(cols: cols, rows: rows, sigma: sigma, headingDeg: headingDeg, seed: UInt64(seed))
        worst = max(worst, centreErrors(Layout.solve(scans: cols * rows, connections: c, manhattan: prior ? m : []), truth: t).max()!)
    }
    return worst
}

@Test func driftTableAndTheRightAnglePrior() {
    for (cols, rows) in [(8, 1), (4, 3)] {
        for heading in [0.3, 1.0] {
            let a = drift(cols: cols, rows: rows, headingDeg: heading, sigma: 0.08, prior: false)
            let b = drift(cols: cols, rows: rows, headingDeg: heading, sigma: 0.08, prior: true)
            print("DRIFT \(cols)x\(rows) rooms, door heading noise \(heading) deg, 8 cm label noise: worst centre error \(String(format: "%.2f", a)) m without the right-angle prior, \(String(format: "%.2f", b)) m with it")
        }
    }
    #expect(drift(cols: 8, rows: 1, headingDeg: 1.0, sigma: 0.08, prior: true) < 0.5)
}
