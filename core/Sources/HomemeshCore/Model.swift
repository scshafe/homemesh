import Foundation

// The house document (docs/design.md section 2), as the Python model writes it: snake_case keys, metres, dB, one frame for all levels.
// Types decode strictly and encode every field, so a document the app writes is complete; properties that have a default can be
// left out when building one in code. Optionals that are nil are omitted when encoding. Blueprints (`underlays`) are not part of the
// standalone app (design section 13, Q6): a document that has them decodes, and they are not kept.

public typealias Prov = Provenance

public struct Provenance: Codable, Sendable, Hashable {
    public var source: String = "manual"          // scan, blueprint, photo, manual
    public var ref: String?
    public var confidence: Double = 1
    public var edited: Bool = false
    public var at: String?                        // ISO 8601 text, kept as written
    public init(source: String = "manual", ref: String? = nil, confidence: Double = 1, edited: Bool = false, at: String? = nil) {
        self.source = source; self.ref = ref; self.confidence = confidence; self.edited = edited; self.at = at
    }
    public static let manual = Provenance()
}

public enum Band: String, CaseIterable, Sendable, Codable, Hashable {
    case b24 = "2.4", b5 = "5", b6 = "6"
    public var mhz: Double {
        switch self { case .b24: 2437; case .b5: 5500; case .b6: 6200 }
    }
}

public struct Material: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var loss: [String: Double]              // dB at ref_thickness, per band
    public var ref_thickness: Double
    public var prior_sd: Double = 2
    public var source: String = "unsourced"
    public func loss(_ band: Band) -> Double { loss[band.rawValue] ?? 0 }
    public init(id: String, name: String, loss: [String: Double], ref_thickness: Double, prior_sd: Double = 2, source: String = "unsourced") {
        self.id = id; self.name = name; self.loss = loss; self.ref_thickness = ref_thickness; self.prior_sd = prior_sd; self.source = source
    }
}

public struct Slab: Codable, Sendable, Hashable {
    public var material: String
    public var thickness: Double
    public init(material: String, thickness: Double) { self.material = material; self.thickness = thickness }
}

public struct Level: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var elevation: Double                   // Z of the top of the finished floor
    public var height: Double                      // floor to ceiling
    public var slab: Slab?
    public var height_source: String = "default"   // default, walls, stair
    public var below_ground: Bool = false
    public init(id: String, name: String, elevation: Double, height: Double, slab: Slab? = nil, height_source: String = "default", below_ground: Bool = false) {
        self.id = id; self.name = name; self.elevation = elevation; self.height = height; self.slab = slab; self.height_source = height_source; self.below_ground = below_ground
    }
}

public struct Opening: Codable, Sendable, Hashable {
    public var kind: String                        // door, window, arch, hole
    public var offset: Double                      // from wall endpoint a, along the wall
    public var width: Double
    public var height: Double
    public var sill: Double = 0
    public var material: String
    public var state: String = "closed"            // open, closed
    public var prov: Provenance = .manual
    public init(kind: String, offset: Double, width: Double, height: Double, sill: Double = 0, material: String, state: String = "closed", prov: Provenance = .manual) {
        self.kind = kind; self.offset = offset; self.width = width; self.height = height; self.sill = sill; self.material = material; self.state = state; self.prov = prov
    }
}

public struct WallCurve: Codable, Sendable, Hashable {
    public var group: String
    public var cx: Double, cy: Double, radius: Double, a0: Double, a1: Double
}

public struct Wall: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var a: Vec2
    public var b: Vec2
    public var thickness: Double
    public var height: Double
    public var base_z: Double = 0
    public var material: String
    public var thickness_defaulted: Bool = false
    public var material_defaulted: Bool = false
    public var profile: [Vec2]?                    // (offset along a to b, height above base_z) points
    public var curve: WallCurve?
    public var openings: [Opening] = []
    public var prov: Provenance = .manual
    public var length: Double { (b - a).length }
    public init(id: String, level: String, a: Vec2, b: Vec2, thickness: Double, height: Double, base_z: Double = 0, material: String, openings: [Opening] = [], prov: Provenance = .manual) {
        self.id = id; self.level = level; self.a = a; self.b = b; self.thickness = thickness; self.height = height; self.base_z = base_z
        self.material = material; self.openings = openings; self.prov = prov
    }
}

public struct Room: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var name: String
    public var description: String = ""
    public var polygon: [Vec2]
    public var kind: String = "room"
    public var prov: Provenance = .manual
    public init(id: String, level: String, name: String, description: String = "", polygon: [Vec2], kind: String = "room", prov: Provenance = .manual) {
        self.id = id; self.level = level; self.name = name; self.description = description; self.polygon = polygon; self.kind = kind; self.prov = prov
    }
}

public struct SlabHole: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var polygon: [Vec2]
    public var prov: Provenance = .manual
    public init(id: String, level: String, polygon: [Vec2], prov: Provenance = .manual) { self.id = id; self.level = level; self.polygon = polygon; self.prov = prov }
}

public struct Furniture: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var room: String?
    public var category: String
    public var name: String = ""
    public var center: Vec2
    public var width: Double
    public var depth: Double
    public var height: Double
    public var base_z: Double = 0
    public var rotation: Double = 0
    public var attributes: [String: String] = [:]
    public var movable: Bool = true
    public var movable_default: Bool = true
    public var obstacle: Bool = false
    public var prov: Provenance = .manual
}

public struct Stair: Codable, Sendable, Hashable {
    public var id: String
    public var from_level: String
    public var to_level: String
    public var polygon: [Vec2]
    public var void: Bool = true
    public var steps: Int?
    public var low: Vec2?
    public var prov: Provenance = .manual
    public init(id: String, from_level: String, to_level: String, polygon: [Vec2], void: Bool = true, steps: Int? = nil, low: Vec2? = nil, prov: Provenance = .manual) {
        self.id = id; self.from_level = from_level; self.to_level = to_level; self.polygon = polygon; self.void = void; self.steps = steps; self.low = low; self.prov = prov
    }
}

public struct Entry: Codable, Sendable, Hashable {
    public var position: Vec2
    public var level: String
    public var kind: String = "modem"              // modem, ont, coax_drop
    public var wan_down: Double?
    public var wan_up: Double?
    public var leads_to: String?
    public var prov: Provenance = .manual
}

public struct Switch: Codable, Sendable, Hashable {
    public var id: String
    public var position: Vec2
    public var level: String
    public var ports: Int = 8
    public var port_rate: Double = 1000
    public var uplink: String?                     // a Jack id, a Switch id, or "entry"
    public var prov: Provenance = .manual
}

public struct Jack: Codable, Sendable, Hashable {
    public var id: String
    public var position: Vec2
    public var level: String
    public var z: Double = 0.3
    public var wall: String?
    public var type: String                        // cat5e, cat6, cat6a, coax_moca
    public var state: String = "unknown"           // live, dead, unknown
    public var leads_to: String = "unknown"
    public var `switch`: String?
    public var poe: Bool = false
    public var run_length: Double?
    public var measured_rate: Double?
    public var prov: Provenance = .manual
}

public struct Outlet: Codable, Sendable, Hashable {
    public var id: String
    public var position: Vec2
    public var level: String
    public var z: Double = 0.3
    public var circuit: String?
    public var prov: Provenance = .manual
}

public struct Need: Codable, Sendable, Hashable {
    public var min_rssi: Double?
    public var min_throughput: Double?
    public var max_latency: Double?
    public var band_pref: String?
    public var must: Bool = false
    public var rx_height: Double = 1
}

public struct Zone: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var polygon: [Vec2]                     // one point = a single spot
    public var kind: String                        // allow, forbid, demand
    public var name: String = ""
    public var weight: Double = 1
    public var need: Need?
    public var requires: String = "none"           // outlet, poe, none
    public var mounts: [String] = []
    public var heights: [Double] = []
    public var prov: Provenance = .manual
}

public struct AccessPoint: Codable, Sendable, Hashable {
    public var id: String
    public var name: String = ""
    public var position: Vec2
    public var level: String
    public var height: Double = 1.5
    public var eirp_dbm: Double = 23
    public var bssids: [String] = []
    public var prov: Provenance = .manual
}

public struct Calibration: Codable, Sendable, Hashable {
    public var at: String?
    public var n: [String: Double] = [:]
    public var extra_loss_db: [String: Double] = [:]
    public var rmse_cv: [String: Double?] = [:]
    public var n_measurements: [String: Int] = [:]
}

public struct Measurement: Codable, Sendable, Hashable {
    public var id: String
    public var position: Vec2
    public var level: String
    public var device: String
    public var band: String
    public var bssid: String?
    public var rssi: Double?
    public var snr: Double?
    public var throughput: Double?
    public var at: String?
}

public struct PlacedNode: Codable, Sendable, Hashable {
    public var equipment: String
    public var position: Vec2
    public var level: String
    public var mount_height: Double = 1
    public var backhaul: String = "auto"           // auto, wired, wireless
    public var jack: String?
    public var parent: Int?
}

public struct Arrangement: Codable, Sendable, Hashable {
    public var id: String
    public var name: String = ""
    public var nodes: [PlacedNode]
}

public struct MeasureCheck: Codable, Sendable, Hashable {
    public var id: String
    public var what: String
    public var level: String?
    public var wall: String?
    public var scanned: Double
    public var measured: Double
    public var at: String = ""
}

public struct House: Codable, Sendable {
    public static let schemaVersion = 1
    public var schema_version: Int = House.schemaVersion
    public var id: String
    public var name: String
    public var synthetic: Bool = false
    public var jog_fold: Double = 0.3
    public var region: String = "US"
    public var revision: Int = 0
    public var levels: [Level]
    public var materials: [Material] = []
    public var walls: [Wall] = []
    public var rooms: [Room] = []
    public var slab_holes: [SlabHole] = []
    public var measure_checks: [MeasureCheck] = []
    public var stairs: [Stair] = []
    public var furniture: [Furniture] = []
    public var entry: Entry?
    public var switches: [Switch] = []
    public var jacks: [Jack] = []
    public var outlets: [Outlet] = []
    public var zones: [Zone] = []
    public var access_points: [AccessPoint] = []
    public var calibration: Calibration?
    public var measurements: [Measurement] = []
    public var arrangements: [Arrangement] = []

    public init(id: String, name: String, levels: [Level], materials: [Material] = [], walls: [Wall] = [], slab_holes: [SlabHole] = [], stairs: [Stair] = []) {
        self.id = id; self.name = name; self.levels = levels; self.materials = materials; self.walls = walls; self.slab_holes = slab_holes; self.stairs = stairs
    }

    public static func load(_ data: Data) throws -> House { try JSONDecoder().decode(House.self, from: data) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }
}
