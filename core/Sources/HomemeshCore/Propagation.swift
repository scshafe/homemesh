import Foundation

// Multi-wall-and-floor path loss (a port of homemesh/propagation.py; see docs/design.md section 3).
//   PL = PL0(f) + 10 n log10(d) + sum(wall losses) + sum(slab losses)
// Median only. The Python module is the oracle: the golden tests compare this port with its output.

public struct Vec3: Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
}

public struct PropParams: Sendable {
    public var n: [Band: Double] = [.b24: 2, .b5: 2, .b6: 2]
    public var extraLoss: [Band: Double] = [.b24: 0, .b5: 0, .b6: 0]
    public init() {}
    public init(n: [Band: Double], extraLoss: [Band: Double]) { self.n = n; self.extraLoss = extraLoss }
}

public struct Tx: Sendable {
    public var position: Vec2
    public var level: String
    public var height = 1.8
    public var power_dbm = 20.0
    public var gain_dbi = 3.0
    public init(position: Vec2, level: String, height: Double = 1.8, power_dbm: Double = 20, gain_dbi: Double = 3) {
        self.position = position; self.level = level; self.height = height; self.power_dbm = power_dbm; self.gain_dbi = gain_dbi
    }
}

public struct Grid: Sendable {
    public var level: String
    public var x0: Double, y0: Double, step: Double
    public var nx: Int, ny: Int
    public var z: Double

    /// Cell centres, row by row (y outer, x inner), as the Python grid lists them.
    public func points() -> [Vec2] {
        var out: [Vec2] = []
        out.reserveCapacity(nx * ny)
        for iy in 0..<ny { for ix in 0..<nx { out.append(Vec2(x0 + (Double(ix) + 0.5) * step, y0 + (Double(iy) + 0.5) * step)) } }
        return out
    }
}

/// A house prepared for repeated path-loss queries: material lookups and level elevations resolved once.
public struct PropagationModel: Sendable {
    public let house: House
    let materials: [String: Material]
    let elevation: [String: Double]
    let holes: [String: [[Vec2]]]            // per level: slab holes and open stairwells arriving there

    static let cosMaxIncidence = cos(70.0 * .pi / 180)
    static let eps = 1e-9

    public init(_ house: House) {
        self.house = house
        materials = Dictionary(house.materials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        elevation = Dictionary(house.levels.map { ($0.id, $0.elevation) }, uniquingKeysWith: { a, _ in a })
        var h: [String: [[Vec2]]] = [:]
        for s in house.slab_holes { h[s.level, default: []].append(s.polygon) }
        for s in house.stairs where s.void { h[s.to_level, default: []].append(s.polygon) }
        holes = h
    }

    public func freeSpace1m(_ band: Band) -> Double { 20 * log10(band.mhz) - 27.56 }

    private func loss(_ id: String, _ band: Band) -> Double { id == "air" ? 0 : (materials[id]?.loss(band) ?? 0) }
    private func ref(_ id: String) -> Double { id == "air" ? 1 : (materials[id]?.ref_thickness ?? 1) }

    static func inPolygon(_ x: Double, _ y: Double, _ poly: [Vec2]) -> Bool {
        var inside = false
        let n = poly.count
        for i in 0..<n {
            let p1 = poly[i], p2 = poly[(i + 1) % n]
            if p1.y == p2.y { continue }
            if ((p1.y > y) != (p2.y > y)) && (x < (p2.x - p1.x) * (y - p1.y) / (p2.y - p1.y) + p1.x) { inside.toggle() }
        }
        return inside
    }

    /// Total path loss in dB from the absolute point `tx` to every receiver in `rx`.
    public func pathLoss(tx: Vec3, rx: [Vec3], band: Band, params: PropParams = PropParams()) -> [Double] {
        let base = freeSpace1m(band) + (params.extraLoss[band] ?? 0)
        let n = params.n[band] ?? 2
        var out = [Double](repeating: 0, count: rx.count)
        for i in 0..<rx.count {
            let dx = rx[i].x - tx.x, dy = rx[i].y - tx.y, dz = rx[i].z - tx.z
            out[i] = base + 10 * n * log10(max((dx * dx + dy * dy + dz * dz).squareRoot(), 1))
        }
        walk(tx: tx, rx: rx, band: band, unit: false) { i, _, db, _, _ in out[i] += db }
        return out
    }

    /// Per material, how many reference-thickness units of it each segment tx-rx crosses: path loss is linear in the material
    /// losses, `loss = sum exposure_m * L_m`, and calibration regresses on this. The same geometry with every loss set to 1 dB.
    public func exposures(tx: Vec3, rx: [Vec3], band: Band) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        walk(tx: tx, rx: rx, band: band, unit: true) { i, material, db, _, _ in
            if out[material] == nil { out[material] = [Double](repeating: 0, count: rx.count) }
            out[material]![i] += db
        }
        return out
    }

    /// The largest-first list of (kind, element id, dB) for one transmitter/receiver pair: what costs signal between them.
    public func explainPoint(tx: Vec3, rx: Vec3, band: Band) -> [(kind: String, id: String, db: Double)] {
        var totals: [(kind: String, id: String, db: Double)] = []
        walk(tx: tx, rx: [rx], band: band, unit: false) { _, _, db, slab, id in
            let kind = slab ? "slab" : "wall"
            if let k = totals.firstIndex(where: { $0.kind == kind && $0.id == id }) { totals[k].db += db } else { totals.append((kind, id, db)) }
        }
        return totals.enumerated().sorted { $0.element.db != $1.element.db ? $0.element.db > $1.element.db : $0.offset < $1.offset }.map(\.element)
    }

    /// Every wall and slab the segment crosses, reported per receiver as (index, material, dB). `unit` charges 1 dB for every
    /// material (and nothing extra for an `air` one) so the amounts count units of material.
    func walk(tx: Vec3, rx: [Vec3], band: Band, unit: Bool, charge: (_ receiver: Int, _ material: String, _ db: Double, _ slab: Bool, _ element: String) -> Void) {
        func lossOf(_ id: String) -> Double { id == "air" ? 0 : (unit ? 1 : (materials[id]?.loss(band) ?? 0)) }
        for w in house.walls {
            let floor = elevation[w.level] ?? 0
            let zLo = floor + w.base_z, zHi = zLo + w.height
            let ex = w.b.x - w.a.x, ey = w.b.y - w.a.y
            let wlen = hypot(ex, ey)
            if wlen == 0 { continue }
            let px = w.a.x - tx.x, py = w.a.y - tx.y
            let wallDb = lossOf(w.material) / ref(w.material)
            let thick = w.thickness
            for i in 0..<rx.count {
                let dx = rx[i].x - tx.x, dy = rx[i].y - tx.y, dz = rx[i].z - tx.z
                let denom = dx * ey - dy * ex
                if abs(denom) <= Self.eps { continue }
                let s = (px * ey - py * ex) / denom
                if !(s > Self.eps && s < 1 - Self.eps) { continue }
                let u = (px * dy - py * dx) / denom
                if !(u >= 0 && u <= 1) { continue }
                let z = tx.z + s * dz
                if !(z >= zLo && z <= zHi) { continue }
                let dlen = hypot(dx, dy)
                var cosT = abs((dx * -ey + dy * ex) / ((dlen > 0 ? dlen : 1) * wlen))
                cosT = min(1, max(Self.cosMaxIncidence, cosT))
                let along = u * wlen, zrel = z - floor
                var through = true
                for o in w.openings where along >= o.offset && along <= o.offset + o.width && zrel >= o.sill && zrel <= o.sill + o.height {
                    through = false
                    let db = o.state == "open" ? 0 : lossOf(o.material)
                    if db != 0 { charge(i, o.material, db, false, w.id) }
                    break   // a point inside one opening is not charged for another
                }
                if through && wallDb != 0 { charge(i, w.material, wallDb * (thick / cosT), false, w.id) }
            }
        }
        for lv in house.levels {
            guard let slab = lv.slab else { continue }
            let zb = lv.elevation
            let db = lossOf(slab.material) * slab.thickness / ref(slab.material)
            if db == 0 { continue }
            let polys = holes[lv.id] ?? []
            for i in 0..<rx.count {
                if !((tx.z - zb) * (rx[i].z - zb) < 0) { continue }
                let dz = rx[i].z - tx.z
                let s = (zb - tx.z) / (dz != 0 ? dz : 1)
                let x = tx.x + s * (rx[i].x - tx.x), y = tx.y + s * (rx[i].y - tx.y)
                if polys.contains(where: { Self.inPolygon(x, y, $0) }) { continue }
                charge(i, slab.material, db, true, lv.id)
            }
        }
    }
}

extension PropagationModel {
    /// True where a receiver may sit: not inside a wall (the thickness band around its centre line).
    public func gridMask(_ grid: Grid) -> [Bool] {
        let pts = grid.points()
        var ok = [Bool](repeating: true, count: pts.count)
        for w in house.walls where w.level == grid.level {
            let ex = w.b.x - w.a.x, ey = w.b.y - w.a.y
            let ee = ex * ex + ey * ey
            let half = w.thickness / 2
            for i in 0..<pts.count where ok[i] {
                let rx = pts[i].x - w.a.x, ry = pts[i].y - w.a.y
                let t = ee > 0 ? min(1, max(0, (rx * ex + ry * ey) / ee)) : 0
                if hypot(rx - t * ex, ry - t * ey) < half { ok[i] = false }
            }
        }
        return ok
    }
}
