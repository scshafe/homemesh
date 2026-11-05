import HomemeshCore
import SwiftUI

enum PlanTool: String, CaseIterable, Identifiable {
    case select = "Select", wall = "Walls", opening = "Doors and windows", outlet = "Outlet", jack = "Jack", accessPoint = "Access point", entry = "Internet", measure = "Measure", stair = "Stair", zone = "Zone"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .wall: "pencil.line"
        case .opening: "door.left.hand.open"
        case .outlet: "powerplug"
        case .jack: "cable.connector"
        case .accessPoint: "wifi.router"
        case .entry: "network"
        case .measure: "dot.radiowaves.left.and.right"
        case .stair: "figure.stairs"
        case .zone: "square.dashed"
        }
    }

    /// Command-1 for Select, Command-2 for Walls … Command-0 for Zone.
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self)! + 1) % 10))) }

    /// The tools that put a thing on the plan, grouped in one menu.
    static let placing: [PlanTool] = [.outlet, .jack, .accessPoint, .entry]
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
    @State private var status: SuiMessage?
    @State private var bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
    @State private var detent = PresentationDetent.height(220)
    @State private var zoneForm = false
    @State private var wallMaterial = "drywall"
    @State private var wallThickness = "0.1"
    @State private var openingKind = "door"
    @State private var snapNote = ""
    @State private var numbersForm = false
    @State private var stairForm = false
    @State private var placeForm = false
    @State private var drawingTool = PlanTool.wall   // what the Pencil's double tap goes back to
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var drag: (handle: PlanHandle, at: Pt)?   // a handle being dragged, and where it is now
    @State private var coreWalls: [HomemeshCore.Wall] = []   // for snapping while dragging
    @State private var gapForm = false

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

    /// On a wide screen (iPad) the inspector sits beside the plan instead of covering it.
    private var sidePanel: Bool { sizeClass == .regular }

    var body: some View {
        HStack(spacing: 0) {
        VStack(spacing: 8) {
            if let plan {
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
                if tool == .wall { wallBar }
                if tool == .opening {
                    HStack {
                        Picker("Kind", selection: $openingKind) { Text("Door").tag("door"); Text("Window").tag("window"); Text("Open doorway").tag("arch") }.pickerStyle(.segmented)
                    }.padding(.horizontal)
                }
                PlanCanvas(walls: shownWalls(plan), rooms: plan.rooms.filter { $0.level == level },
                           bounds: bounds, selected: selectedWall, markers: markers, stairs: stairsHere.map(\.polygon), stairLayouts: stairsHere.compactMap { stairLayout($0, plan) }, draft: draft,
                           selectedMarker: selectedMarker?.id, zones: shownZones(plan), selectedZone: selectedZone,
                           furniture: plan.furniture.filter { $0.level == level }, selectedFurniture: selectedFurniture, onTapPlan: { p, tol in tap(p, tol: tol, plan: plan) },
                           handles: tool == .select ? handles(plan) : [], onHandleDrag: { h, p, done, tol in dragHandle(h, p, done, tol: tol, plan: plan) })
                    .background(Color(.secondarySystemBackground))
                    .accessibilityAction(named: "Add a zone from rooms, walls or corners") { zoneForm = true }
                    .accessibilityAction(named: "Add a staircase by floors and room") { stairForm = true }
                    .accessibilityAction(named: "Add an outlet, jack or access point by room") { placeForm = true }
                if tool == .select { chooser(plan) }
                hint
            } else {
                ProgressView()
            }
        }
        sidePanelView
        }
        .onChange(of: tool) { draft = []; clearSelection(); if tool != .select { drawingTool = tool } }
        .onPencilDoubleTap { _ in tool = tool == .select ? drawingTool : .select }
        .background { shortcuts }
        .suiMessage(Binding(get: { inspecting && !sidePanel ? nil : status }, set: { status = $0 }), undo: { Task { await undo() } })
        .sheet(isPresented: Binding(get: { inspecting && !sidePanel }, set: { if !$0 { clearSelection() } })) {
            if let plan {
                NavigationStack {
                    inspector(plan)
                        .navigationTitle(inspectorTitle(plan))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { clearSelection() } } }
                }
                .suiMessage($status)
                .presentationDetents([.height(220), .medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))   // the plan stays tappable above the sheet
            }
        }
        .navigationTitle(plan?.levels.first { $0.id == level }?.name ?? "Plan")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                toolButton(.select)
                toolButton(.wall)
                toolButton(.opening)
                Menu {
                    ForEach(PlanTool.placing) { t in
                        Button { tool = t } label: { Label(t.rawValue, systemImage: t.symbol) }.keyboardShortcut(t.shortcut, modifiers: .command)
                    }
                } label: {
                    Label(PlanTool.placing.contains(tool) ? tool.rawValue : "Put on the plan", systemImage: PlanTool.placing.contains(tool) ? tool.symbol : "mappin.and.ellipse")
                        .symbolVariant(PlanTool.placing.contains(tool) ? .fill : .none)
                }
                toolButton(.measure)
                toolButton(.stair)
                toolButton(.zone)
                Menu {
                    Button { fix { WallOps.squareUp($0, level: level).0 } } label: { Label("Square up the walls", systemImage: "square.dashed.inset.filled") }
                    Button { fix { WallOps.closeGaps($0, level: level).0 } } label: { Label("Close small gaps between walls", systemImage: "link") }
                    Button { gapForm = true } label: { Label("Fill a gap with walls…", systemImage: "square.dashed") }
                } label: { Label("Fix", systemImage: "wand.and.stars") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { zoneForm = true } label: { Label("Zone from rooms, walls or corners", systemImage: "square.dashed") }
                    Button { stairForm = true } label: { Label("Staircase by floors and room", systemImage: "figure.stairs") }
                    Button { placeForm = true } label: { Label("Outlet, jack or access point by room", systemImage: "mappin.and.ellipse") }
                } label: { Label("Add without drawing", systemImage: "list.bullet.rectangle") }
                    .accessibilityHint("Adds a zone, a staircase, an outlet, a jack or an access point from lists and fields, without touching the plan")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await undo() } }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(undoTarget == nil)
                    .accessibilityHint("Goes back to the plan as it was before the last change")
            }
        }
        .sheet(isPresented: $numbersForm) {
            NumbersSheet(start: draft.last) { pts, closed in draft = pts; finishWalls(closed: closed) }
        }
        .sheet(isPresented: $zoneForm) {
            if let plan {
                ZoneFormSheet(rooms: plan.rooms.filter { $0.level == level }, walls: plan.walls.filter { $0.level == level }) { kind, poly in makeZone(kind: kind, polygon: poly) }
            }
        }
        .sheet(isPresented: $stairForm) {
            if let plan {
                StairFormSheet(levels: plan.levels, here: level, rooms: plan.rooms.filter { $0.level == level }) { target, bottom, top, width in
                    makeStair(target: target, bottom: bottom, top: top, width: width, plan: plan)
                }
            }
        }
        .sheet(isPresented: $placeForm) {
            if let plan {
                PlaceThingSheet(rooms: plan.rooms.filter { $0.level == level }) { thing, p in
                    switch thing {
                    case .outlet: putThing(.outlet, at: p)
                    case .jack: putThing(.jack, at: p)
                    case .accessPoint: putThing(.accessPoint, at: p)
                    }
                }
            }
        }
        .sheet(isPresented: $gapForm) {
            if let plan {
                FillGapSheet(walls: plan.walls.filter { $0.level == level }, preview: gapPreview, onMake: fillGap)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var sidePanelView: some View {
        if sidePanel, inspecting, let plan {
            Divider()
            NavigationStack {
                inspector(plan)
                    .navigationTitle(inspectorTitle(plan))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { clearSelection() } } }
            }
            .suiMessage($status)
            .frame(width: 360)
        }
    }

    /// Keyboard shortcuts (an iPad with a keyboard): the tools on Command-1 to Command-0, Escape to let go, Command-Delete for the selected wall.
    private var shortcuts: some View {
        Group {
            Button("Let go") { draft = []; clearSelection() }.keyboardShortcut(.cancelAction)
            Button("Delete the selected wall") {
                if let id = selectedWall { edit { WallOps.delete($0, walls: [id]) }; clearSelection() }
            }.keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    /// Everything on this floor that can be selected, as a list: the alternative to tapping the drawing.
    private func chooser(_ plan: PlanHouse) -> some View {
        Menu("Choose from a list") {
            Menu("Walls") {
                ForEach(plan.walls.filter { $0.level == level }) { w in
                    Button(String(format: "Wall %@, %.1f m", w.id, w.length)) { clearSelection(); selectedWall = w.id }
                }
            }
            Menu("Zones") {
                ForEach(plan.zones.filter { $0.level == level }) { z in
                    Button(z.name.isEmpty ? "Zone \(z.id), \(z.kind)" : z.name) { clearSelection(); selectedZone = z.id }
                }
            }
            Menu("Staircases") {
                ForEach(stairsHere) { s in
                    Button("Staircase \(s.id)") { clearSelection(); selectedStair = s.id }
                }
            }
            Menu("Furniture") {
                ForEach(plan.furniture.filter { $0.level == level }) { f in
                    Button(f.title) { clearSelection(); selectedFurniture = f.id }
                }
            }
            Menu("Outlets, jacks, access points and readings") {
                ForEach(markers) { m in
                    Button("\(PlanScreen.markerTitle(m.kind)) \(m.id)") { clearSelection(); selectedMarker = m }
                }
            }
        }
        .font(.footnote)
    }

    private func toolButton(_ t: PlanTool) -> some View {
        Button { tool = t } label: { Label(t.rawValue, systemImage: t.symbol).symbolVariant(tool == t ? .fill : .none) }
            .accessibilityAddTraits(tool == t ? .isSelected : [])
            .keyboardShortcut(t.shortcut, modifiers: .command)
    }

    private var inspecting: Bool {
        selectedWall != nil || selectedMarker != nil || selectedStair != nil || selectedZone != nil || selectedFurniture != nil
    }

    private func clearSelection() { selectedWall = nil; selectedMarker = nil; selectedStair = nil; selectedZone = nil; selectedFurniture = nil }

    private func inspectorTitle(_ plan: PlanHouse) -> String {
        if let id = selectedWall { return "Wall \(id)" }
        if let m = selectedMarker { return PlanScreen.markerTitle(m.kind) }
        if selectedStair != nil { return "Staircase" }
        if selectedFurniture != nil { return "Furniture" }
        if selectedZone != nil { return "Zone" }
        return ""
    }

    private static func markerTitle(_ k: PlanMarker.Kind) -> String {
        switch k {
        case .outlet: "Outlet"
        case .jack: "Jack"
        case .accessPoint: "Access point"
        case .entry: "Internet"
        case .measurement: "Reading"
        default: "Marker"
        }
    }

    /// What to do next, under the plan.
    @ViewBuilder
    private var hint: some View {
        if tool == .select {
            Text("Tap a wall, a thing, a piece of furniture, a staircase or a zone.").font(.footnote).foregroundStyle(.secondary)
        } else if tool == .opening {
            Text("Tap a wall to put a \(openingKind == "arch" ? "doorway" : openingKind) there.").font(.footnote).foregroundStyle(.secondary)
        } else if tool != .stair && tool != .zone && tool != .wall {
            Text("Tap the plan to put the \(tool.rawValue.lowercased()) there.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inspector(_ plan: PlanHouse) -> some View {
        if let doc {
            if let id = selectedWall, let wall = plan.walls.first(where: { $0.id == id }) {
                WallInspector(houseId: houseId, wall: wall, doc: doc, level: level, onSaved: { new in Task { await save(new) } }, status: $status,
                              onMoveEnd: { end, x, y in edit { WallOps.moveEndpoint($0, wall: wall.id, end: end, to: Vec2(x, y)) } },
                              onSlide: { k, start in edit { WallOps.slideOpening($0, wall: wall.id, index: k, to: start + (wall.openings.indices.contains(k) ? wall.openings[k].width / 2 : 0)) } })
            } else if let m = selectedMarker {
                MarkerInspector(marker: m, doc: doc, rooms: plan.rooms.filter { $0.level == level }, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedMarker = nil })
            } else if let id = selectedStair, let st = plan.stairs.first(where: { $0.id == id }) {
                StairInspector(stair: st, doc: doc, here: level, rise: plan.levels.first { $0.id == st.from_level }.flatMap { a in plan.levels.first { $0.id == st.to_level }.map { abs($0.elevation - a.elevation) } }, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedStair = nil })
            } else if let id = selectedFurniture, let f = plan.furniture.first(where: { $0.id == id }) {
                FurnitureInspector(item: f, doc: doc, onSaved: { new in Task { await save(new) } }, onClose: { selectedFurniture = nil })
            } else if let id = selectedZone, let z = plan.zones.first(where: { $0.id == id }) {
                ZoneInspector(zone: z, doc: doc, levels: plan.levels.filter { $0.id != level }, onSaved: { new in Task { await save(new) } }, onRemoved: { selectedZone = nil }, onCopy: { duplicateZone(z.id, to: $0) })
            }
        }
    }

    private func tap(_ p: Pt, tol: Double, plan: PlanHouse) {
        guard var d = doc else { return }
        switch tool {
        case .select:
            clearSelection()
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
        case .wall: tapWall(p, tol: tol)
        case .opening: addOpening(at: p, tol: tol, plan: plan)
        case .outlet, .jack, .accessPoint: putThing(tool, at: p)
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
            guard draft.count == 2, !stairTarget.isEmpty else { if stairTarget.isEmpty { status = .warning("Choose the floor it leads to first."); draft = [] }; return }
            makeStair(target: stairTarget, bottom: draft[0], top: draft[1], width: 1.0, plan: plan)
            draft = []
        }
    }

    /// An outlet, a jack or an access point at `p`, selected afterwards so its details can be filled in.
    private func putThing(_ kind: PlanTool, at p: Pt) {
        guard var d = doc else { return }
        switch kind {
        case .outlet:
            let id = d.add("outlets", prefix: "o", ["position": [p.x, p.y], "level": level, "z": 0.3])
            selectedMarker = PlanMarker(id: id, kind: .outlet, at: p)
        case .jack:
            let id = d.add("jacks", prefix: "j", ["position": [p.x, p.y], "level": level, "z": 0.3, "type": "cat6", "state": "unknown", "poe": false])
            selectedMarker = PlanMarker(id: id, kind: .jack, at: p)
        default:
            let id = d.add("access_points", prefix: "ap", ["position": [p.x, p.y], "level": level, "name": "Access point", "height": 1.5])
            selectedMarker = PlanMarker(id: id, kind: .accessPoint, at: p)
        }
        Task { await save(d) }
    }

    /// What filling a gap round these walls would add: the closing walls and the area they enclose.
    private func gapPreview(_ ids: Set<String>) -> (closing: Int, area: Double)? {
        guard let d = doc, let core = try? d.core(), let r = WallOps.fillGap(core, walls: ids) else { return nil }
        return (r.closing.count, Geometry.area(r.outline.map { Pt($0.x, $0.y) }))
    }

    /// Adds the walls that close the gap, with fresh ids, at the height and thickness of the walls they join.
    private func fillGap(_ ids: Set<String>) {
        edit { h in
            guard let r = WallOps.fillGap(h, walls: ids), !r.closing.isEmpty else { return nil }
            var taken = Set(h.walls.map(\.id))
            var n = h.walls.count
            var out = h
            for var w in r.closing {
                repeat { n += 1 } while taken.contains("w\(n)")
                w.id = "w\(n)"
                taken.insert(w.id)
                out.walls.append(w)
            }
            return out
        }
    }

    /// A copy of a zone on another floor.
    private func duplicateZone(_ id: String, to target: String) {
        guard let d = doc, let core = try? d.core(), let (new, nid) = ZoneOps.duplicate(core, zone: id, to: target) else { return }
        _ = nid
        commit(new)
        status = .success("Copied to \(plan?.levels.first { $0.id == target }?.name ?? target).")
    }

    // MARK: dragging handles

    /// The walls of this floor as drawn, the dragged end where the finger has it.
    private func shownWalls(_ plan: PlanHouse) -> [PlanWall] {
        let here = plan.walls.filter { $0.level == level }
        guard let d = drag, case .wallEnd(let w, let end) = d.handle.kind else { return here }
        return here.map { $0.id == w ? PlanHandles.moved($0, end: end, to: d.at) : $0 }
    }

    private func shownZones(_ plan: PlanHouse) -> [PlanZone] {
        let here = plan.zones.filter { $0.level == level }
        guard let d = drag, case .zoneCorner(let z, let i) = d.handle.kind else { return here }
        return here.map { $0.id == z ? PlanHandles.moved($0, corner: i, to: d.at) : $0 }
    }

    /// The grab points of the selected wall or zone.
    private func handles(_ plan: PlanHouse) -> [PlanHandle] {
        var out: [PlanHandle] = []
        if let id = selectedWall, let w = shownWalls(plan).first(where: { $0.id == id }) { out = PlanHandles.forWall(w) }
        else if let id = selectedZone, let z = shownZones(plan).first(where: { $0.id == id }) { out = PlanHandles.forZone(z) }
        guard let d = drag else { return out }
        return out.map { $0.id == d.handle.id ? PlanHandle(kind: $0.kind, at: d.at) : $0 }
    }

    private func dragHandle(_ h: PlanHandle, _ p: Pt, _ done: Bool, tol: Double, plan: PlanHouse) {
        var target = p
        switch h.kind {
        case .wallEnd(let w, let end):
            if let wall = coreWalls.first(where: { $0.id == w }) {
                let r = Snap.resolve(Vec2(p.x, p.y), walls: coreWalls.filter { $0.level == level && $0.id != w }, tolerance: tol, from: end == 0 ? wall.b : wall.a)
                target = Pt(r.point.x, r.point.y)
                snapNote = r.label
            }
        case .openingMove(let w, _), .openingEdge(let w, _, _):
            if let pw = plan.walls.first(where: { $0.id == w }) { target = PlanHandles.point(on: pw, at: PlanHandles.along(pw, p)) }
        case .zoneCorner: break
        }
        if !done { drag = (h, target); return }
        drag = nil
        snapNote = ""
        commit(h, to: target, plan: plan)
    }

    private func commit(_ h: PlanHandle, to t: Pt, plan: PlanHouse) {
        let v = Vec2(t.x, t.y)
        switch h.kind {
        case .wallEnd(let w, let end):
            edit { WallOps.moveEndpoint($0, wall: w, end: end, to: v) }
        case .zoneCorner(let z, let i):
            edit { ZoneOps.moveVertex($0, zone: z, vertex: i, to: v) }
        case .openingMove(let w, let k):
            guard let pw = plan.walls.first(where: { $0.id == w }) else { return }
            edit { WallOps.slideOpening($0, wall: w, index: k, to: PlanHandles.along(pw, t)) }
        case .openingEdge(let w, let k, let far):
            guard let pw = plan.walls.first(where: { $0.id == w }), pw.openings.indices.contains(k) else { return }
            let o = pw.openings[k], s = PlanHandles.along(pw, t)
            let width = far ? s - o.offset : o.offset + o.width - s            // the other edge stays where it is
            let centre = far ? o.offset + width / 2 : o.offset + o.width - width / 2
            edit { house in WallOps.resizeOpening(house, wall: w, index: k, width: width).flatMap { WallOps.slideOpening($0, wall: w, index: k, to: centre) } }
        }
    }

    private func finishZone(_ plan: PlanHouse) {
        makeZone(kind: zoneKind, polygon: draft)
        draft = []
    }

    // MARK: editing walls and openings with the on-device engine

    /// Runs an operation of the engine on the house as the screen has it and saves the result as the next revision.
    private func edit(_ change: (HomemeshCore.House) -> HomemeshCore.House?) {
        guard let d = doc, let core = try? d.core() else { return }
        guard let new = change(core) else { status = .warning("That change does not fit there."); return }
        commit(new)
    }

    private func commit(_ new: HomemeshCore.House) {
        guard let nd = try? HouseDoc(core: new) else { return }
        Task { await save(nd) }
    }

    private func tapWall(_ p: Pt, tol: Double) {
        guard let d = doc, let core = try? d.core() else { return }
        let r = Snap.resolve(Vec2(p.x, p.y), walls: core.walls.filter { $0.level == level }, tolerance: tol, from: draft.last.map { Vec2($0.x, $0.y) })
        snapNote = r.label
        let q = Pt(r.point.x, r.point.y)
        if draft.count >= 3, hypot(p.x - draft[0].x, p.y - draft[0].y) <= tol { finishWalls(closed: true); return }
        if let last = draft.last, hypot(q.x - last.x, q.y - last.y) < 0.02 { return }
        draft.append(q)
    }

    /// The traced corners become walls with the chosen material and thickness, at the floor's height.
    private func finishWalls(closed: Bool) {
        let pts = draft.map { Vec2($0.x, $0.y) }
        let t = Double(wallThickness.replacingOccurrences(of: ",", with: ".")) ?? 0.1
        draft = []
        snapNote = ""
        guard pts.count >= 2 else { return }
        edit { h in
            let height = h.levels.first { $0.id == level }?.height ?? 2.5
            var taken = Set(h.walls.map(\.id))
            var n = h.walls.count
            let walls = Draw.trace(points: pts, closed: closed, level: level, material: wallMaterial, thickness: t > 0 ? t : 0.1, height: height) {
                repeat { n += 1 } while taken.contains("w\(n)")
                taken.insert("w\(n)")
                return "w\(n)"
            }
            if walls.isEmpty { return nil }
            var out = h
            out.walls += walls
            return out
        }
    }

    private func addOpening(at p: Pt, tol: Double, plan: PlanHouse) {
        guard let id = nearestWall(p, tol: tol, plan: plan), let w = plan.walls.first(where: { $0.id == id }), let d = doc, let core = try? d.core() else {
            status = .warning("Tap a wall to put it on.")
            return
        }
        let (_, t) = Snap.project(Vec2(p.x, p.y), Vec2(w.a.x, w.a.y), Vec2(w.b.x, w.b.y))
        guard let (new, _) = WallOps.addOpening(core, wall: id, kind: openingKind, along: t * w.length) else { status = .warning("There is no room for it there."); return }
        commit(new)
        selectedWall = id
    }

    private func fix(_ change: @escaping (HomemeshCore.House) -> HomemeshCore.House) {
        guard let d = doc, let core = try? d.core() else { return }
        let new = change(core)
        if new.walls == core.walls { status = .info("Nothing to fix."); return }
        commit(new)
    }

    private var wallBar: some View {
        let mats = doc?.materials ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Material", selection: $wallMaterial) { ForEach(mats.indices, id: \.self) { Text(mats[$0].name).tag(mats[$0].id) } }.pickerStyle(.menu)
                TextField("Thickness (m)", text: $wallThickness).keyboardType(.decimalPad).frame(width: 110).textFieldStyle(.roundedBorder)
                Spacer()
                Button("By numbers…") { numbersForm = true }
            }
            HStack {
                Text(draft.isEmpty ? "Tap where the first corner goes. It snaps to corners, walls and right angles."
                     : "\(draft.count) corner(s)\(snapNote.isEmpty ? "" : " · \(snapNote)"). Tap the first corner to close.").font(.footnote)
                Spacer()
                Button("Undo corner") { draft.removeLast() }.disabled(draft.isEmpty)
                Button("Done") { finishWalls(closed: false) }.disabled(draft.count < 2)
            }.font(.footnote)
        }.padding(.horizontal)
    }

    /// A zone from a drawn outline or from the form.
    private func makeZone(kind: String, polygon: [Pt]) {
        guard var d = doc, !polygon.isEmpty else { return }
        var zone: [String: Any] = ["level": level, "polygon": polygon.map { [$0.x, $0.y] }, "kind": kind, "name": ""]
        switch kind {
        case "demand": zone["weight"] = 1.0; zone["need"] = ["min_rssi": -65.0, "must": false, "rx_height": 1.0]
        case "allow": zone["requires"] = "none"
        default: break
        }
        let id = d.add("zones", prefix: "z", zone)
        selectedZone = id
        Task { await save(d) }
    }

    /// A staircase from two tapped points or from the form: the lower floor is the start of the flight.
    private func makeStair(target: String, bottom: Pt, top: Pt, width: Double, plan: PlanHouse) {
        guard var d = doc else { return }
        let ev = Dictionary(uniqueKeysWithValues: plan.levels.map { ($0.id, $0.elevation) })
        let up = (ev[target] ?? 0) > (ev[level] ?? 0)
        let id = d.add("stairs", prefix: "s", ["from_level": up ? level : target, "to_level": up ? target : level,
                                               "polygon": Geometry.stairRectangle(bottom, top, width: width).map { [$0.x, $0.y] }, "void": true])
        selectedStair = id
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
            coreWalls = (try? doc?.core().walls) ?? []
            let p = try JSONDecoder().decode(PlanHouse.self, from: data)
            plan = p
            if stairTarget.isEmpty { stairTarget = p.levels.first { $0.id != level }?.id ?? "" }
            let pts = p.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] }
            bounds = Geometry.bounds(pts)
        } catch {
            status = .danger("Could not load the plan: \(error.localizedDescription)")
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
            clearSelection()
            status = .success("Back to the plan as it was at revision \(t).")
            await load()
        } catch {
            status = .danger("Could not undo: \(error.localizedDescription)")
        }
    }

    private func save(_ new: HouseDoc) async {
        undoCursor = nil
        do {
            try await model.client().saveHouse(house: houseId, json: try new.data(), expectRevision: new.revision)
            status = .success("Saved.", undoable: true)
            await load()
        } catch {
            status = .danger("Could not save: \(error.localizedDescription)")
        }
    }
}

/// Edit or delete an outlet, a jack or an access point.
struct MarkerInspector: View {
    let marker: PlanMarker
    let doc: HouseDoc
    var rooms: [PlanRoom] = []
    let onSaved: (HouseDoc) -> Void
    let onRemoved: () -> Void
    @State private var px = ""
    @State private var py = ""
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
        switch marker.kind { case .outlet: "outlets"; case .jack: "jacks"; case .accessPoint: "access_points"; case .entry: "entry"; case .measurement, .suggestion, .door, .planDoor: "measurements" }
    }

    var body: some View {
        Form {
            whereSection
            Section(title) {
                switch marker.kind {
                case .outlet:
                    field("Height above the floor (m)", $height)
                case .jack:
                    Picker("Type", selection: $type) { ForEach(["cat5e", "cat6", "cat6a", "coax_moca"], id: \.self) { Text($0).tag($0) } }
                    Picker("Works?", selection: $state) { ForEach(["live", "dead", "unknown"], id: \.self) { Text($0).tag($0) } }
                    Toggle("Power over Ethernet", isOn: $poe)
                    field("Height above the floor (m)", $height)
                case .measurement, .suggestion, .door, .planDoor:
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

    /// Where it is, in plan metres, and a list of rooms to move it into.
    @ViewBuilder
    private var whereSection: some View {
        Section("Where") {
            field("x (m)", $px)
            field("y (m)", $py)
            if !rooms.isEmpty {
                Menu("Move to the middle of a room") {
                    ForEach(rooms) { r in
                        Button(r.name.isEmpty ? r.id : r.name) {
                            if let c = Geometry.pointInRoom(r.polygon, side: nil, along: 0) { px = String(format: "%.2f", c.x); py = String(format: "%.2f", c.y) }
                        }
                    }
                }
            }
            Text("Press Save below to move it.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch marker.kind { case .outlet: "Outlet \(marker.id)"; case .jack: "Jack \(marker.id)"; case .accessPoint: "Access point \(marker.id)"; case .entry: "Where the internet comes in"; case .measurement, .suggestion, .door, .planDoor: "Measurement \(marker.id)" }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack { Text(label); TextField("", text: text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    private func load() {
        let it = (marker.kind == .entry ? doc.object("entry") : doc.item(collection, marker.id)) ?? [:]
        let pos = it["position"] as? [Double]
        px = pos.map { String(format: "%.2f", $0[0]) } ?? String(format: "%.2f", marker.at.x)
        py = pos.map { String(format: "%.2f", $0[1]) } ?? String(format: "%.2f", marker.at.y)
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
        let moved: [Double]? = num(px).flatMap { x in num(py).map { [x, $0] } }
        switch marker.kind {
        case .outlet: d.set(collection, marker.id, ["z": num(height) ?? 0.3, "position": moved])
        case .jack: d.set(collection, marker.id, ["type": type, "state": state, "poe": poe, "z": num(height) ?? 0.3, "position": moved])
        case .accessPoint: d.set(collection, marker.id, ["name": name, "height": num(height) ?? 1.5, "eirp_dbm": num(eirp) ?? 23, "position": moved])
        case .measurement, .suggestion, .door, .planDoor:
            d.set(collection, marker.id, ["band": band, "rssi": num(rssi), "throughput": num(rate), "device": device.trimmed.isEmpty ? "iPhone" : device.trimmed, "position": moved])
        case .entry:
            var e = doc.object("entry") ?? [:]
            e["kind"] = entryKind
            if let m = moved { e["position"] = m }
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
    @Binding var status: SuiMessage?
    var onMoveEnd: ((Int, Double, Double) -> Void)?   // end 0 or 1, new x and y in metres
    var onSlide: ((Int, Double) -> Void)?             // opening index, new start in metres from the first end
    @State private var ends = ["", "", "", ""]        // x and y of the first end, x and y of the second
    @State private var starts: [String] = []
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
                if doc.thicknessDefaulted(wall.id) { SuiNote(.warning, "The scan gave no thickness: this is a guess.") }
                Picker("Material", selection: $material) { ForEach(doc.materials, id: \.id) { Text($0.name).tag($0.id) } }
                Button("Save this wall") { apply(all: false) }
                Button("Use for every wall on this floor still on the defaults") { apply(all: true) }
            }
            if let onMoveEnd {
                Section("Ends, in plan metres") {
                    ForEach(0..<2, id: \.self) { e in
                        HStack {
                            Text(e == 0 ? "First" : "Second")
                            TextField("x", text: $ends[e * 2]).keyboardType(.numbersAndPunctuation).accessibilityLabel("\(e == 0 ? "First" : "Second") end, x")
                            TextField("y", text: $ends[e * 2 + 1]).keyboardType(.numbersAndPunctuation).accessibilityLabel("\(e == 0 ? "First" : "Second") end, y")
                            Button("Move") {
                                let n = ends[e * 2 ... e * 2 + 1].map { Double($0.replacingOccurrences(of: ",", with: ".")) }
                                if let x = n[0], let y = n[1] { onMoveEnd(e, x, y) } else { status = .warning("Give both numbers in metres.") }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
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
                        if let onSlide, starts.indices.contains(i) {
                            HStack {
                                TextField("starts (m from the first end)", text: $starts[i]).keyboardType(.decimalPad)
                                Button("Slide") {
                                    if let v = Double(starts[i].replacingOccurrences(of: ",", with: ".")) { onSlide(i, v) } else { status = .warning("Give the distance in metres.") }
                                }.buttonStyle(.borderless)
                            }.font(.footnote)
                        }
                    }
                }
            }
            MeasureCheckSection(houseId: houseId, wall: wall, level: level, doc: doc, onSaved: onSaved, status: $status)
        }
        .onAppear(perform: load)
        .onChange(of: wall) { load() }
    }

    private func load() {
        thickness = String(format: "%.3f", wall.thickness)
        material = doc.material(of: wall.id) ?? doc.materials.first?.id ?? ""
        let o = doc.openings(of: wall.id)
        kinds = o.map(\.kind)
        widths = o.map { String(format: "%.2f", $0.width) }
        starts = wall.openings.map { String(format: "%.2f", $0.offset) }
        ends = [wall.a.x, wall.a.y, wall.b.x, wall.b.y].map { String(format: "%.2f", $0) }
    }

    private func apply(all: Bool) {
        var d = doc
        let t = Double(thickness.replacingOccurrences(of: ",", with: "."))
        if all {
            let n = d.applyToDefaults(level: level, thickness: t, material: material)
            status = .success("\(n) wall(s) updated.")
        } else {
            d.update(wall: wall.id, thickness: t, material: material)
        }
        onSaved(d)
    }

    private func saveOpening(_ i: Int) {
        var d = doc
        guard let w = Double(widths[i].replacingOccurrences(of: ",", with: ".")), w > 0 else { status = .warning("Give the width in metres."); return }
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
