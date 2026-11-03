import Foundation

// The house document (docs/design.md section 2), as the Python model writes it: snake_case keys, metres, dB.
// P0 carries the parts the propagation needs; P1 completes the model (rooms, zones, equipment, furniture, ...).

public enum Band: String, CaseIterable, Sendable, Codable, Hashable {
    case b24 = "2.4", b5 = "5", b6 = "6"
    public var mhz: Double {
        switch self { case .b24: 2437; case .b5: 5500; case .b6: 6200 }
    }
}

public struct Material: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var loss: [String: Double]            // dB at ref_thickness, per band
    public var ref_thickness: Double
    public var prior_sd: Double
    public var source: String
    public func loss(_ band: Band) -> Double { loss[band.rawValue] ?? 0 }
}

public struct Slab: Codable, Sendable, Hashable {
    public var material: String
    public var thickness: Double
}

public struct Level: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var elevation: Double
    public var height: Double
    public var slab: Slab?
    public var height_source: String?
    public var below_ground: Bool?
}

public struct Opening: Codable, Sendable, Hashable {
    public var kind: String                      // door, window, arch, hole
    public var offset: Double
    public var width: Double
    public var height: Double
    public var sill: Double
    public var material: String
    public var state: String                     // open, closed
}

public struct Wall: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var a: Vec2
    public var b: Vec2
    public var thickness: Double
    public var height: Double
    public var base_z: Double
    public var material: String
    public var openings: [Opening]
    public var length: Double { (b - a).length }
}

public struct SlabHole: Codable, Sendable, Hashable {
    public var id: String
    public var level: String
    public var polygon: [Vec2]
}

public struct Stair: Codable, Sendable, Hashable {
    public var id: String
    public var from_level: String
    public var to_level: String
    public var polygon: [Vec2]
    public var void: Bool
}

public struct House: Codable, Sendable {
    public var id: String
    public var name: String
    public var levels: [Level]
    public var materials: [Material]
    public var walls: [Wall]
    public var slab_holes: [SlabHole]
    public var stairs: [Stair]

    public static func load(_ data: Data) throws -> House { try JSONDecoder().decode(House.self, from: data) }
}
