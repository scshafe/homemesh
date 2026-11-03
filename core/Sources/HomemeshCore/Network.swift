import Foundation

// Backhaul and client-rate evaluation of one arrangement (a port of homemesh/network.py; design sections 4 and 5.2).
// An arrangement is a gateway (at the internet entry) plus extra nodes. Each extra node reaches the gateway over a wired link (a live jack
// whose switch chain reaches the entry) or a wireless hop to another node. Each cell then gets the best client rate over the nodes,
// limited by that node's end-to-end backhaul. Single client, idle network, downlink; no interference.

public enum Net {
    public static let bandWidthCap: [Band: Int] = [.b24: 20, .b5: 80, .b6: 80]
    public static let jackRate: [String: Double] = ["cat5e": 1000, "cat6": 2500, "cat6a": 5000, "coax_moca": 1000]
    public static let carrierSenseLossDb = 100.0
}

public struct NodePlacement: Hashable, Sendable {
    public var equipment: String
    public var position: Vec2
    public var level: String
    public var height = 1.5
    public init(equipment: String, position: Vec2, level: String, height: Double = 1.5) { self.equipment = equipment; self.position = position; self.level = level; self.height = height }
}

public struct Policy: Sendable, Hashable {
    public var floor_mbps = 25.0
    public var margin_db = 6.0
    public var mac_eff = Rates.macEfficiency
    public var trust_unknown_jacks = false
    public var must_fraction = 0.9
    public init(floor_mbps: Double = 25, margin_db: Double = 6, mac_eff: Double = Rates.macEfficiency, trust_unknown_jacks: Bool = false, must_fraction: Double = 0.9) {
        self.floor_mbps = floor_mbps; self.margin_db = margin_db; self.mac_eff = mac_eff; self.trust_unknown_jacks = trust_unknown_jacks; self.must_fraction = must_fraction
    }
}

public struct NodeResult: Sendable {
    public var index: Int
    public var kind: String                    // gateway, wired, wireless, disconnected
    public var parent: Int?
    public var backhaul_mbps = 0.0
    public var hops = 0
    public var jack: String?
    public var link_band: Band?
    public var shared_radio = false
}

public struct Evaluation: @unchecked Sendable {
    public var problems: [String]
    public var nodes: [NodeResult]
    public var rate: [Double]
    public var serving: [Int]
    public var limitedBy: [Int8]               // 0 access, 1 backhaul
    public var cost: Double
    public var jacksUsed: [String]
    public var jacksUnverified: [String]
    public var valid: Bool { problems.isEmpty }
}

public struct ZoneScore: Sendable {
    public var zone: String
    public var utility: Double
    public var utility_margin: Double
    public var mean_rate: Double
    public var frac_target: Double
    public var must_met: Bool?
}

/// House + catalogue + client, with the receiver grid and cached loss maps. A class: its caches fill as the search runs.
public final class PlanContext: @unchecked Sendable {
    public let house: House
    public let catalogue: [String: Equipment]
    public let client: Client
    public let model: PropagationModel
    public let params: PropParams
    public let grids: [Grid]
    public let cells: [Vec3]
    public let cellLevel: [Int]
    public let cellOk: [Bool]
    let elevation: [String: Double]
    private let lock = NSLock()
    private var lossCache: [LossKey: [Double]] = [:]
    private var pairCache: [PairKey: Double] = [:]
    private var accessCache: [AccessKey: [Double]] = [:]
    private var zoneCache: [String: [Bool]] = [:]

    struct LossKey: Hashable { var pos: Vec2; var level: String; var height: Double; var band: Band }
    struct PairKey: Hashable { var a: LossKey; var b: LossKey }
    struct AccessKey: Hashable { var pl: NodePlacement; var band: Band; var tx: Double; var gain: Double; var chains: Int; var width: Int; var std: Standard; var margin: Double; var mac: Double }

    public init(house: House, catalogue: [String: Equipment], client: Client, params: PropParams = PropParams(), step: Double = 0.5, rxHeight: Double = 1.0) throws {
        self.house = house; self.catalogue = catalogue; self.client = client; self.params = params
        model = PropagationModel(house)
        elevation = Dictionary(house.levels.map { ($0.id, $0.elevation) }, uniquingKeysWith: { a, _ in a })
        var gs: [Grid] = [], pts: [Vec3] = [], lv: [Int] = [], ok: [Bool] = []
        for l in house.levels where house.walls.contains(where: { $0.level == l.id }) {
            let g = try PlanContext.levelGrid(house, l.id, step: step, rxHeight: rxHeight, elevation: l.elevation)
            let gi = gs.count
            gs.append(g)
            let p = g.points()
            pts += p.map { Vec3($0.x, $0.y, g.z) }
            lv += [Int](repeating: gi, count: p.count)
            ok += model.gridMask(g)
        }
        grids = gs; cells = pts; cellLevel = lv; cellOk = ok
    }

    static func levelGrid(_ house: House, _ level: String, step: Double, rxHeight: Double, elevation: Double) throws -> Grid {
        let ws = house.walls.filter { $0.level == level }
        let xs = ws.flatMap { [$0.a.x, $0.b.x] }, ys = ws.flatMap { [$0.a.y, $0.b.y] }
        guard let x0 = xs.min(), let y0 = ys.min() else { throw ImportError("level \(level) has no walls to bound a grid") }
        let nx = max(1, Int(((xs.max()! - x0) / step).rounded(.up))), ny = max(1, Int(((ys.max()! - y0) / step).rounded(.up)))
        return Grid(level: level, x0: x0, y0: y0, step: step, nx: nx, ny: ny, z: elevation + rxHeight)
    }

    func abs(_ pl: NodePlacement) -> Vec3 { Vec3(pl.position.x, pl.position.y, (elevation[pl.level] ?? 0) + pl.height) }
    func key(_ pl: NodePlacement, _ band: Band) -> LossKey { LossKey(pos: pl.position, level: pl.level, height: pl.height, band: band) }

    func lossToCells(_ pl: NodePlacement, _ band: Band) -> [Double] {
        let k = key(pl, band)
        lock.lock(); if let v = lossCache[k] { lock.unlock(); return v }; lock.unlock()
        let v = model.pathLoss(tx: abs(pl), rx: cells, band: band, params: params)
        lock.lock(); lossCache[k] = v; lock.unlock()
        return v
    }

    func pairLoss(_ a: NodePlacement, _ b: NodePlacement, _ band: Band) -> Double {
        let k = PairKey(a: key(a, band), b: key(b, band)), k2 = PairKey(a: key(b, band), b: key(a, band))
        lock.lock(); if let v = pairCache[k] { lock.unlock(); return v }; lock.unlock()
        let v = model.pathLoss(tx: abs(a), rx: [abs(b)], band: band, params: params)[0]
        lock.lock(); pairCache[k] = v; pairCache[k2] = v; lock.unlock()
        return v
    }

    func zoneMask(_ zone: Zone) -> [Bool] {
        lock.lock(); if let v = zoneCache[zone.id] { lock.unlock(); return v }; lock.unlock()
        var m = [Bool](repeating: false, count: cells.count)
        if let lvi = grids.firstIndex(where: { $0.level == zone.level }) {
            for i in 0..<cells.count where cellLevel[i] == lvi {
                m[i] = zone.polygon.count >= 3 ? PropagationModel.inPolygon(cells[i].x, cells[i].y, zone.polygon)
                                               : hypot(cells[i].x - zone.polygon[0].x, cells[i].y - zone.polygon[0].y) <= 0.75
            }
        }
        lock.lock(); zoneCache[zone.id] = m; lock.unlock()
        return m
    }

    func accessRate(_ pl: NodePlacement, _ radio: Radio, _ policy: Policy, _ margin: Double) -> [Double] {
        guard let cr = client.radio(radio.band) else { return [Double](repeating: 0, count: cells.count) }
        let width = min(radio.max_width, cr.max_width, Net.bandWidthCap[radio.band]!)
        let k = AccessKey(pl: pl, band: radio.band, tx: radio.tx_dbm, gain: radio.ant_gain_dbi, chains: radio.chains, width: width, std: radio.standard, margin: margin, mac: policy.mac_eff)
        lock.lock(); if let v = accessCache[k] { lock.unlock(); return v }; lock.unlock()
        let loss = lossToCells(pl, radio.band)
        let table = Rates.table(min(radio.standard, cr.standard), width: width, streams: min(radio.chains, cr.chains), macEff: policy.mac_eff)
        let noise = Rates.noiseFloorDbm(width: width, noiseFigure: client.noise_figure_db)
        var out = [Double](repeating: 0, count: cells.count)
        let eirp = radio.tx_dbm + radio.ant_gain_dbi + cr.ant_gain_dbi
        for i in 0..<cells.count where cellOk[i] { out[i] = table.throughput(eirp - (loss[i] + margin) - noise) }
        lock.lock(); accessCache[k] = out; lock.unlock()
        return out
    }
}

extension Standard: Comparable { public static func < (a: Standard, b: Standard) -> Bool { a.rank < b.rank } }

extension Rates {
    nonisolated(unsafe) static var tables: [String: Table] = [:]
    static let tableLock = NSLock()
    /// Tables are cheap to build but built thousands of times in a search: keep one per link shape.
    public static func table(_ std: WifiStandard, width: Int, streams: Int, macEff: Double) -> Table {
        let k = "\(std.rawValue)/\(width)/\(streams)/\(macEff)"
        tableLock.lock(); defer { tableLock.unlock() }
        if let t = tables[k] { return t }
        let t = Table(std, width: width, streams: streams, macEff: macEff)
        tables[k] = t
        return t
    }
    static func table(_ std: Standard, width: Int, streams: Int, macEff: Double) -> Table { table(WifiStandard(rawValue: std.rawValue)!, width: width, streams: streams, macEff: macEff) }
}

public enum Backhaul {
    static func jackRate(_ j: Jack) -> Double { j.measured_rate ?? Net.jackRate[j.type] ?? 0 }

    /// (rate, jack id, verified) for a live jack at `pl` whose switch chain reaches the entry, else nil.
    static func wiredAt(_ house: House, _ pl: NodePlacement, trustUnknown: Bool, near: Double = 0.6) -> (Double, String, Bool)? {
        let usable: Set<String> = trustUnknown ? ["live", "unknown"] : ["live"]
        let jacks = Dictionary(house.jacks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let switches = Dictionary(house.switches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func chain(_ id: String?, _ seen: Set<String>) -> Double? {
            guard let id, !seen.contains(id), let s = switches[id] else { return nil }
            let rate = s.ports > 0 ? s.port_rate : s.port_rate
            if s.uplink == "entry" { return rate }
            if let up = s.uplink, switches[up] != nil { return chain(up, seen.union([id])).map { min($0, rate) } }
            if let up = s.uplink, let j = jacks[up], usable.contains(j.state) { return chain(j.switch, seen.union([id])).map { min($0, rate, jackRate(j)) } }
            return nil
        }
        var best: (Double, String, Bool)?
        for j in house.jacks where j.level == pl.level && usable.contains(j.state) {
            if hypot(j.position.x - pl.position.x, j.position.y - pl.position.y) > near { continue }
            guard let up = chain(j.switch, []) else { continue }
            let rate = min(jackRate(j), up)
            if best == nil || rate > best!.0 { best = (rate, j.id, j.state == "live") }
        }
        return best
    }

    struct Hop { var parent: NodePlacement, child: NodePlacement, rate: Double, band: Band }

    /// Best wireless link between two placed nodes: (rate, band, shared radio) or nil.
    static func linkRate(_ ctx: PlanContext, _ parent: NodePlacement, _ child: NodePlacement, _ policy: Policy, margin: Double = 0) -> (Double, Band, Bool)? {
        let pe = ctx.catalogue[parent.equipment]!, ce = ctx.catalogue[child.equipment]!
        var best: (Double, Band, Bool)?
        for cr in ce.backhaulRadios() {
            let cands = pe.radios.filter { $0.band == cr.band && ($0.dedicated_backhaul || !cr.dedicated_backhaul) }
            for pr in cands {
                if cr.dedicated_backhaul && !pr.dedicated_backhaul { continue }
                let loss = ctx.pairLoss(parent, child, cr.band) + margin
                let width = min(pr.max_width, cr.max_width, Net.bandWidthCap[cr.band]!)
                let down = pr.tx_dbm + pr.ant_gain_dbi + cr.ant_gain_dbi - loss
                let up = cr.tx_dbm + cr.ant_gain_dbi + pr.ant_gain_dbi - loss
                let snr = min(down, up) - Rates.noiseFloorDbm(width: width, noiseFigure: 7)
                let std = min(pr.standard, cr.standard)
                let rate = Rates.table(std, width: width, streams: min(pr.chains, cr.chains), macEff: policy.mac_eff).throughput(snr)
                if rate > 0 && (best == nil || rate > best!.0) { best = (rate, cr.band, !cr.dedicated_backhaul) }
            }
        }
        return best
    }

    /// Rate of a chain of wireless hops with airtime sharing among hops that can hear each other on the same band.
    static func pathRate(_ ctx: PlanContext, _ hops: [Hop]) -> Double {
        if hops.isEmpty { return .infinity }
        var worst = Double.infinity
        for (i, h) in hops.enumerated() {
            var inv = 1 / h.rate
            for (j, g) in hops.enumerated() where j != i && g.band == h.band {
                let shares = [h.parent, h.child].contains(g.parent) || [h.parent, h.child].contains(g.child)
                    || [h.parent, h.child].flatMap { x in [g.parent, g.child].map { ctx.pairLoss(x, $0, h.band) } }.min()! <= Net.carrierSenseLossDb
                if shares { inv += 1 / g.rate }
            }
            worst = min(worst, 1 / inv)
        }
        return worst
    }

    static func root(_ res: [NodeResult], _ n: Int) -> Int { var k = n; while res[k].kind == "wireless" { k = res[k].parent! }; return k }
    static func rootRate(_ res: [NodeResult], _ n: Int, _ wan: Double) -> Double { let r = root(res, n); return res[r].kind == "wired" ? min(wan, res[r].backhaul_mbps) : wan }

    /// Resolves backhaul and per-cell client rate. `margin` dB is added to every path loss (the robust run).
    public static func evaluate(_ ctx: PlanContext, gateway: NodePlacement, extras: [NodePlacement], policy: Policy = Policy(), margin: Double = 0) -> Evaluation {
        let house = ctx.house, cat = ctx.catalogue
        let nodes = [gateway] + extras
        var problems: [String] = []
        let cost = nodes.map { cat[$0.equipment]!.price }.reduce(0, +)
        let wan = house.entry?.wan_down ?? .infinity
        let gwPort = cat[gateway.equipment]!.portRate == 0 ? Double.infinity : cat[gateway.equipment]!.portRate
        let systems = Set(nodes.dropFirst().compactMap { cat[$0.equipment]!.system.isEmpty ? nil : cat[$0.equipment]!.system })
        for p in nodes.dropFirst() {
            let e = cat[p.equipment]!
            if let m = e.max_nodes, nodes.count > m { problems.append("\(e.name): system allows at most \(m) nodes") }
        }
        if systems.count > 1 { problems.append("nodes from different mesh systems") }

        var res = [NodeResult(index: 0, kind: "gateway", parent: nil, backhaul_mbps: wan, hops: 0)]
        var paths: [Int: [Hop]] = [0: []]
        var done: Set<Int> = [0]
        var used: [String] = [], unverified: [String] = []
        for (i0, pl) in extras.enumerated() {
            let i = i0 + 1
            res.append(NodeResult(index: i, kind: "disconnected"))
            let e = cat[pl.equipment]!
            if e.wired_backhaul, let (rate, jid, verified) = wiredAt(house, pl, trustUnknown: policy.trust_unknown_jacks) {
                res[i] = NodeResult(index: i, kind: "wired", parent: nil, backhaul_mbps: min(rate, e.portRate == 0 ? rate : e.portRate, gwPort, wan), hops: 0, jack: jid)
                paths[i] = []
                done.insert(i)
                used.append(jid)
                if !verified { unverified.append(jid) }
            }
        }
        var remaining = Set(1..<max(nodes.count, 1)).subtracting(done)
        while !remaining.isEmpty {
            var best: (rate: Double, n: Int, m: Int, band: Band, shared: Bool, hops: [Hop])?
            for n in remaining.sorted() {
                for m in done.sorted() {
                    if paths[m]!.count + 1 > (cat[nodes[n].equipment]!.max_hops ?? 99) { continue }
                    guard let lk = linkRate(ctx, nodes[m], nodes[n], policy, margin: margin) else { continue }
                    let hops = paths[m]! + [Hop(parent: nodes[m], child: nodes[n], rate: lk.0, band: lk.1)]
                    let r = min(pathRate(ctx, hops), rootRate(res, m, wan))
                    if best == nil || r > best!.rate { best = (r, n, m, lk.1, lk.2, hops) }
                }
            }
            guard let b = best else { break }
            res[b.n] = NodeResult(index: b.n, kind: "wireless", parent: b.m, backhaul_mbps: b.rate, hops: b.hops.count, jack: nil, link_band: b.band, shared_radio: b.shared)
            paths[b.n] = b.hops
            done.insert(b.n)
            remaining.remove(b.n)
        }
        for n in remaining.sorted() { problems.append("node \(n) cannot reach the gateway") }

        let ncell = ctx.cells.count
        var rate = [Double](repeating: 0, count: ncell), serving = [Int](repeating: -1, count: ncell), limited = [Int8](repeating: 0, count: ncell)
        for (i, pl) in nodes.enumerated() {
            let nr = res[i]
            if nr.kind == "disconnected" { continue }
            var bh = i > 0 ? nr.backhaul_mbps : min(wan, gwPort)
            if i > 0 && nr.kind == "wired" { bh = nr.backhaul_mbps }
            let e = cat[pl.equipment]!
            var nodeBest = [Double](repeating: 0, count: ncell), nodeLim = [Int8](repeating: 0, count: ncell)
            for radio in e.radios where !radio.dedicated_backhaul {
                let acc = ctx.accessRate(pl, radio, policy, margin)
                let shared = nr.kind == "wireless" && nr.shared_radio && nr.link_band == radio.band
                for c in 0..<ncell {
                    let eff = shared ? (acc[c] > 0 ? 1 / (1 / max(acc[c], 1e-9) + 1 / bh) : 0) : min(acc[c], bh)
                    if eff > nodeBest[c] { nodeBest[c] = eff; nodeLim[c] = bh < acc[c] ? 1 : 0 }
                }
            }
            for c in 0..<ncell where nodeBest[c] > rate[c] { rate[c] = nodeBest[c]; serving[c] = i; limited[c] = nodeLim[c] }
        }
        return Evaluation(problems: problems, nodes: res, rate: rate, serving: serving, limitedBy: limited, cost: cost, jacksUsed: used, jacksUnverified: unverified)
    }

    public static func zoneScores(_ ctx: PlanContext, _ ev: Evaluation, _ evMargin: Evaluation, _ policy: Policy = Policy()) -> [ZoneScore] {
        var out: [ZoneScore] = []
        for z in ctx.house.zones where z.kind == "demand" {
            guard let need = z.need else { continue }
            let mask = ctx.zoneMask(z)
            let idx = (0..<ctx.cells.count).filter { mask[$0] && ctx.cellOk[$0] }
            if idx.isEmpty { out.append(ZoneScore(zone: z.id, utility: 0, utility_margin: 0, mean_rate: 0, frac_target: 0, must_met: need.must ? false : nil)); continue }
            let target = need.min_throughput ?? policy.floor_mbps
            let floor = min(policy.floor_mbps, target * 0.999)
            func util(_ r: [Double]) -> Double { idx.map { min(1, max(0, (r[$0] - floor) / (target - floor))) }.reduce(0, +) / Double(idx.count) }
            let frac = Double(idx.filter { evMargin.rate[$0] >= target }.count) / Double(idx.count)
            out.append(ZoneScore(zone: z.id, utility: util(ev.rate), utility_margin: util(evMargin.rate), mean_rate: idx.map { ev.rate[$0] }.reduce(0, +) / Double(idx.count),
                                 frac_target: frac, must_met: need.must ? frac >= policy.must_fraction : nil))
        }
        return out
    }
}
