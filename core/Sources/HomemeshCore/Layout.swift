import Foundation

// Stitching by labelled doorways (docs/design-standalone-app.md section 3). A scan is a rigid frame; a connection says
// "door a of scan A and door b of scan B are the two sides of one doorway". The layout places scans by walking a spanning tree
// (exact up to the door positions), then spreads the disagreement of the remaining connections by least squares and reports it.

public struct DoorRef: Sendable, Hashable {
    public var scan: Int
    public var at: Vec2          // door centre, in the scan's frame
    public var normal: Vec2      // unit vector pointing out of the room through the door, in the scan's frame
    public init(scan: Int, at: Vec2, normal: Vec2) { self.scan = scan; self.at = at; self.normal = normal }
}

public struct Connection: Sendable, Hashable {
    public var a: DoorRef
    public var b: DoorRef
    /// The wall's thickness: B's door centre sits this far beyond A's along A's outward normal.
    public var gap: Double
    public init(a: DoorRef, b: DoorRef, gap: Double = 0.1) { self.a = a; self.b = b; self.gap = gap }
}

/// A rigid transform scan frame -> plan: rotate by `angle` (radians, counter-clockwise), then translate.
public struct Pose: Sendable, Hashable {
    public var angle: Double
    public var t: Vec2
    public static let identity = Pose(angle: 0, t: Vec2(0, 0))
    public init(angle: Double, t: Vec2) { self.angle = angle; self.t = t }
    public func apply(_ p: Vec2) -> Vec2 { let c = cos(angle), s = sin(angle); return Vec2(c * p.x - s * p.y + t.x, s * p.x + c * p.y + t.y) }
    public func rotate(_ v: Vec2) -> Vec2 { let c = cos(angle), s = sin(angle); return Vec2(c * v.x - s * v.y, s * v.x + c * v.y) }
}

public struct LayoutResult: Sendable {
    public var poses: [Int: Pose]                 // placed scans
    public var unplaced: [Int]                    // scans no connection reaches
    public var connections: [ConnectionFit]       // one per input connection, in order
    public var maxResidual: Double { connections.map(\.residual).max() ?? 0 }
}

public struct ConnectionFit: Sendable {
    public var residual: Double                   // metres: where B's door sits against where A says it should, after the fit
    public var treeResidual: Double               // the same for the spanning-tree placement alone (a loop's disagreement)
    public var angleError: Double                 // radians away from the doors facing each other
    public var inTree: Bool
}

public enum Layout {
    static func angle(_ v: Vec2) -> Double { atan2(v.y, v.x) }
    static func wrap(_ a: Double) -> Double { var x = a; while x > .pi { x -= 2 * .pi }; while x < -.pi { x += 2 * .pi }; return x }

    /// Residuals of one connection under two poses: [door position error x, y, rotation error scaled by `arm` metres per radian].
    static func residual(_ c: Connection, _ pa: Pose, _ pb: Pose, arm: Double) -> [Double] {
        let na = pa.rotate(c.a.normal)
        let want = pa.apply(c.a.at) + na * c.gap
        let got = pb.apply(c.b.at)
        let facing = wrap(pb.angle + angle(c.b.normal) - pa.angle - angle(c.a.normal) - .pi)
        return [got.x - want.x, got.y - want.y, facing * arm]
    }

    static func quarterWrap(_ a: Double) -> Double { var x = a.truncatingRemainder(dividingBy: .pi / 2); if x > .pi / 4 { x -= .pi / 2 }; if x < -.pi / 4 { x += .pi / 2 }; return x }

    /// `manhattan[s]` is scan s's dominant wall direction in its own frame (radians, any multiple of a quarter turn is the same
    /// direction), or nil. Houses are mostly rectilinear, so when given, every scan's dominant wall direction is pulled to the
    /// anchor's modulo 90 degrees: this removes the rotation drift that otherwise accumulates along a chain of rooms.
    public static func solve(scans: Int, connections: [Connection], anchor: Int = 0, arm: Double = 1.0, manhattan: [Double?] = []) -> LayoutResult {
        var poses: [Int: Pose] = [anchor: .identity]
        var inTree = [Bool](repeating: false, count: connections.count)
        // spanning tree by breadth first search over the connections
        var queue = [anchor]
        while !queue.isEmpty {
            let s = queue.removeFirst()
            for (i, c) in connections.enumerated() where !inTree[i] {
                var placed: DoorRef, new: DoorRef
                if c.a.scan == s, poses[c.b.scan] == nil { placed = c.a; new = c.b }
                else if c.b.scan == s, poses[c.a.scan] == nil { placed = c.b; new = c.a }
                else { continue }
                let ps = poses[s]!
                let nw = ps.rotate(placed.normal)
                // the new scan's normal must face back: R n_new = -n_placed_world
                let ang = angle(Vec2(-nw.x, -nw.y)) - angle(new.normal)
                var pose = Pose(angle: ang, t: Vec2(0, 0))
                let g = c.gap
                let door = ps.apply(placed.at) + nw * g   // the placed scan's outward normal, whichever side it is
                pose.t = door - pose.rotate(new.at)
                poses[new.scan] = pose
                inTree[i] = true
                queue.append(new.scan)
            }
        }
        let treeResiduals = connections.map { c -> (Double, Double) in
            guard let pa = poses[c.a.scan], let pb = poses[c.b.scan] else { return (0, 0) }
            let r = residual(c, pa, pb, arm: arm)
            return (hypot(r[0], r[1]), r[2] / arm)
        }
        // least squares over every placed scan except the anchor (Gauss-Newton, numeric Jacobian)
        let free = poses.keys.filter { $0 != anchor }.sorted()
        if !free.isEmpty, connections.contains(where: { poses[$0.a.scan] != nil && poses[$0.b.scan] != nil }) {
            let idx = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($1, $0) })
            let m = free.count * 3
            for _ in 0..<12 {
                var jtj = [Double](repeating: 0, count: m * m), jtr = [Double](repeating: 0, count: m)
                for c in connections {
                    guard let pa = poses[c.a.scan], let pb = poses[c.b.scan] else { continue }
                    let r0 = residual(c, pa, pb, arm: arm)
                    var cols: [(Int, [Double])] = []
                    for (scan, isA) in [(c.a.scan, true), (c.b.scan, false)] {
                        guard let k = idx[scan] else { continue }
                        for v in 0..<3 {
                            var qa = pa, qb = pb
                            let h = 1e-6
                            func nudge(_ p: Pose) -> Pose { v == 0 ? Pose(angle: p.angle + h, t: p.t) : v == 1 ? Pose(angle: p.angle, t: Vec2(p.t.x + h, p.t.y)) : Pose(angle: p.angle, t: Vec2(p.t.x, p.t.y + h)) }
                            if isA { qa = nudge(pa) } else { qb = nudge(pb) }
                            let r1 = residual(c, qa, qb, arm: arm)
                            cols.append((k * 3 + v, zip(r1, r0).map { ($0 - $1) / h }))
                        }
                    }
                    for (ci, cj) in cols.enumerated() {
                        for r in 0..<3 { jtr[cj.0] -= cj.1[r] * r0[r] }
                        for (cj2) in cols[0...ci] { for r in 0..<3 { jtj[cj.0 * m + cj2.0] += cj.1[r] * cj2.1[r]; if cj.0 != cj2.0 { jtj[cj2.0 * m + cj.0] += cj.1[r] * cj2.1[r] } } }
                    }
                }
                if manhattan.count == scans, let ma = manhattan[anchor] {
                    for (scan, k) in idx {
                        guard let ms = manhattan[scan] else { continue }
                        // residual: the scan's wall direction against the anchor's, modulo a quarter turn; derivative 1 in the angle
                        let r = quarterWrap(poses[scan]!.angle + ms - (poses[anchor]!.angle + ma)) * arm
                        jtj[(k * 3) * m + k * 3] += arm * arm
                        jtr[k * 3] -= arm * r
                    }
                }
                for i in 0..<m { jtj[i * m + i] += 1e-9 }
                guard let dx = Linalg.choleskySolve(jtj, jtr, n: m) else { break }
                var step = 0.0
                for (scan, k) in idx {
                    var p = poses[scan]!
                    p.angle += dx[k * 3]; p.t.x += dx[k * 3 + 1]; p.t.y += dx[k * 3 + 2]
                    poses[scan] = p
                    step = max(step, abs(dx[k * 3]), abs(dx[k * 3 + 1]), abs(dx[k * 3 + 2]))
                }
                if step < 1e-9 { break }
            }
        }
        var fits: [ConnectionFit] = []
        for (i, c) in connections.enumerated() {
            guard let pa = poses[c.a.scan], let pb = poses[c.b.scan] else { fits.append(ConnectionFit(residual: 0, treeResidual: 0, angleError: 0, inTree: false)); continue }
            let r = residual(c, pa, pb, arm: arm)
            fits.append(ConnectionFit(residual: hypot(r[0], r[1]), treeResidual: treeResiduals[i].0, angleError: r[2] / arm, inTree: inTree[i]))
        }
        return LayoutResult(poses: poses, unplaced: (0..<scans).filter { poses[$0] == nil }, connections: fits)
    }
}
