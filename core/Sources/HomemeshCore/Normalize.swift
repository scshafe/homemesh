import Foundation

// Documents that other code builds (the app's passthrough editor adds objects with only the fields it knows) leave out fields that have
// defaults. The strict Codable model wants every key, so a document is filled in first, as the Python model's defaults did.

public enum Normalize {
    static var prov: JObject { ["source": "manual", "confidence": 1.0, "edited": false] }

    static func fill(_ o: inout JObject, _ defaults: JObject) { for (k, v) in defaults where o[k] == nil { o[k] = v } }

    static func each(_ o: inout JObject, _ key: String, _ body: (inout JObject) -> Void) {
        guard var arr = o[key] as? [Any] else { return }
        for i in arr.indices { if var d = arr[i] as? JObject { body(&d); arr[i] = d } }
        o[key] = arr
    }

    public static func house(_ input: JObject) -> JObject {
        var h = input
        h["underlays"] = nil     // blueprints are not part of the standalone app
        fill(&h, ["schema_version": 1, "synthetic": false, "jog_fold": 0.3, "region": "US", "revision": 0, "materials": [Any](), "walls": [Any](), "rooms": [Any](),
                  "slab_holes": [Any](), "measure_checks": [Any](), "stairs": [Any](), "furniture": [Any](), "switches": [Any](), "jacks": [Any](), "outlets": [Any](),
                  "zones": [Any](), "access_points": [Any](), "measurements": [Any](), "arrangements": [Any]()])
        each(&h, "levels") { fill(&$0, ["height_source": "default", "below_ground": false]) }
        each(&h, "materials") { fill(&$0, ["prior_sd": 2.0, "source": "unsourced"]) }
        each(&h, "walls") { w in
            fill(&w, ["base_z": 0.0, "thickness_defaulted": false, "material_defaulted": false, "openings": [Any](), "prov": prov])
            each(&w, "openings") { fill(&$0, ["sill": 0.0, "state": "closed", "prov": prov]) }
        }
        each(&h, "rooms") { fill(&$0, ["description": "", "kind": "room", "prov": prov]) }
        each(&h, "slab_holes") { fill(&$0, ["prov": prov]) }
        each(&h, "stairs") { fill(&$0, ["void": true, "prov": prov]) }
        each(&h, "furniture") { fill(&$0, ["name": "", "base_z": 0.0, "rotation": 0.0, "attributes": JObject(), "movable": true, "movable_default": true, "obstacle": false, "prov": prov]) }
        each(&h, "switches") { fill(&$0, ["ports": 8, "port_rate": 1000.0, "prov": prov]) }
        each(&h, "jacks") { fill(&$0, ["z": 0.3, "state": "unknown", "leads_to": "unknown", "poe": false, "prov": prov]) }
        each(&h, "outlets") { fill(&$0, ["z": 0.3, "prov": prov]) }
        each(&h, "zones") { z in
            fill(&z, ["name": "", "weight": 1.0, "requires": "none", "mounts": [Any](), "heights": [Any](), "prov": prov])
            if var need = z["need"] as? JObject { fill(&need, ["must": false, "rx_height": 1.0]); z["need"] = need }
        }
        each(&h, "access_points") { fill(&$0, ["name": "", "height": 1.5, "eirp_dbm": 23.0, "bssids": [Any](), "prov": prov]) }
        each(&h, "measure_checks") { fill(&$0, ["at": ""]) }
        each(&h, "arrangements") { a in
            fill(&a, ["name": ""])
            each(&a, "nodes") { fill(&$0, ["mount_height": 1.0, "backhaul": "auto"]) }
        }
        if var e = h["entry"] as? JObject { fill(&e, ["kind": "modem", "prov": prov]); h["entry"] = e }
        if var c = h["calibration"] as? JObject { fill(&c, ["n": JObject(), "extra_loss_db": JObject(), "rmse_cv": JObject(), "n_measurements": JObject()]); h["calibration"] = c }
        return h
    }
}

/// Brings an older document up to `House.schemaVersion`, one version at a time. `steps[n]` turns a version n document into version n+1.
/// There is none yet (the model is at version 1): add the step in the same change that adds or renames a field, with a fixture of the old shape.
public enum Migrations {
    public static let steps: [Int: @Sendable (JObject) -> JObject] = [:]

    /// The document at `current`. A document from a newer app, or one with no step to bring it forward, is refused (never guessed at).
    public static func upgrade(_ input: JObject, to current: Int = House.schemaVersion, steps: [Int: @Sendable (JObject) -> JObject] = Migrations.steps) throws -> JObject {
        var o = input
        let found = o["schema_version"]
        var v = 1
        if let f = found { guard let n = (f as? NSNumber)?.intValue, n >= 1 else { throw ImportError("the house has no readable schema version") }; v = n }
        if v > current { throw ImportError("this house was saved by a newer version of homemesh (format \(v), this one reads up to \(current)); update the app to open it") }
        while v < current {
            guard let step = steps[v] else { throw ImportError("no way to bring a format \(v) house up to format \(current)") }
            o = step(o)
            v += 1
            o["schema_version"] = v
        }
        return o
    }
}

extension House {
    /// Decodes a document with its format brought up to date, missing defaulted fields filled in (and blueprints dropped).
    public static func load(lenient data: Data) throws -> House {
        guard let o = try JSONSerialization.jsonObject(with: data) as? JObject else { throw ImportError("the house is not a JSON object") }
        return try load(try JSONSerialization.data(withJSONObject: Normalize.house(try Migrations.upgrade(o))))
    }
}
