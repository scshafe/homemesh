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
                    Text("\(d.number)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(Color.orange))
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
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let info {
                    Text("Say where each door leads. Placing a scan then lines it up with the room on the other side.").font(.footnote).foregroundStyle(.secondary)
                    if info.doors.isEmpty { Text("RoomPlan found no doors in this scan.").font(.footnote) }
                    else { DoorLabelsView(doors: info.doors, walls: info.walls, roomNames: info.rooms, choices: choices, labels: $labels) }
                    Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent)
                } else { ProgressView() }
                if !status.isEmpty { Text(status).font(.footnote) }
            }.padding()
        }
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
        } catch { status = "Could not load the doors: \(error.localizedDescription)" }
    }

    private func save() async {
        do {
            _ = try await model.client().setDoorLabels(house: houseId, blob: capture.blob, labels: labels)
            status = "Saved."
        } catch { status = "Could not save: \(error.localizedDescription)" }
    }
}

/// Tap-to-pair in the placement view: a door on the scan and the door on the plan it meets.
enum DoorPairing {
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

    static func all(_ walls: [PlanWall], level: String) -> [PlanDoor] {
        var out: [PlanDoor] = []
        for w in walls where w.level == level {
            let len = w.length
            guard len > 0 else { continue }
            let dx = (w.b.x - w.a.x) / len, dy = (w.b.y - w.a.y) / len
            for (k, o) in w.openings.enumerated() where o.kind != "window" {
                let m = o.offset + o.width / 2
                out.append(PlanDoor(id: "\(w.id)#\(k)", at: Pt(w.a.x + dx * m, w.a.y + dy * m), angle: atan2(dy, dx) * 180 / .pi, width: o.width, ref: o.prov?.ref))
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
