import SwiftUI

/// Put a scan on the plan: the server proposes a placement (doorways, room names), the owner drags and turns the
/// red scan until it sits right, and Accept imports it at that placement and saves the house.
struct PlaceView: View {
    let houseId: String
    let capture: CaptureMeta
    @EnvironmentObject var model: AppModel
    @State private var house: PlanHouse?
    @State private var level = ""
    @State private var placement: Placement?
    @State private var base: [Seg] = []
    @State private var centre = Pt(0, 0)
    @State private var bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
    @State private var dragged = Pt(0, 0)      // total shift so far
    @State private var live = Pt(0, 0)         // shift of the gesture in progress
    @State private var delta = 0.0             // extra turn, degrees
    @State private var status = ""
    @State private var busy = false
    @State private var done = false
    @State private var stairs: [StairSuggestion] = []
    @State private var stairTarget = ""
    @State private var proposing = false
    @State private var proposalRun = 0         // the newest proposal wins; an older answer arriving late is dropped

    private var shift: Pt { Pt(dragged.x + live.x, dragged.y + live.y) }
    private var ghost: [Seg] { Geometry.adjust(base, centre: centre, delta: delta, d: shift) }

    var body: some View {
        VStack(spacing: 8) {
            if let house {
                Picker("Level", selection: Binding(get: { level }, set: { level = $0; Task { await propose() } })) {   // only the owner's change proposes
                    ForEach(house.levels, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                PlanCanvas(walls: house.walls.filter { $0.level == level && !$0.isFromCapture(capture.blob) },
                           rooms: house.rooms.filter { $0.level == level },
                           ghost: ghost, bounds: bounds,
                           onDrag: { live = $0 }, onDragEnd: { dragged = shift; live = Pt(0, 0) })
                    .background(Color(.secondarySystemBackground))
                if proposing {
                    HStack(spacing: 8) { ProgressView(); Text("Finding where it fits…").font(.footnote) }
                }
                if let p = placement {
                    Text("\(p.confidence.uppercased()): \(p.reason)").font(.footnote).foregroundStyle(p.confidence == "auto" ? .green : .orange)
                }
                HStack {
                    Button("-90°") { delta -= 90 }
                    Button("-1°") { delta -= 1 }
                    Text(String(format: "%+.0f°", delta)).monospacedDigit().frame(minWidth: 50)
                    Button("+1°") { delta += 1 }
                    Button("+90°") { delta += 90 }
                }.buttonStyle(.bordered)
                HStack {
                    Button("Reset to proposal") { dragged = Pt(0, 0); live = Pt(0, 0); delta = 0 }
                    Spacer()
                    Button(done ? "Placed" : "Accept") { Task { await accept() } }
                        .buttonStyle(.borderedProminent).disabled(busy || done || placement == nil)
                }
            } else {
                ProgressView()
            }
            if let found = stairs.first, let house {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A staircase was found in this scan (\(String(format: "%.1f", found.rise)) m tall). Which floor does it lead to?").font(.footnote)
                    Picker("Leads to", selection: $stairTarget) {
                        ForEach(house.levels.filter { $0.id != found.level }, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("Save the staircase") { Task { await saveStair(found, house: house) } }.buttonStyle(.borderedProminent)
                        Button("Not a staircase") { stairs.removeFirst() }
                    }
                }.padding(8).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .padding()
        .navigationTitle(capture.name.isEmpty ? "Place scan" : capture.name)
        .task { await load() }
    }

    private func load() async {
        do {
            let h: PlanHouse = try await model.client().get("/api/houses/\(houseId)")
            house = h
            level = h.levels.first { $0.id == capture.level }?.id ?? h.levels.first?.id ?? ""
            await propose()
        } catch {
            status = "Could not load the plan: \(error.localizedDescription)"
        }
    }

    /// Asks the server where the scan fits. One request at a time (the newest wins); if the server fails or takes more than
    /// ten seconds, the scan is put in the middle of the floor's walls as a manual placement so it can always be dragged,
    /// turned and accepted. Every outcome goes to the event log.
    private func propose() async {
        guard let house, !level.isEmpty else { return }
        proposalRun += 1
        let run = proposalRun
        proposing = true
        placement = nil
        let started = Date()
        let lvl = level, blob = capture.blob
        let client = model.client()
        let request = Task { () -> Placement in
            try await client.send("POST", "/api/houses/\(houseId)/captures/\(blob)/place?level=\(lvl)", [String: String]())
        }
        let timer = Task { try? await Task.sleep(for: .seconds(10)); request.cancel() }
        defer { timer.cancel() }
        do {
            let p = try await request.value
            guard run == proposalRun else { return }
            Diagnostics.event("place", ["capture": String(blob.prefix(8)), "level": lvl, "ms": Int(Date().timeIntervalSince(started) * 1000), "outcome": p.confidence])
            apply(p, house: house)
            status = ""
        } catch {
            guard run == proposalRun else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let slow = ms >= 9_500
            Diagnostics.event("place", ["capture": String(blob.prefix(8)), "level": lvl, "ms": ms, "outcome": slow ? "timeout" : "error",
                                        "error": (error as NSError).domain + " " + String((error as NSError).code)])
            status = slow ? "Finding the place took too long, so the scan is in the middle of the floor: drag and turn it into place."
                          : "Could not work out where it fits (\(error.localizedDescription)): the scan is in the middle of the floor; drag and turn it into place."
            await manualPlacement(house: house, level: lvl, blob: blob)
        }
        if run == proposalRun { proposing = false }
    }

    private func apply(_ p: Placement, house: PlanHouse) {
        placement = p
        base = p.preview
        centre = Geometry.centroid(p.preview)
        dragged = Pt(0, 0); live = Pt(0, 0); delta = 0
        let pts = house.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] } + p.preview.flatMap { [$0.a, $0.b] }
        bounds = Geometry.bounds(pts)
    }

    /// The scan's own walls (imported with no movement) shifted so their centre sits at the centre of the floor's walls.
    private func manualPlacement(house: PlanHouse, level: String, blob: String) async {
        do {
            let r = try await model.client().importScan(house: houseId, blob: blob, level: level, transform: Transform2D(rotation: 0, tx: 0, ty: 0))
            let plan = try JSONDecoder().decode(PlanHouse.self, from: r.house)
            let mine = plan.walls.filter { $0.level == level && $0.isFromCapture(blob) }.map { Seg(a: $0.a, b: $0.b) }
            guard !mine.isEmpty else { return }
            let floorSegs = house.walls.filter { $0.level == level && !$0.isFromCapture(blob) }.map { Seg(a: $0.a, b: $0.b) }
            let floor = floorSegs.flatMap { [$0.a, $0.b] }
            let target = floorSegs.isEmpty ? Geometry.centroid(mine) : Geometry.centroid(floorSegs)
            let here = Geometry.centroid(mine)
            let p = Placement(confidence: "manual", reason: "placed by hand: drag and turn the scan into place", transform: Transform2D(rotation: 0, tx: 0, ty: 0),
                              alternatives: [], preview: mine)
            apply(p, house: house)
            dragged = Pt(target.x - here.x, target.y - here.y)   // starts at the floor's centre; Accept composes it into the transform
            let pts = floor + mine.flatMap { [$0.a, $0.b] }.map { Pt($0.x + dragged.x, $0.y + dragged.y) }
            bounds = Geometry.bounds(pts)
        } catch {
            status += " (The scan could not be shown either: \(error.localizedDescription).)"
            Diagnostics.event("place-fallback-failed", ["error": (error as NSError).domain + " " + String((error as NSError).code)])
        }
    }

    private func accept() async {
        guard let house, let p = placement else { return }
        busy = true
        defer { busy = false }
        do {
            let t = Geometry.compose(p.transform, centre: centre, delta: delta, d: shift)
            let result = try await model.client().importScan(house: houseId, blob: capture.blob, level: level, transform: t)
            try await model.client().saveHouse(house: houseId, json: result.house, expectRevision: house.revision)
            done = true
            stairs = capture.stair == nil ? result.stairs : []   // the floors were already given with the scan
            stairTarget = house.levels.first { $0.id != level }?.id ?? ""
            status = "Placed and saved. Walls and rooms are on the plan; set thickness and materials next." + (capture.stair != nil ? " The staircase is saved too." : "")
            await model.refresh()
        } catch {
            status = "Could not save the placement: \(error.localizedDescription)"
        }
    }

    /// The stair joins this floor to the chosen one: from the lower floor to the upper; the opening is on the upper floor.
    private func saveStair(_ found: StairSuggestion, house: PlanHouse) async {
        guard let here = house.levels.first(where: { $0.id == found.level }), let there = house.levels.first(where: { $0.id == stairTarget }) else { return }
        let up = there.elevation > here.elevation
        do {
            try await model.client().addStair(house: houseId, from: up ? here.id : there.id, to: up ? there.id : here.id, polygon: found.polygon)
            stairs.removeFirst()
            status = "Staircase saved: it joins \(here.name) and \(there.name)."
        } catch {
            status = "Could not save the staircase: \(error.localizedDescription)"
        }
    }
}
