import RoomPlan
import SwiftUI

/// A door or opening of a scan, in the scan's own plan frame. `id` is the first 8 characters of RoomPlan's identifier: the key
/// doorway labels use on the server.
struct DoorInfo: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: String
    let room: Int
    let x: Double
    let y: Double
    let angle: Double      // degrees
    let width: Double
    var number: Int = 0
    var label: String = ""

    var at: Pt { Pt(x, y) }
}

/// `GET .../captures/<blob>/doors`
struct ScanDoorsInfo: Codable, Sendable {
    let doors: [DoorInfo]
    let walls: [Seg]
    let rooms: [String]
}

struct DoorLabelsBody: Encodable, Sendable {
    let labels: [String: String]
}

/// Doors and walls read off the RoomPlan rooms just scanned (before anything is uploaded), in the same frame the server uses.
enum ScanDoors {
    nonisolated static func doors(_ rooms: [CapturedRoom]) -> [DoorInfo] {
        var out: [DoorInfo] = []
        for (i, r) in rooms.enumerated() {
            for s in r.doors + r.openings {
                let t = s.transform
                let c = t.columns.3, ax = t.columns.0
                let angle = atan2(Double(-ax.z), Double(ax.x)) * 180 / .pi
                var kind = "door"
                if case .opening = s.category { kind = "opening" }
                out.append(DoorInfo(id: String(s.identifier.uuidString.prefix(8)), kind: kind, room: i, x: Double(c.x), y: Double(-c.z), angle: angle,
                                    width: Double(s.dimensions.x), number: out.count + 1, label: ""))
            }
        }
        return out
    }

    nonisolated static func walls(_ rooms: [CapturedRoom]) -> [Seg] {
        rooms.flatMap { $0.walls }.map { w in
            let t = w.transform, c = t.columns.3, ax = t.columns.0
            let h = Double(w.dimensions.x) / 2
            return Seg(a: Pt(Double(c.x) - Double(ax.x) * h, -(Double(c.z) - Double(ax.z) * h)), b: Pt(Double(c.x) + Double(ax.x) * h, -(Double(c.z) + Double(ax.z) * h)))
        }
    }
}

enum DoorLabelChoices {
    static let outside = "Outside"

    /// The names a door can lead to: rooms of the house and of this scan session, once each, the owner's order kept.
    static func names(house: [String], session: [String], excluding own: Set<String> = []) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in house + session {
            let t = n.trimmed
            guard !t.isEmpty, !own.contains(t.lowercased()), seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }
}

/// A small picture of a scan with its doors numbered, and a "leads to" choice for each.
struct DoorLabelsView: View {
    let doors: [DoorInfo]
    let walls: [Seg]
    let roomNames: [String]          // names of the scan's own rooms, by index, for the door list
    let choices: [String]
    @Binding var labels: [String: String]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanCanvas(walls: [], rooms: [], ghost: walls, bounds: Geometry.bounds(walls.flatMap { [$0.a, $0.b] }),
                       markers: doors.map { PlanMarker(id: "s\($0.number)", kind: .door, at: $0.at) }, selectedMarker: selected.map { "s\($0)" },
                       onTapPlan: { p, tol in
                           selected = doors.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
                               .flatMap { hypot($0.x - p.x, $0.y - p.y) <= max(tol, 0.5) ? $0.id : nil }
                       })
                .frame(height: 220)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            ForEach(doors) { d in
                HStack {
                    Text("\(d.number)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(SuiPlanColor.doorMarker)).foregroundStyle(SuiPlanColor.onMarker)
                    VStack(alignment: .leading) {
                        Text(d.kind == "door" ? "Door" : "Opening").font(.footnote)
                        Text(d.room < roomNames.count && !roomNames[d.room].isEmpty ? "in \(roomNames[d.room])" : "").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Leads to", selection: Binding(get: { labels[d.id] ?? "" }, set: { selected = d.id; if $0.isEmpty { labels[d.id] = nil } else { labels[d.id] = $0 } })) {
                        Text("Not said").tag("")
                        ForEach(choices + [DoorLabelChoices.outside], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 2)
                .background(selected == d.id ? Color.accentColor.opacity(0.12) : .clear)
            }
        }
    }
}

/// The doors of a scan already uploaded: where each leads, saved on the server.
struct DoorsScreen: View {
    let houseId: String
    let capture: CaptureMeta
    @EnvironmentObject var model: AppModel
    @State private var info: ScanDoorsInfo?
    @State private var labels: [String: String] = [:]
    @State private var choices: [String] = []
    @State private var status: SuiMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let info {
                    Text("Say where each door leads. Placing a scan then lines it up with the room on the other side.").font(.footnote).foregroundStyle(.secondary)
                    if info.doors.isEmpty { Text("RoomPlan found no doors in this scan.").font(.footnote) }
                    else { DoorLabelsView(doors: info.doors, walls: info.walls, roomNames: info.rooms, choices: choices, labels: $labels) }
                    Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent)
                } else { ProgressView() }
            }.padding()
        }
        .suiMessage($status)
        .navigationTitle("Doors")
        .task { await load() }
    }

    private func load() async {
        do {
            let i = try await model.client().doors(house: houseId, blob: capture.blob)
            info = i
            labels = Dictionary(uniqueKeysWithValues: i.doors.filter { !$0.label.isEmpty }.map { ($0.id, $0.label) })
            let rooms = try await model.client().rooms(house: houseId)
            choices = DoorLabelChoices.names(house: rooms.filter { $0.replaced_by == nil }.map(\.name), session: [],
                                             excluding: Set(i.rooms.map { $0.trimmed.lowercased() }))
        } catch { status = .danger("Could not load the doors: \(error.localizedDescription)") }
    }

    private func save() async {
        do {
            _ = try await model.client().setDoorLabels(house: houseId, blob: capture.blob, labels: labels)
            status = .success("Saved.")
        } catch { status = .danger("Could not save: \(error.localizedDescription)") }
    }
}

/// Tap-to-pair in the placement view: a door on the scan and the door on the plan it meets.
enum DoorPairing {
    /// Whether the scan has to be turned the other way for its room to lie on the opposite side of the wall from `planRoom`
    /// (the rooms of a connection are on opposite sides, so there is no half-turn ambiguity). `scanCentre` is the scan room's
    /// centre in the scan's frame.
    static func needsFlip(scan s: DoorInfo, plan q: PlanDoor, scanCentre: Pt, planRoomCentre: Pt) -> Bool {
        let n = Pt(-sin(q.angle * .pi / 180), cos(q.angle * .pi / 180))
        func side(_ p: Pt) -> Double { (p.x - q.at.x) * n.x + (p.y - q.at.y) * n.y }
        let sidePlan = side(planRoomCentre)
        let t = transform(scan: s, plan: q, flip: false)
        let sideScan = side(Geometry.apply(t, scanCentre))
        return sidePlan * sideScan > 0   // the same side: turn it over
    }

    /// The pairing transform with the rooms on opposite sides and the scan's door set off the plan's by the wall thickness.
    static func transform(scan s: DoorInfo, plan q: PlanDoor, scanCentre: Pt, planRoomCentre: Pt, flip: Bool) -> Transform2D {
        let turn = needsFlip(scan: s, plan: q, scanCentre: scanCentre, planRoomCentre: planRoomCentre) != flip
        var t = transform(scan: s, plan: q, flip: turn)
        let n = Pt(-sin(q.angle * .pi / 180), cos(q.angle * .pi / 180))
        let away = ((planRoomCentre.x - q.at.x) * n.x + (planRoomCentre.y - q.at.y) * n.y) > 0 ? -1.0 : 1.0
        t.tx += n.x * away * q.thickness
        t.ty += n.y * away * q.thickness
        return t
    }

    /// The scan-frame to plan transform that lays scan door `s` on plan door `q`; `flip` turns the scan half a turn the other way.
    static func transform(scan s: DoorInfo, plan q: PlanDoor, flip: Bool) -> Transform2D {
        let rot = q.angle - s.angle + (flip ? 180 : 0)
        let r = Geometry.rotate(s.at, degrees: rot)
        return Transform2D(rotation: rot, tx: q.at.x - r.x, ty: q.at.y - r.y)
    }
}

/// A door already on the plan, with the scan it came from (when known) and its place on a wall.
struct PlanDoor: Hashable, Identifiable {
    let id: String
    let at: Pt
    let angle: Double
    let width: Double
    let ref: String?        // prov ref "<blob>#door/<id8>"
    var thickness: Double = 0.1

    static func all(_ walls: [PlanWall], level: String) -> [PlanDoor] {
        var out: [PlanDoor] = []
        for w in walls where w.level == level {
            let len = w.length
            guard len > 0 else { continue }
            let dx = (w.b.x - w.a.x) / len, dy = (w.b.y - w.a.y) / len
            for (k, o) in w.openings.enumerated() where o.kind != "window" {
                let m = o.offset + o.width / 2
                out.append(PlanDoor(id: "\(w.id)#\(k)", at: Pt(w.a.x + dx * m, w.a.y + dy * m), angle: atan2(dy, dx) * 180 / .pi, width: o.width, ref: o.prov?.ref, thickness: w.thickness))
            }
        }
        return out
    }

    /// (capture blob, door id) it was scanned as.
    var source: (blob: String, door: String)? {
        guard let ref, let hash = ref.range(of: "#door/") else { return nil }
        return (String(ref[..<hash.lowerBound]), String(ref[hash.upperBound...]))
    }
}


/// `GET /api/houses/<id>/doors`: one scan's doors with where each leads and whether the other side says so too.
struct ChecklistDoor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: String
    let room: Int
    let number: Int
    let room_name: String
    let label: String
    let status: String   // unlabelled, outside, ok, missing
}

struct ChecklistRow: Codable, Hashable, Identifiable, Sendable {
    let capture: String
    let name: String
    let level: String?
    let rooms: [String]
    let doors: [ChecklistDoor]
    let issues: [String]
    let complete: Bool
    var id: String { capture }
}

/// The doors of one floor, scan by scan: label everything first, then place.
struct DoorsChecklistView: View {
    let houseId: String
    let level: String
    let levelName: String
    @EnvironmentObject var model: AppModel
    @State private var rows: [ChecklistRow] = []
    @State private var captures: [CaptureMeta] = []
    @State private var note: SuiMessage?

    var body: some View {
        List {
            Section {
                Text("Placing a scan needs a door of it labelled with the room it leads to, and a door of that room labelled back. Label everything first, then place.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                Section {
                    NavigationLink {
                        if let c = captures.first(where: { $0.blob == r.capture }) { DoorsScreen(houseId: houseId, capture: c).onDisappear { Task { await load() } } }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: SuiTone.tone(complete: r.complete).symbol).foregroundStyle(SuiTone.tone(complete: r.complete).color)
                                Text(r.rooms.filter { !$0.isEmpty }.joined(separator: ", ").nonEmpty ?? r.name)
                            }
                            ForEach(r.doors) { d in
                                Text("\(symbol(d.status)) \(d.number). \(d.room_name.isEmpty ? "door" : d.room_name)\(d.label.isEmpty ? "" : " → \(d.label)")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(r.issues, id: \.self) { SuiNote(.warning, $0) }
                }
            }
            if rows.isEmpty { Text("No scans on \(levelName) yet.").font(.footnote) }
        }
        .suiMessage($note)
        .navigationTitle("Doors on \(levelName)")
        .task { await load() }
        .refreshable { await load() }
    }

    private func symbol(_ status: String) -> String {
        switch status { case "ok": "✓"; case "outside": "↗"; case "missing": "✗"; default: "○" }
    }

    private func load() async {
        do {
            rows = try await model.client().get("/api/houses/\(houseId)/doors?level=\(level)")
            captures = try await model.client().captures(house: houseId)
            note = .info("")
        } catch { note = .danger("Could not load the doors: \(error.localizedDescription)") }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
