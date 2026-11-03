import Foundation

// The capture routes of the in-process API: upload, naming, floors, doors, the room list, placement and import.

extension LocalAPI {
    func uploadCapture(_ id: String, _ body: Data, _ q: [String: String]) throws -> Any {
        let (s, h) = try get(id)
        let level = q["level"] ?? "", replaces = q["replaces"] ?? "", purpose = q["purpose"] ?? ""
        let levelIds = Set(h.levels.map(\.id))
        if !level.isEmpty && !levelIds.contains(level) { throw APIError(422, "unknown level") }
        if !replaces.isEmpty {   // "<capture>:<room index>" of the room this scan re-scans
            let parts = replaces.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, (try? Captures.meta(s, parts[0])) != nil, Int(parts[1]) != nil else { throw APIError(422, "replaces must be <capture>:<room index> of a stored scan") }
        }
        if let text = String(data: body, encoding: .utf8), text.contains("\"room_levels\""), let data = try? JSONSerialization.jsonObject(with: body) as? JObject {
            if let rl = Captures.roomLevelsOf(data), rl.contains(where: { ($0 as? String).map { !levelIds.contains($0) } ?? false }) { throw APIError(422, "unknown level in room_levels") }
        }
        if purpose != "" && purpose != "stairs" { throw APIError(422, "unknown purpose") }
        var stair: JObject?
        let from = q["stair_from"] ?? "", to = q["stair_to"] ?? ""
        if !from.isEmpty || !to.isEmpty {
            if !levelIds.contains(from) || !levelIds.contains(to) || from == to { throw APIError(422, "a staircase joins two different, existing levels") }
            stair = ["from_level": from, "to_level": to]
        }
        do { return try Captures.saveCapture(s, raw: body, name: q["name"] ?? "", level: level, replaces: replaces, purpose: purpose, stair: stair, now: now()) }
        catch let e as CaptureError { throw APIError(422, e.message) }
    }

    func uploadUSDZ(_ id: String, _ digest: String, _ raw: Data) throws -> Any {
        let (s, _) = try get(id)
        do { return try Captures.attachUSDZ(s, digest, raw: raw) } catch let e as CaptureError { throw APIError(422, e.message) }
    }

    func putCapture(_ id: String, _ digest: String, what: String, _ b: JObject) throws -> Any {
        let (s, h) = try get(id)
        let levelIds = Set(h.levels.map(\.id))
        do {
            switch what {
            case "rooms":
                guard let names = b["names"] as? [String] else { throw APIError(422, "names are required") }
                return try Captures.setRoomNames(s, digest, names: names, descriptions: b["descriptions"] as? [String])
            case "level":
                guard let level = b["level"] as? String, levelIds.contains(level) else { throw APIError(422, "unknown level") }
                _ = try Captures.meta(s, digest)
                func mine(_ ref: String?) -> Bool { (ref ?? "").hasPrefix("\(digest)#") }
                if h.walls.contains(where: { mine($0.prov.ref) }) || h.rooms.contains(where: { mine($0.prov.ref) }) {
                    var moved = h
                    for i in moved.walls.indices where mine(moved.walls[i].prov.ref) { moved.walls[i].level = level }
                    for i in moved.rooms.indices where mine(moved.rooms[i].prov.ref) { moved.rooms[i].level = level }
                    _ = try save(s, moved, expect: h.revision)
                }
                return try Captures.setLevel(s, digest, level)
            case "stair":
                var stair: JObject?
                let from = b["from_level"] as? String, to = b["to_level"] as? String
                if (from?.isEmpty == false) || (to?.isEmpty == false) {
                    guard let f = from, let t = to, levelIds.contains(f), levelIds.contains(t), f != t else { throw APIError(422, "a staircase joins two different, existing levels") }
                    stair = ["from_level": f, "to_level": t]
                }
                return try Captures.setStair(s, digest, stair)
            case "doors":
                guard let labels = b["labels"] as? [String: String] else { throw APIError(422, "labels are required") }
                return try Captures.setDoorLabels(s, digest, labels)
            default: throw APIError(404, "no such route")
            }
        } catch let e as CaptureError { throw APIError(422, e.message) }
    }

    func doorsChecklist(_ id: String, level: String) throws -> Any {
        let (s, _) = try get(id)
        let metas = Captures.list(s).map(Self.captureInfo)
        let rows = Connections.checklist(metas)
        return rows.filter { level.isEmpty || ($0.level ?? "") == level }.map { r -> JObject in
            ["capture": r.capture, "name": r.name, "level": r.level as Any? ?? NSNull(), "rooms": r.rooms, "issues": r.issues, "complete": r.complete,
             "doors": r.doors.map { ["id": $0.id, "kind": metas.first { $0.blob == r.capture }?.kind(of: $0.id) ?? "door", "room": $0.room, "number": $0.number, "room_name": $0.roomName, "label": $0.label, "status": $0.status.rawValue] as JObject }]
        }
    }

    static func captureInfo(_ m: JObject) -> CaptureInfo {
        var c = CaptureInfo(blob: m["blob"] as! String, name: m["name"] as? String ?? "", level: m["level"] as? String, at: (m["at"] as? NSNumber)?.doubleValue ?? 0, rooms: m["rooms"] as? [String] ?? [],
                            doors: (m["doors"] as? [JObject] ?? []).map { DoorEntry(id: $0["id"] as! String, room: $0["room"] as! Int, number: $0["number"] as! Int) },
                            doorLabels: m["door_labels"] as? [String: String] ?? [:], purpose: m["purpose"] as? String, replaces: m["replaces"] as? String)
        c.kinds = Dictionary((m["doors"] as? [JObject] ?? []).map { ($0["id"] as! String, $0["kind"] as? String ?? "door") }, uniquingKeysWith: { a, _ in a })
        return c
    }

    func captureDoors(_ id: String, _ digest: String) throws -> Any {
        let (s, _) = try get(id)
        do {
            let meta = try Captures.meta(s, digest), data = try Captures.load(s, digest)
            let labels = meta["door_labels"] as? [String: String] ?? [:]
            let ds = try ScanImport.scanDoors(data).enumerated().map { (i, d) -> JObject in
                ["id": d.id, "kind": d.kind, "room": d.room, "x": d.x, "y": d.y, "angle": d.angle, "width": d.width, "number": i + 1, "label": labels[d.id] ?? ""]
            }
            let walls = try ScanImport.scanWallSegments(data).map { ["a": [$0.a.x, $0.a.y], "b": [$0.b.x, $0.b.y]] as JObject }
            return ["doors": ds, "walls": walls, "rooms": meta["rooms"] ?? [String]()] as JObject
        } catch let e as CaptureError { throw APIError(422, e.message) } catch let e as ImportError { throw APIError(422, e.message) }
    }

    func roomList(_ id: String) throws -> Any {
        let (s, h) = try get(id)
        var placed: [String: Room] = [:]
        for r in h.rooms { placed[r.prov.ref ?? ""] = r }
        let metas = Captures.list(s).sorted { ($0["at"] as? NSNumber)?.doubleValue ?? 0 < ($1["at"] as? NSNumber)?.doubleValue ?? 0 }
        var replacedBy: [String: String] = [:]
        for meta in metas {   // a re-scan names the room it replaces; its first room of the same name (else the first) takes over
            guard let rep = meta["replaces"] as? String, !rep.isEmpty else { continue }
            let names = (meta["rooms"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let parts = rep.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            replacedBy[rep] = "\(meta["blob"] as! String):0"
            if let old = metas.first(where: { ($0["blob"] as? String) == parts[0] }), parts.count > 1, let oi = Int(parts[1]) {
                let oldRooms = old["rooms"] as? [String] ?? []
                if oi < oldRooms.count {
                    let want = oldRooms[oi].trimmingCharacters(in: .whitespaces).lowercased()
                    if let k = names.firstIndex(of: want) { replacedBy[rep] = "\(meta["blob"] as! String):\(k)" }
                }
            }
        }
        var out: [Any] = []
        for meta in metas {
            if (meta["purpose"] as? String) == "stairs" { continue }
            let blob = meta["blob"] as! String
            let names = meta["rooms"] as? [String] ?? [], about = meta["descriptions"] as? [String] ?? []
            let n = (meta["counts"] as? [String: Int])?["rooms"] ?? 0
            let stories = meta["stories"] as? [Any] ?? []
            let roomLevels = meta["room_levels"] as? [Any] ?? []
            for i in 0..<n {
                let r = placed["\(blob)#room/\(i)"]
                let nm = (i < names.count ? names[i] : "").isEmpty ? (r?.name ?? "") : names[i]
                let ds = (i < about.count ? about[i] : "").isEmpty ? (r?.description ?? "") : about[i]
                let levelFromScan: Any = (i < roomLevels.count ? (roomLevels[i] as? String) : nil) ?? (meta["level"] as? String) as Any? ?? NSNull()
                out.append(["key": "\(blob):\(i)", "capture": blob, "index": i, "scan": meta["name"] as? String ?? "", "name": nm, "description": ds,
                            "level": r.map { $0.level as Any } ?? levelFromScan, "story": i < stories.count ? stories[i] : NSNull(), "placed": r.map { $0.id as Any } ?? NSNull(),
                            "usdz": meta["usdz"] ?? NSNull(), "at": meta["at"] as Any, "replaced_by": replacedBy["\(blob):\(i)"].map { $0 as Any } ?? NSNull(), "baro": meta["baro"] ?? NSNull()] as JObject)
            }
        }
        return out
    }

    func retireArgs(_ s: HouseStore, _ meta: JObject) throws -> (data: JObject, blob: String, room: Int)? {
        guard let key = meta["replaces"] as? String, !key.isEmpty else { return nil }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let idx = Int(parts[1]) else { return nil }
        return (try Captures.load(s, parts[0]), parts[0], idx)
    }

    func place(_ id: String, _ digest: String, level: String) throws -> Any {
        let (s, h) = try get(id)
        do {
            let data = try Captures.load(s, digest), meta = try Captures.meta(s, digest)
            var planLabels: [String: String] = [:]
            for m in Captures.list(s) { for (k, v) in m["door_labels"] as? [String: String] ?? [:] { planLabels["\(m["blob"] as! String)#\(k)"] = v } }
            let rl = (meta["room_levels"] as? [Any])?.map { $0 as? String }
            let p = try Placement.propose(house: h, data: data, level: level, blob: digest, names: meta["rooms"] as? [String], retire: try retireArgs(s, meta), roomLevels: rl,
                                          doorLabels: meta["door_labels"] as? [String: String] ?? [:], planLabels: planLabels)
            var ev: JObject = [:]
            if p.confidence == .labelled || p.confidence == .confirm && p.evidence.source == "labelled doors" {
                ev = ["connections": p.evidence.connections, "residual_cm": p.evidence.residualCm, "room_overlap_m2": p.evidence.roomOverlapM2, "wall_overlap_m": p.evidence.wallOverlapM, "source": p.evidence.source, "missing": p.evidence.missing]
            } else if p.confidence == .unlabelled { ev = ["missing": p.evidence.missing] }
            else if p.evidence.source == "stair" { ev = ["stairs": p.evidence.stairs, "source": "stair"] }
            var out: JObject = ["confidence": p.confidence.rawValue, "reason": p.reason, "transform": ["rotation": ScanImport.rnd(p.transform.rotation, 3), "tx": ScanImport.rnd(p.transform.tx, 4), "ty": ScanImport.rnd(p.transform.ty, 4)],
                                "score": 0.0, "evidence": ev, "alternatives": [Any](),
                                "preview": p.preview.map { ["a": [$0.a.x, $0.a.y], "b": [$0.b.x, $0.b.y]] as JObject }]
            if p.confidence != .unlabelled { out["source"] = p.evidence.source }
            return out
        } catch let e as CaptureError { throw APIError(422, e.message) } catch let e as ImportError { throw APIError(422, e.message) }
    }

    func importScan(_ id: String, _ digest: String, level: String, _ raw: Data) throws -> Any {
        let (s, stored) = try get(id)
        if raw.count > Self.maxBody { throw APIError(413, "too large") }
        let b = try body(raw)
        do {
            var h = stored
            if let hv = b["house"] as? JObject {
                h = try House.load(lenient: try JSONSerialization.data(withJSONObject: hv))
                if h.id != id || !h.validate().isEmpty { throw APIError(422, "invalid house") }
            }
            var sim: Similarity2D?
            var regInfo: JObject?
            if let reg = b["registration"] as? JObject, let src = reg["src"] as? [[Double]], let dst = reg["dst"] as? [[Double]] {
                let s2 = src.map { Vec2($0[0], $0[1]) }, d2 = dst.map { Vec2($0[0], $0[1]) }
                let r = try ScanImport.register(s2, d2)
                sim = r
                let err = zip(s2, d2).map { (r.apply($0) - $1).length }.max() ?? 0
                regInfo = ["rotation": r.rotation, "tx": r.tx, "ty": r.ty, "max_error_m": err]
            } else if let t = b["transform"] as? JObject {
                let r = Similarity2D(rotation: (t["rotation"] as! NSNumber).doubleValue, tx: (t["tx"] as! NSNumber).doubleValue, ty: (t["ty"] as! NSNumber).doubleValue)
                sim = r
                regInfo = ["rotation": r.rotation, "tx": r.tx, "ty": r.ty]
            }
            let data = try Captures.load(s, digest), meta = try Captures.meta(s, digest)
            var o = ImportOptions(transform: sim, names: meta["rooms"] as? [String], descriptions: meta["descriptions"] as? [String], makeRooms: (meta["purpose"] as? String) != "stairs")
            o.roomLevels = (meta["room_levels"] as? [Any])?.map { $0 as? String }
            var (new, rep) = try ScanImport.importCapture(house: h, data: data, level: level, blob: digest, options: o)
            new = try ScanImport.applyStair(new, data: data, blob: digest, meta: meta, sim: sim, found: rep.stairs, notes: &rep.notes)
            let problems = new.validate()
            if !problems.isEmpty { throw APIError(422, "the import would make an invalid house: " + problems.prefix(5).joined(separator: "; ")) }
            if let r = try retireArgs(s, meta) {
                let (n2, gone) = try ScanImport.retireRoom(new, data: r.data, blob: r.blob, index: r.room)
                new = n2
                rep.replaced += gone
                rep.notes.append("replaced the earlier scan of this room (\(gone) wall(s) removed); the old scan stays stored")
            }
            let stairs = rep.stairs.map { st -> JObject in ["room": st.room, "polygon": st.polygon.map { [$0.x, $0.y] }, "rise": st.rise, "width": st.width, "run": st.run, "level": st.level as Any? ?? NSNull()] }
            var out: JObject = ["house": try houseJSON(new), "report": ["walls": rep.walls, "paired_walls": rep.paired_walls, "openings": rep.openings, "skipped_openings": rep.skipped_openings, "rooms": rep.rooms,
                                                                         "furniture": rep.furniture, "curved_walls": rep.curved_walls, "profile_walls": rep.profile_walls, "folded_jogs": rep.folded_jogs,
                                                                         "stairs": stairs, "replaced": rep.replaced, "notes": rep.notes] as JObject]
            if let regInfo { out["registration"] = regInfo }
            return out
        } catch let e as CaptureError { throw APIError(422, e.message) } catch let e as ImportError { throw APIError(422, e.message) }
    }
}

extension CaptureInfo {
    func kind(of id: String) -> String? { kinds[id] }
}
