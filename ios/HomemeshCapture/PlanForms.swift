import SwiftUI

extension Geometry {
    /// The convex hull of points (monotone chain), counter-clockwise.
    static func convexHull(_ pts: [Pt]) -> [Pt] {
        let p = Set(pts).sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: Pt, _ a: Pt, _ b: Pt) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Pt] = [], upper: [Pt] = []
        for q in p { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The outline of a zone around chosen rooms and walls: one room is its own outline; several things are wrapped in their hull.
    /// Two points (a lone wall) become a strip 0.6 m across; one point stays a single spot.
    static func zoneOutline(rooms: [PlanRoom], walls: [PlanWall], corners: [Pt] = []) -> [Pt] {
        if rooms.count == 1, walls.isEmpty, corners.isEmpty { return rooms[0].polygon }
        let pts = rooms.flatMap(\.polygon) + walls.flatMap { [$0.a, $0.b] } + corners
        let hull = convexHull(pts)
        if hull.count == 2 { return stairRectangle(hull[0], hull[1], width: 0.6) }
        return hull
    }

    enum Side: String, CaseIterable, Identifiable, Sendable {
        case north = "North", east = "East", south = "South", west = "West"
        var id: String { rawValue }
    }

    /// A staircase flight inside a room, against its `side` wall: `length` metres along the wall from the corner at the
    /// start of that side (west to east on the north and south sides, south to north on the east and west sides), `width` across.
    /// Returns the flight's centre line from its bottom to its top, clamped to the room's extent.
    static func stairInRoom(_ room: [Pt], side: Side, length: Double, width: Double) -> (bottom: Pt, top: Pt)? {
        guard room.count >= 3 else { return nil }
        let b = bounds(room)
        let w = min(width, min(b.width, b.height))
        let half = w / 2
        switch side {
        case .north, .south:
            let y = side == .north ? b.maxY - half : b.minY + half
            let l = min(length, b.width)
            return (Pt(b.minX, y), Pt(b.minX + l, y))
        case .east, .west:
            let x = side == .east ? b.maxX - half : b.minX + half
            let l = min(length, b.height)
            return (Pt(x, b.minY), Pt(x, b.minY + l))
        }
    }
}

/// Makes a zone without touching the plan: from chosen rooms, chosen walls, or corners typed in metres.
struct ZoneFormSheet: View {
    enum Source: String, CaseIterable, Identifiable { case rooms = "Rooms", walls = "Walls", corners = "Corners"; var id: String { rawValue } }

    let rooms: [PlanRoom]
    let walls: [PlanWall]
    let onMake: (_ kind: String, _ polygon: [Pt]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "allow"
    @State private var source = Source.rooms
    @State private var pickedRooms: Set<String> = []
    @State private var pickedWalls: Set<String> = []
    @State private var corners: [(x: String, y: String)] = [("", "")]

    private func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    var cornerPoints: [Pt] { corners.compactMap { c in number(c.x).flatMap { x in number(c.y).map { Pt(x, $0) } } } }

    var outline: [Pt] {
        switch source {
        case .rooms: Geometry.zoneOutline(rooms: rooms.filter { pickedRooms.contains($0.id) }, walls: [])
        case .walls: Geometry.zoneOutline(rooms: [], walls: walls.filter { pickedWalls.contains($0.id) })
        case .corners: Geometry.zoneOutline(rooms: [], walls: [], corners: cornerPoints)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kind") {
                    Picker("Kind", selection: $kind) {
                        Text("Where it may go").tag("allow"); Text("Where it must not").tag("forbid"); Text("Needs signal").tag("demand")
                    }
                }
                Section("Take the area from") {
                    Picker("Take the area from", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                }
                switch source {
                case .rooms:
                    Section("Rooms on this floor") {
                        if rooms.isEmpty { SuiNote(.neutral, "No rooms on this floor yet.") }
                        ForEach(rooms) { r in pick(r.name.isEmpty ? r.id : r.name, selected: pickedRooms.contains(r.id)) { toggle(&pickedRooms, r.id) } }
                    }
                case .walls:
                    Section("Walls on this floor") {
                        ForEach(walls) { w in pick(String(format: "Wall %@, %.1f m", w.id, w.length), selected: pickedWalls.contains(w.id)) { toggle(&pickedWalls, w.id) } }
                    }
                case .corners:
                    Section {
                        ForEach(corners.indices, id: \.self) { i in
                            HStack {
                                TextField("x (m)", text: Binding(get: { corners[i].x }, set: { corners[i].x = $0 })).keyboardType(.numbersAndPunctuation)
                                    .accessibilityLabel("Corner \(i + 1), x in metres")
                                TextField("y (m)", text: Binding(get: { corners[i].y }, set: { corners[i].y = $0 })).keyboardType(.numbersAndPunctuation)
                                    .accessibilityLabel("Corner \(i + 1), y in metres")
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityAction(named: "Remove corner \(i + 1)") { if corners.count > 1 { corners.remove(at: i) } }
                        }
                        Button("Add a corner", systemImage: "plus") { corners.append(("", "")) }
                    } header: { Text("Corners, in plan metres") } footer: { Text("One corner makes a single spot; three or more make an area.") }
                }
                Section {
                    Text(summary).font(.footnote).accessibilityLabel("Result: \(summary)")
                }
            }
            .navigationTitle("Add a zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onMake(kind, outline); dismiss() }.disabled(outline.isEmpty) }
            }
        }
    }

    private var summary: String {
        let o = outline
        switch o.count {
        case 0: return "Choose at least one \(source == .corners ? "corner" : source == .rooms ? "room" : "wall")."
        case 1: return "A single spot."
        default:
            let b = Geometry.bounds(o)
            return String(format: "An area about %.1f by %.1f m with %d corners.", b.width, b.height, o.count)
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }

    private func pick(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(SuiColor.accent) } }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Places a staircase without touching the plan: the floor it leads to, the room it is in, which wall it runs along, how long and wide.
struct StairFormSheet: View {
    let levels: [HouseLite.Level]
    let here: String
    let rooms: [PlanRoom]    // on this floor
    let onMake: (_ target: String, _ bottom: Pt, _ top: Pt, _ width: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var roomId = ""
    @State private var side = Geometry.Side.north
    @State private var length = "3.0"
    @State private var width = "1.0"

    private func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil } }

    private var placement: (bottom: Pt, top: Pt)? {
        guard let room = rooms.first(where: { $0.id == roomId }), let l = number(length), let w = number(width) else { return nil }
        return Geometry.stairInRoom(room.polygon, side: side, length: l, width: w)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Floors") {
                    Picker("This floor leads to", selection: $target) { ForEach(levels.filter { $0.id != here }, id: \.id) { Text($0.name).tag($0.id) } }
                }
                Section("Where") {
                    Picker("Room", selection: $roomId) { ForEach(rooms) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) } }
                    Picker("Runs along the wall on the", selection: $side) { ForEach(Geometry.Side.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Length (m)", text: $length).keyboardType(.decimalPad)
                    TextField("Width (m)", text: $width).keyboardType(.decimalPad)
                } footer: { Text("The bottom of the flight is at the west or south end of that wall. Turn the flight round afterwards if it climbs the other way.") }
            }
            .navigationTitle("Add a staircase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { if let p = placement, let w = number(width) { onMake(target, p.bottom, p.top, w); dismiss() } }.disabled(placement == nil || target.isEmpty)
                }
            }
            .onAppear {
                if target.isEmpty { target = levels.first { $0.id != here }?.id ?? "" }
                if roomId.isEmpty { roomId = rooms.first?.id ?? "" }
            }
        }
    }
}
