import Foundation

// The doors checklist (a port of homemesh/connections.py): every scan's doors and openings, whether each says where it leads, and whether
// the room it leads to has a door that says it leads back. Placement by connections needs both sides.

public struct DoorEntry: Sendable, Hashable {
    public var id: String
    public var room: Int
    public var number: Int
    public init(id: String, room: Int, number: Int) { self.id = id; self.room = room; self.number = number }
}

/// What the checklist needs to know of a stored scan.
public struct CaptureInfo: Sendable {
    public var blob: String
    public var name: String
    public var level: String?
    public var at: Double
    public var rooms: [String]
    public var doors: [DoorEntry]
    public var doorLabels: [String: String]
    public var purpose: String?
    public var replaces: String?          // "<blob>" or "<blob>:<index>"
    public init(blob: String, name: String = "", level: String? = nil, at: Double = 0, rooms: [String] = [], doors: [DoorEntry] = [], doorLabels: [String: String] = [:], purpose: String? = nil, replaces: String? = nil) {
        self.blob = blob; self.name = name; self.level = level; self.at = at; self.rooms = rooms; self.doors = doors; self.doorLabels = doorLabels; self.purpose = purpose; self.replaces = replaces
    }
}

public enum DoorStatus: String, Sendable { case unlabelled, outside, ok, missing }

public struct CheckedDoor: Sendable, Hashable {
    public var id: String
    public var room: Int
    public var number: Int
    public var roomName: String
    public var label: String
    public var status: DoorStatus
}

public struct CaptureChecklist: Sendable {
    public var capture: String
    public var name: String
    public var level: String?
    public var rooms: [String]
    public var doors: [CheckedDoor]
    public var issues: [String]
    public var complete: Bool
}

public enum Connections {
    public static func fold(_ name: String) -> String { name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    public static func checklist(_ metas: [CaptureInfo]) -> [CaptureChecklist] {
        let replaced = Set(metas.map { ($0.replaces ?? "").split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? "" })
        let live = metas.filter { $0.purpose != "stairs" && !replaced.contains($0.blob) }
        var back: [String: Set<String>] = [:]
        for m in live {
            for d in m.doors {
                if let to = m.doorLabels[d.id], !to.isEmpty, d.room < m.rooms.count, !fold(m.rooms[d.room]).isEmpty { back[fold(m.rooms[d.room]), default: []].insert(fold(to)) }
            }
        }
        let known = Set(back.keys).union(live.flatMap { $0.rooms.map(fold) }.filter { !$0.isEmpty })
        var out: [CaptureChecklist] = []
        for m in live.sorted(by: { $0.at < $1.at }) {
            var doors: [CheckedDoor] = [], issues: [String] = []
            for d in m.doors {
                let mine = d.room < m.rooms.count ? m.rooms[d.room] : ""
                let to = m.doorLabels[d.id] ?? ""
                var status: DoorStatus
                if to.isEmpty { status = .unlabelled }
                else if fold(to) == "outside" { status = .outside }
                else if back[fold(to)]?.contains(fold(mine)) == true { status = .ok }
                else {
                    status = .missing
                    let who = mine.isEmpty ? "A room" : mine
                    issues.append(known.contains(fold(to))
                        ? "\(who) says door \(d.number) leads to \(to), but \(to) has no door labelled \(mine.isEmpty ? "this room" : mine)"
                        : "\(who) says door \(d.number) leads to \(to), but there is no scanned room called \(to)")
                }
                doors.append(CheckedDoor(id: d.id, room: d.room, number: d.number, roomName: mine, label: to, status: status))
            }
            let n = doors.filter { $0.status == .unlabelled }.count
            if n > 0 { issues.append("\(n) door(s) not labelled yet") }
            out.append(CaptureChecklist(capture: m.blob, name: m.name, level: m.level, rooms: m.rooms, doors: doors, issues: issues, complete: !doors.isEmpty && issues.isEmpty))
        }
        return out
    }
}
