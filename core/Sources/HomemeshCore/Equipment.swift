import Foundation

// Equipment and client profiles as data (a port of homemesh/equipment.py). The generic catalogue is invented round numbers that stand for a
// class of device, not claims about any product.

public enum Standard: String, Codable, Sendable, Hashable { case n, ac, ax
    var rank: Int { switch self { case .n: 0; case .ac: 1; case .ax: 2 } }
}

public struct Radio: Codable, Sendable, Hashable {
    public var band: Band
    public var chains: Int
    public var max_width: Int
    public var tx_dbm: Double
    public var ant_gain_dbi: Double
    public var standard: Standard
    public var dedicated_backhaul = false
    public var assumed = true
    public init(band: Band, chains: Int, max_width: Int, tx_dbm: Double, ant_gain_dbi: Double, standard: Standard, dedicated_backhaul: Bool = false, assumed: Bool = true) {
        self.band = band; self.chains = chains; self.max_width = max_width; self.tx_dbm = tx_dbm; self.ant_gain_dbi = ant_gain_dbi
        self.standard = standard; self.dedicated_backhaul = dedicated_backhaul; self.assumed = assumed
    }
}

public struct Port: Codable, Sendable, Hashable {
    public var rate: Double
    public init(rate: Double) { self.rate = rate }
}

public struct Equipment: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: String                     // router, mesh_node, extender
    public var system = ""
    public var radios: [Radio]
    public var ports: [Port] = []
    public var poe_in = false
    public var max_nodes: Int?
    public var max_hops: Int?
    public var wired_backhaul = true
    public var price = 0.0
    public var notes = ""
    public var sources: [String] = []

    public init(id: String, name: String, kind: String, system: String = "", radios: [Radio], ports: [Port] = [], poe_in: Bool = false, max_nodes: Int? = nil, max_hops: Int? = nil,
                wired_backhaul: Bool = true, price: Double = 0, notes: String = "", sources: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.system = system; self.radios = radios; self.ports = ports; self.poe_in = poe_in
        self.max_nodes = max_nodes; self.max_hops = max_hops; self.wired_backhaul = wired_backhaul; self.price = price; self.notes = notes; self.sources = sources
    }

    public func radio(_ band: Band) -> Radio? { radios.first { $0.band == band && !$0.dedicated_backhaul } }

    /// Radios usable for a wireless uplink: dedicated ones first, then the higher band.
    public func backhaulRadios() -> [Radio] {
        func rank(_ b: Band) -> Int { switch b { case .b24: 0; case .b5: 1; case .b6: 2 } }
        return radios.enumerated().sorted { l, r in
            let lk = (!l.element.dedicated_backhaul ? 1 : 0, -rank(l.element.band)), rk = (!r.element.dedicated_backhaul ? 1 : 0, -rank(r.element.band))
            if lk != rk { return lk < rk }
            return l.offset < r.offset
        }.map(\.element)
    }

    public var portRate: Double { ports.map(\.rate).max() ?? 0 }
}

public struct ClientRadio: Codable, Sendable, Hashable {
    public var chains: Int
    public var max_width: Int
    public var standard: Standard
    public var ant_gain_dbi = 0.0
    public init(chains: Int, max_width: Int, standard: Standard, ant_gain_dbi: Double = 0) { self.chains = chains; self.max_width = max_width; self.standard = standard; self.ant_gain_dbi = ant_gain_dbi }
}

public struct Client: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var radios: [String: ClientRadio]    // keyed by band ("2.4", "5", "6")
    public var noise_figure_db = 7.0
    public var sources: [String] = []
    public init(id: String, name: String, radios: [String: ClientRadio], noise_figure_db: Double = 7, sources: [String] = []) { self.id = id; self.name = name; self.radios = radios; self.noise_figure_db = noise_figure_db; self.sources = sources }
    public func radio(_ b: Band) -> ClientRadio? { radios[b.rawValue] }
}

public enum Catalogue {
    /// In the order the Python catalogue lists them.
    public static func genericList() -> [Equipment] {
        func ax(_ band: Band, _ w: Int, _ tx: Double, _ g: Double, dedicated: Bool = false) -> Radio { Radio(band: band, chains: 2, max_width: w, tx_dbm: tx, ant_gain_dbi: g, standard: .ax, dedicated_backhaul: dedicated) }
        let items = [
            Equipment(id: "generic-router-ax", name: "Generic dual-band AX router", kind: "router", radios: [ax(.b24, 20, 20, 3), ax(.b5, 80, 23, 4)],
                      ports: Array(repeating: Port(rate: 1000), count: 4), price: 120, notes: "Invented round numbers for a class of device."),
            Equipment(id: "generic-mesh-ax", name: "Generic dual-band AX mesh node", kind: "mesh_node", system: "generic", radios: [ax(.b24, 20, 20, 3), ax(.b5, 80, 23, 4)],
                      ports: Array(repeating: Port(rate: 1000), count: 2), max_nodes: 6, max_hops: 3, price: 100, notes: "Backhaul shares the 5 GHz radio with clients."),
            Equipment(id: "generic-mesh-tri", name: "Generic tri-band AX mesh node", kind: "mesh_node", system: "generic-tri",
                      radios: [ax(.b24, 20, 20, 3), ax(.b5, 80, 23, 4), ax(.b5, 80, 23, 4, dedicated: true)], ports: [Port(rate: 2500), Port(rate: 1000)], max_nodes: 5, max_hops: 3, price: 180,
                      notes: "A dedicated 5 GHz radio carries the node-to-node link."),
        ]
        return items
    }

    public static func generic() -> [String: Equipment] { Dictionary(genericList().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    public static func genericClientList() -> [Client] {
        let items = [
            Client(id: "phone-2x2-ax", name: "Generic 2x2 AX phone", radios: ["2.4": ClientRadio(chains: 2, max_width: 20, standard: .ax), "5": ClientRadio(chains: 2, max_width: 80, standard: .ax)]),
            Client(id: "laptop-1x1-ac", name: "Generic 1x1 AC laptop", radios: ["2.4": ClientRadio(chains: 1, max_width: 20, standard: .n), "5": ClientRadio(chains: 1, max_width: 80, standard: .ac)]),
        ]
        return items
    }

    public static func genericClients() -> [String: Client] { Dictionary(genericClientList().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
}
