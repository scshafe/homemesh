import SwiftUI

enum PlanTool: String, CaseIterable, Identifiable {
    case select = "Select", outlet = "Outlet", jack = "Jack", accessPoint = "Access point", entry = "Internet", measure = "Measure", stair = "Stair", zone = "Zone"
    var id: String { rawValue }
}

/// The plan of one floor: tap a wall or a thing to edit it, or pick a tool to put an outlet, jack, access point
/// or staircase on the plan.
struct PlanScreen: View {
    let houseId: String
    let level: String
    @EnvironmentObject var model: AppModel
    @State private var doc: HouseDoc?
    @State private var plan: PlanHouse?
    @State private var tool = PlanTool.select
    @State private var selectedWall: String?
    @State private var selectedMarker: PlanMarker?
    @State private var selectedStair: String?
    @State private var selectedZone: String?
    @State private var selectedFurniture: String?
    @State private var zoneKind = "allow"
    @State private var undoCursor: Int?        // the revision the last undo restored; the next undo goes one before it
    @State private var draft: [Pt] = []
    @State private var stairTarget = ""
    @State private var status = ""
    @State private var bounds = CGRect(x: -1, y: -1, width: 2, height: 2)

    private var markers: [PlanMarker] {
        guard let plan else { return [] }
        var out: [PlanMarker] = []
        for o in plan.outlets where o.level == level { out.append(PlanMarker(id: o.id, kind: .outlet, at: o.position)) }
        for j in plan.jacks where j.level == level { out.append(PlanMarker(id: j.id, kind: .jack, at: j.position)) }
        for a in plan.access_points where a.level == level { out.append(PlanMarker(id: a.id, kind: .accessPoint, at: a.position)) }
        for m in plan.measurements where m.level == level { out.append(PlanMarker(id: m.id, kind: .measurement, at: m.position)) }
        if let e = plan.entry, e.level == level { out.append(PlanMarker(id: "entry", kind: .entry, at: e.position)) }
        return out
    }

    /// The steps of a staircase: the rise is the height between the two floors it joins.
    private func stairLayout(_ st: PlanStair, _ plan: PlanHouse) -> StairGeometry.Layout? {
        let ev = Dictionary(uniqueKeysWithValues: plan.levels.map { ($0.id, $0.elevation) })
        let rise = ev[st.from_level].flatMap { a in ev[st.to_level].map { abs($0 - a) } }
        return StairGeometry.layout(polygon: st.polygon, rise: rise, steps: st.steps, low: st.low)
    }

    private var stairsHere: [PlanStair] { plan?.stairs.filter { $0.from_level == level || $0.to_level == level } ?? [] }

    var body: some View {
        VStack(spacing: 8) {
            if let plan {
                Picker("Tool", selection: $tool) { ForEach(PlanTool.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .onChange(of: tool) { draft = []; selectedWall = nil; selectedMarker = nil; selectedStair = nil; selectedZone = nil; selectedFurniture = nil }
                if tool == .zone {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Kind", selection: $zoneKind) {
                            Text("Where it may go").tag("allow"); Text("Where it must not").tag("forbid"); Text("Needs signal").tag("demand")
                        }.pickerStyle(.segmented)
                        HStack {
                            Text(draft.isEmpty ? "Tap the corners of the area (one tap makes a single spot)." : "\(draft.count) point(s).").font(.footnote)
                            Spacer()
                            Button("Finish") { finishZone(plan) }.disabled(draft.isEmpty)
                            Button("Cancel") { draft = [] }.disabled(draft.isEmpty)
                        }
                    }.padding(.horizontal)
                }
                if tool == .stair {
                    HStack {
                        Text("Leads to").font(.footnote)
                        Picker("Leads to", selection: $stairTarget) { ForEach(plan.levels.filter { $0.id != level }, id: \.id) { Text($0.name).tag($0.id) } }
                        Text(draft.isEmpty ? "Tap the bottom of the stairs, then the top." : "Now tap the top of the stairs.").font(.footnote)
                    }
                }
                PlanCanvas(walls: plan.walls.filter { $0.level == level }, rooms: plan.rooms.filter { $0.level == level },
                           bounds: bounds, selected: selectedWall, markers: markers, stairs: stairsHere.map(\.polygon), stairLayouts: stairsHere.compactMap { stairLayout($0, plan) }, draft: draft,
                           selectedMarker: selectedMarker?.id, zones: plan.zones.filter { $0.level == level }, selectedZone: selectedZone,
                           furniture: plan.furniture.filter { $0.level == level }, selectedFurniture: selectedFurniture, onTapPlan: { p, tol in tap(p, tol: tol, plan: plan) })
                    .background(Color(.secondarySystemBackground))
                if tool == .select {
                    Menu("Choose a wall from a list") {
                        ForEach(plan.walls.filter { $0.level == level }) { w in
                            Button(String(format: "Wall %@, %.1f m", w.id, w.length)) { selectedWall = w.id; selectedMarker = nil; selectedStair = nil; selectedZone = nil; selectedFurniture = nil }
                        }
                    }.font(.footnote)
                }
                inspector(plan)
            } else {
                ProgressView()
            }
            if !status.isEmpty { Text(status).font(.footnote).padding(.horizontal) }
        }
        .navigationTitle(plan?.levels.first { $0.id == level }?.name ?? "Plan")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await undo() } }
                    .disabled(undoTarget == nil)
                    .accessibilityHint("Goes back to the plan as it was before the last change")
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func inspector(_ plan: PlanHouse) -> some View {
        if let doc {
            if let id = selectedWall, let wall = plan.walls.first(where: { $0.id == id }) {
                WallInspector(houseId: houseId, wall: wall, doc: doc, level: level, onSaved: { new in Task { await save(new) } }, status: $status)
                    .frame(maxHeight: 360)
            } else if let m = selectedMarker {
                MarkerInspector(marker: m, doc: doc, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedMarker = nil })
                    .frame(maxHeight: 300)
            } else if let id = selectedStair, let st = plan.stairs.first(where: { $0.id == id }) {
                StairInspector(stair: st, doc: doc, here: level, rise: plan.levels.first { $0.id == st.from_level }.flatMap { a in plan.levels.first { $0.id == st.to_level }.map { abs($0.elevation - a.elevation) } }, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedStair = nil })
                    .frame(maxHeight: 240)
            } else if let id = selectedFurniture, let f = plan.furniture.first(where: { $0.id == id }) {
                FurnitureInspector(item: f, doc: doc, onSaved: { new in Task { await save(new) } }, onClose: { selectedFurniture = nil })
                    .frame(maxHeight: 300)
            } else if let id = selectedZone, let z = plan.zones.first(where: { $0.id == id }) {
                ZoneInspector(zone: z, doc: doc, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedZone = nil })
                    .frame(maxHeight: 420)
            } else if tool == .select {
                Text("Tap a wall, a thing, a piece of furniture, a staircase or a zone.").font(.footnote).foregroundStyle(.secondary)
            } else if tool != .stair && tool != .zone {
                Text("Tap the plan to put the \(tool.rawValue.lowercased()) there.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func tap(_ p: Pt, tol: Double, plan: PlanHouse) {
        guard var d = doc else { return }
        switch tool {
        case .select:
            selectedWall = nil; selectedMarker = nil; selectedStair = nil; selectedZone = nil; selectedFurniture = nil
            if let m = markers.min(by: { dist($0.at, p) < dist($1.at, p) }), dist(m.at, p) <= tol {
                selectedMarker = m
            } else if let st = stairsHere.first(where: { Geometry.contains(p, polygon: $0.polygon) }) {
                selectedStair = st.id
            } else if nearestWall(p, tol: tol / 2, plan: plan) == nil, let f = plan.furniture.first(where: { $0.level == level && $0.contains(p) }) {
                selectedFurniture = f.id
            } else if let w = nearestWall(p, tol: tol, plan: plan) {
                selectedWall = w
            } else if let z = plan.zones.first(where: { $0.level == level && ($0.polygon.count >= 3 ? Geometry.contains(p, polygon: $0.polygon) : dist($0.polygon[0], p) <= max(tol, 0.3)) }) {
                selectedZone = z.id
            }
        case .outlet:
            let id = d.add("outlets", prefix: "o", ["position": [p.x, p.y], "level": level, "z": 0.3])
            selectedMarker = PlanMarker(id: id, kind: .outlet, at: p)
            Task { await save(d) }
        case .jack:
            let id = d.add("jacks", prefix: "j", ["position": [p.x, p.y], "level": level, "z": 0.3, "type": "cat6", "state": "unknown", "poe": false])
            selectedMarker = PlanMarker(id: id, kind: .jack, at: p)
            Task { await save(d) }
        case .accessPoint:
            let id = d.add("access_points", prefix: "ap", ["position": [p.x, p.y], "level": level, "name": "Access point", "height": 1.5])
            selectedMarker = PlanMarker(id: id, kind: .accessPoint, at: p)
            Task { await save(d) }
        case .zone:
            draft.append(p)
        case .measure:
            let id = d.add("measurements", prefix: "m", ["position": [p.x, p.y], "level": level, "device": "iPhone", "band": "5"])
            selectedMarker = PlanMarker(id: id, kind: .measurement, at: p)
            Task { await save(d) }
        case .entry:
            d.setObject("entry", ["position": [p.x, p.y], "level": level, "kind": "modem"])
            selectedMarker = PlanMarker(id: "entry", kind: .entry, at: p)
            Task { await save(d) }
        case .stair:
            draft.append(p)
            guard draft.count == 2, !stairTarget.isEmpty else { if stairTarget.isEmpty { status = "Choose the floor it leads to first."; draft = [] }; return }
            let poly = Geometry.stairRectangle(draft[0], draft[1], width: 1.0)
            let ev = Dictionary(uniqueKeysWithValues: plan.levels.map { ($0.id, $0.elevation) })
            let up = (ev[stairTarget] ?? 0) > (ev[level] ?? 0)
            d.add("stairs", prefix: "s", ["from_level": up ? level : stairTarget, "to_level": up ? stairTarget : level,
                                          "polygon": poly.map { [$0.x, $0.y] }, "void": true])
            draft = []
            Task { await save(d) }
        }
    }

    private func finishZone(_ plan: PlanHouse) {
        guard var d = doc, !draft.isEmpty else { return }
        var zone: [String: Any] = ["level": level, "polygon": draft.map { [$0.x, $0.y] }, "kind": zoneKind, "name": ""]
        switch zoneKind {
        case "demand": zone["weight"] = 1.0; zone["need"] = ["min_rssi": -65.0, "must": false, "rx_height": 1.0]
        case "allow": zone["requires"] = "none"
        default: break
        }
        let id = d.add("zones", prefix: "z", zone)
        draft = []
        selectedZone = id
        Task { await save(d) }
    }

    private func dist(_ a: Pt, _ b: Pt) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private func nearestWall(_ p: Pt, tol: Double, plan: PlanHouse) -> String? {
        var best: (String, Double)?
        for w in plan.walls where w.level == level {
            let d = Geometry.distance(from: p, toSegment: w.a, w.b)
            if d <= tol, best == nil || d < best!.1 { best = (w.id, d) }
        }
        return best?.0
    }

    private func load() async {
        do {
            let data = try await model.client().call("GET", "/api/houses/\(houseId)")
            doc = try HouseDoc(data: data)
            let p = try JSONDecoder().decode(PlanHouse.self, from: data)
            plan = p
            if stairTarget.isEmpty { stairTarget = p.levels.first { $0.id != level }?.id ?? "" }
            let pts = p.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] }
            bounds = Geometry.bounds(pts)
        } catch {
            status = "Could not load the plan: \(error.localizedDescription)"
        }
    }

    private var undoTarget: Int? {
        guard let plan else { return nil }
        let t = (undoCursor ?? plan.revision) - 1
        return t >= 1 ? t : nil
    }

    private func undo() async {
        guard let plan, let t = undoTarget else { return }
        do {
            try await model.client().restore(house: houseId, revision: t, expect: plan.revision)
            undoCursor = t
            selectedWall = nil; selectedMarker = nil; selectedStair = nil; selectedZone = nil; selectedFurniture = nil
            status = "Back to the plan as it was at revision \(t)."
            await load()
        } catch {
            status = "Could not undo: \(error.localizedDescription)"
        }
    }

    private func save(_ new: HouseDoc) async {
        undoCursor = nil
        do {
            try await model.client().saveHouse(house: houseId, json: try new.data(), expectRevision: new.revision)
            status = "Saved."
            await load()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Edit or delete an outlet, a jack or an access point.
struct MarkerInspector: View {
    let marker: PlanMarker
    let doc: HouseDoc
    let onSaved: (HouseDoc) -> Void
    let onRemoved: () -> Void
    @State private var height = ""
    @State private var name = ""
    @State private var type = "cat6"
    @State private var state = "unknown"
    @State private var poe = false
    @State private var eirp = ""
    @State private var rssi = ""
    @State private var rate = ""
    @State private var band = "5"
    @State private var device = "iPhone"
    @State private var entryKind = "modem"
    @State private var wanDown = ""
    @State private var wanUp = ""

    private var collection: String {
        switch marker.kind { case .outlet: "outlets"; case .jack: "jacks"; case .accessPoint: "access_points"; case .entry: "entry"; case .measurement, .suggestion: "measurements" }
    }

    var body: some View {
        Form {
            Section(title) {
                switch marker.kind {
                case .outlet:
                    field("Height above the floor (m)", $height)
                case .jack:
                    Picker("Type", selection: $type) { ForEach(["cat5e", "cat6", "cat6a", "coax_moca"], id: \.self) { Text($0).tag($0) } }
                    Picker("Works?", selection: $state) { ForEach(["live", "dead", "unknown"], id: \.self) { Text($0).tag($0) } }
                    Toggle("Power over Ethernet", isOn: $poe)
                    field("Height above the floor (m)", $height)
                case .measurement, .suggestion:
                    Picker("Band", selection: $band) { Text("2.4 GHz").tag("2.4"); Text("5 GHz").tag("5"); Text("6 GHz").tag("6") }.pickerStyle(.segmented)
                    field("Signal you read here (dBm, for example -62)", $rssi)
                    field("Speed here (Mbit/s, optional)", $rate)
                    TextField("Device", text: $device)
                case .entry:
                    Picker("Comes in as", selection: $entryKind) { Text("Modem").tag("modem"); Text("Fibre ONT").tag("ont"); Text("Coax drop").tag("coax_drop") }
                    field("Download from your provider (Mbit/s)", $wanDown)
                    field("Upload (Mbit/s)", $wanUp)
                case .accessPoint:
                    TextField("Name", text: $name)
                    field("Height (m)", $height)
                    field("Transmit power + antenna gain (dBm)", $eirp)
                }
                Button("Save") { save() }
                Button("Delete", role: .destructive) {
                    var d = doc
                    if marker.kind == .entry { d.setObject("entry", nil) } else { d.remove(collection, marker.id) }
                    onSaved(d); onRemoved()
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: marker.id) { load() }
    }

    private var title: String {
        switch marker.kind { case .outlet: "Outlet \(marker.id)"; case .jack: "Jack \(marker.id)"; case .accessPoint: "Access point \(marker.id)"; case .entry: "Where the internet comes in"; case .measurement, .suggestion: "Measurement \(marker.id)" }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack { Text(label); TextField("", text: text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    private func load() {
        let it = (marker.kind == .entry ? doc.object("entry") : doc.item(collection, marker.id)) ?? [:]
        rssi = (it["rssi"] as? Double).map { String(format: "%g", $0) } ?? ""
        rate = (it["throughput"] as? Double).map { String(format: "%g", $0) } ?? ""
        band = it["band"] as? String ?? "5"
        device = it["device"] as? String ?? "iPhone"
        entryKind = it["kind"] as? String ?? "modem"
        wanDown = (it["wan_down"] as? Double).map { String(format: "%g", $0) } ?? ""
        wanUp = (it["wan_up"] as? Double).map { String(format: "%g", $0) } ?? ""
        height = String(format: "%.2f", (it["z"] as? Double) ?? (it["height"] as? Double) ?? 0.3)
        name = it["name"] as? String ?? ""
        type = it["type"] as? String ?? "cat6"
        state = it["state"] as? String ?? "unknown"
        poe = it["poe"] as? Bool ?? false
        eirp = String(format: "%.0f", (it["eirp_dbm"] as? Double) ?? 23)
    }

    private func save() {
        var d = doc
        switch marker.kind {
        case .outlet: d.set(collection, marker.id, ["z": num(height) ?? 0.3])
        case .jack: d.set(collection, marker.id, ["type": type, "state": state, "poe": poe, "z": num(height) ?? 0.3])
        case .accessPoint: d.set(collection, marker.id, ["name": name, "height": num(height) ?? 1.5, "eirp_dbm": num(eirp) ?? 23])
        case .measurement, .suggestion:
            d.set(collection, marker.id, ["band": band, "rssi": num(rssi), "throughput": num(rate), "device": device.trimmed.isEmpty ? "iPhone" : device.trimmed])
        case .entry:
            var e = doc.object("entry") ?? [:]
            e["kind"] = entryKind
            if let v = num(wanDown), v > 0 { e["wan_down"] = v } else { e.removeValue(forKey: "wan_down") }
            if let v = num(wanUp), v > 0 { e["wan_up"] = v } else { e.removeValue(forKey: "wan_up") }
            d.setObject("entry", e)
        }
        onSaved(d)
    }
}

/// A staircase: which floor it leads to, or delete it.
struct StairInspector: View {
    let stair: PlanStair
    let doc: HouseDoc
    let here: String
    var rise: Double? = nil
    let onSaved: (HouseDoc) -> Void
    let onRemoved: () -> Void
    @State private var other = ""
    @State private var steps = ""

    var body: some View {
        Form {
            Section("Staircase \(stair.id)") {
                Picker("Joins this floor to", selection: $other) {
                    ForEach(doc.levels.filter { $0.id != here }, id: \.id) { Text($0.name).tag($0.id) }
                }
                TextField("Number of steps (blank: \(StairGeometry.stepCount(rise: rise, steps: nil)))", text: $steps).keyboardType(.numberPad)
                Text(stair.low == nil ? "Which end is the bottom is not known; the arrow points the way the flight is drawn." : "The arrow points up the flight.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Turn the flight round (swap bottom and top)") {
                    var d = doc
                    if let l = StairGeometry.swappedLow(polygon: stair.polygon, low: stair.low, rise: rise, steps: Int(steps)) {
                        d.set("stairs", stair.id, ["low": [l.x, l.y]])
                        onSaved(d)
                    }
                }
                Button("Save") {
                    var d = doc
                    let ev = Dictionary(uniqueKeysWithValues: doc.levels.map { ($0.id, $0.elevation) })
                    let up = (ev[other] ?? 0) > (ev[here] ?? 0)
                    d.set("stairs", stair.id, ["from_level": up ? here : other, "to_level": up ? other : here, "steps": Int(steps.trimmed)])
                    onSaved(d)
                }
                Button("Delete", role: .destructive) { var d = doc; d.remove("stairs", stair.id); onSaved(d); onRemoved() }
            }
        }
        .onAppear { other = stair.from_level == here ? stair.to_level : stair.from_level; steps = stair.steps.map(String.init) ?? "" }
        .onChange(of: stair.id) { other = stair.from_level == here ? stair.to_level : stair.from_level; steps = stair.steps.map(String.init) ?? "" }
    }
}

struct WallInspector: View {
    let houseId: String
    let wall: PlanWall
    let doc: HouseDoc
    let level: String
    let onSaved: (HouseDoc) -> Void
    @Binding var status: String
    @State private var thickness = ""
    @State private var material = ""
    @State private var kinds: [String] = []
    @State private var widths: [String] = []
    @State private var tape = ""
    @State private var what = ""

    var body: some View {
        Form {
            Section("Wall \(wall.id): \(String(format: "%.2f", wall.length)) m long") {
                HStack {
                    Text("Thickness (m)")
                    TextField("0.12", text: $thickness).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                if doc.thicknessDefaulted(wall.id) { Text("The scan gave no thickness: this is a guess.").font(.footnote).foregroundStyle(.orange) }
                Picker("Material", selection: $material) { ForEach(doc.materials, id: \.id) { Text($0.name).tag($0.id) } }
                Button("Save this wall") { apply(all: false) }
                Button("Use for every wall on this floor still on the defaults") { apply(all: true) }
            }
            if !kinds.isEmpty {
                Section("Openings") {
                    ForEach(kinds.indices, id: \.self) { i in
                        HStack {
                            Picker("", selection: $kinds[i]) { ForEach(["door", "window", "arch", "hole"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                            TextField("width", text: $widths[i]).keyboardType(.decimalPad).frame(width: 70)
                            Button("Save") { saveOpening(i) }.buttonStyle(.borderless)
                            Button("Delete", role: .destructive) { deleteOpening(i) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            MeasureCheckSection(houseId: houseId, wall: wall, level: level, doc: doc, onSaved: onSaved, status: $status)
        }
        .onAppear(perform: load)
        .onChange(of: wall.id) { load() }
    }

    private func load() {
        thickness = String(format: "%.3f", wall.thickness)
        material = doc.material(of: wall.id) ?? doc.materials.first?.id ?? ""
        let o = doc.openings(of: wall.id)
        kinds = o.map(\.kind)
        widths = o.map { String(format: "%.2f", $0.width) }
    }

    private func apply(all: Bool) {
        var d = doc
        let t = Double(thickness.replacingOccurrences(of: ",", with: "."))
        if all {
            let n = d.applyToDefaults(level: level, thickness: t, material: material)
            status = "\(n) wall(s) updated."
        } else {
            d.update(wall: wall.id, thickness: t, material: material)
        }
        onSaved(d)
    }

    private func saveOpening(_ i: Int) {
        var d = doc
        guard let w = Double(widths[i].replacingOccurrences(of: ",", with: ".")), w > 0 else { status = "Give the width in metres."; return }
        d.setOpening(wall: wall.id, index: i, kind: kinds[i], width: w)
        onSaved(d)
    }

    private func deleteOpening(_ i: Int) {
        var d = doc
        d.removeOpening(wall: wall.id, index: i)
        onSaved(d)
    }
}


/// Name a piece of furniture and say whether it can be moved. The category sets the starting answer (a sink is fixed, a
/// sofa is not); built-in shelves also come as "storage", so each item can be overridden and the override is kept when
/// the room is scanned again.
struct FurnitureInspector: View {
    let item: PlanFurniture
    let doc: HouseDoc
    let onSaved: (HouseDoc) -> Void
    let onClose: () -> Void
    @State private var name = ""
    @State private var movable = true

    var body: some View {
        Form {
            Section(item.title) {
                TextField("Name (for example the grey sofa)", text: $name)
                Toggle("Can be moved", isOn: $movable)
                Text(String(format: "%.2f × %.2f m, %.2f m high", item.width, item.depth, item.height)).font(.footnote).foregroundStyle(.secondary)
                if movable != PlanFurniture.defaultMovable(item.category) {
                    Text("Different from the usual for \(item.category).").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Save") {
                    var d = doc
                    d.set("furniture", item.id, ["name": name.trimmed, "movable": movable, "movable_default": movable == PlanFurniture.defaultMovable(item.category)])
                    onSaved(d)
                }
                Button("Close") { onClose() }
            }
        }
        .onAppear { load() }
        .onChange(of: item.id) { load() }
    }

    private func load() { name = item.name; movable = item.movable }
}

/// The furniture of one room, listed on the room's screen; a tap names it or flips movable/fixed.
struct RoomFurnitureSection: View {
    let houseId: String
    let roomId: String?   // the house room's id once the scan is on the plan
    @EnvironmentObject var model: AppModel
    @State private var plan: PlanHouse?
    @State private var doc: HouseDoc?
    @State private var editing: PlanFurniture?

    var body: some View {
        Group {
            if let roomId, let plan {
                let here = plan.furniture.filter { $0.room == roomId }
                Section("Furniture") {
                    if here.isEmpty { Text("RoomPlan found no furniture in this room.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(here) { f in
                        Button { editing = f } label: {
                            HStack {
                                Text(f.title).foregroundStyle(.primary)
                                Spacer()
                                Text(f.movable ? "movable" : "fixed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { f in
            if let doc {
                FurnitureInspector(item: f, doc: doc, onSaved: { new in Task { await save(new) } }, onClose: { editing = nil })
                    .presentationDetents([.medium])
            }
        }
    }

    private func load() async {
        guard roomId != nil, let data = try? await model.client().call("GET", "/api/houses/\(houseId)") else { return }
        doc = try? HouseDoc(data: data)
        plan = try? JSONDecoder().decode(PlanHouse.self, from: data)
    }

    private func save(_ new: HouseDoc) async {
        if let data = try? new.data() { try? await model.client().saveHouse(house: houseId, json: data, expectRevision: new.revision) }
        editing = nil
        await load()
    }
}
