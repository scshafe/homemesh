import RoomPlan
import SwiftUI

/// The two floors of a staircase scan (lower, upper).
struct StairPair: Hashable, Sendable {
    let from: String
    let to: String
}

/// Which floor a staircase leads to, from the floor it is found on and how far it rises.
enum StairGuess {
    /// The other floor whose elevation differs from `from`'s by about `rise`; without a rise or elevations, the floor
    /// above (else below) in the stack.
    static func otherFloor(levels: [LevelRef], from: String, rise: Double?) -> String? {
        guard let here = levels.first(where: { $0.id == from }) else { return nil }
        let others = levels.filter { $0.id != from }
        if let rise, let e = here.elevation {
            let scored = others.compactMap { o in o.elevation.map { (o.id, abs(abs($0 - e) - rise)) } }
            if let best = scored.min(by: { $0.1 < $1.1 }) { return best.0 }
        }
        guard let i = levels.firstIndex(where: { $0.id == from }) else { return nil }
        return i + 1 < levels.count ? levels[i + 1].id : (i > 0 ? levels[i - 1].id : nil)
    }
}

/// What RoomPlan found in captured rooms, for the save sheet: "8 walls, 2 doors, 1 window. Staircase found: rises 3.3 m".
enum ScanFindings {
    nonisolated static func summary(_ rooms: [CapturedRoom]) -> String {
        func n(_ count: Int, _ one: String) -> String? { count == 0 ? nil : "\(count) \(one)\(count == 1 ? "" : "s")" }
        let parts = [n(rooms.reduce(0) { $0 + $1.walls.count }, "wall"), n(rooms.reduce(0) { $0 + $1.doors.count }, "door"),
                     n(rooms.reduce(0) { $0 + $1.windows.count }, "window"), n(rooms.reduce(0) { $0 + $1.openings.count }, "opening")]
        return "RoomPlan found " + (parts.compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "nothing") + "."
    }

    /// Rise (metres) of each staircase object RoomPlan found.
    nonisolated static func stairRises(_ rooms: [CapturedRoom]) -> [Double] {
        rooms.flatMap { $0.objects }.filter { $0.category == .stairs }.map { Double($0.dimensions.y) }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// "This floor" and "leads to" for a staircase: the question asked in the save sheet, in the Staircases list and when
/// a staircase is scanned on its own. `to == ""` means "not a staircase".
struct StairFloorPickers: View {
    let levels: [LevelRef]
    let from: String
    @Binding var to: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Joins \(levels.first { $0.id == from }?.name ?? "this floor") and:").font(.footnote.weight(.semibold))
            Picker("Leads to", selection: $to) {
                Text("Not a staircase").tag("")
                ForEach(levels.filter { $0.id != from }.reversed()) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// A staircase found in an already uploaded scan whose floors were never given: ask now, store on the scan.
struct StairFloorsSheet: View {
    let houseId: String
    let capture: CaptureMeta
    let levels: [LevelRef]
    let onSaved: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""
    @State private var status = ""

    private var rise: Double? { capture.stairs_found?.first?.rise }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let r = rise { Text("RoomPlan found a staircase in \"\(capture.name)\": it rises \(String(format: "%.1f", r)) m.") }
                    Picker("This scan's floor", selection: $from) { ForEach(levels.reversed()) { Text($0.name).tag($0.id) } }
                    StairFloorPickers(levels: levels, from: from, to: $to)
                    if !status.isEmpty { Text(status).font(.footnote) }
                }
            }
            .navigationTitle("Staircase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
            .onAppear {
                from = capture.level.flatMap { l in levels.contains { $0.id == l } ? l : nil } ?? levels.first?.id ?? ""
                to = StairGuess.otherFloor(levels: levels, from: from, rise: rise) ?? ""
            }
            .onChange(of: from) { _, f in to = StairGuess.otherFloor(levels: levels, from: f, rise: rise) ?? "" }
        }
    }

    private func save() async {
        do {
            _ = try await model.client().setCaptureStair(house: houseId, blob: capture.blob, from: to.isEmpty ? nil : from, to: to.isEmpty ? nil : to)
            onSaved()
            dismiss()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Pick the two floors first, then scan the stairs (a scan made for a staircase, not a room).
struct ScanStaircaseSheet: View {
    let levels: [LevelRef]
    let onStart: (_ from: String, _ to: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Lower floor", selection: $from) { ForEach(levels) { Text($0.name).tag($0.id) } }
                    Picker("Upper floor", selection: $to) { ForEach(levels.filter { $0.id != from }) { Text($0.name).tag($0.id) } }
                    Text("Then scan the staircase from the bottom up, with the walls beside it in view. It is saved as a staircase, not a room, and lines the two floors up.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scan a staircase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Scan") { dismiss(); onStart(from, to) }.disabled(from.isEmpty || to.isEmpty || from == to) }
            }
            .onAppear {
                from = levels.first?.id ?? ""
                to = levels.dropFirst().first?.id ?? ""
            }
            .onChange(of: from) { _, f in if to == f || to.isEmpty { to = levels.first { $0.id != f }?.id ?? "" } }
        }
    }
}


/// A RoomPlan session can span stories (the owner walks up the stairs mid-scan); each room carries RoomPlan's `story`.
/// The lowest story goes on the chosen floor, the next on the floor above it in the stack, and so on (clamped to the top).
enum StoryFloors {
    nonisolated static func stories(_ rooms: [CapturedRoom]) -> [Int] { Array(Set(rooms.map(\.story))).sorted() }

    nonisolated static func defaults(stories: [Int], base: String, levels: [LevelRef]) -> [Int: String] {
        guard let lo = stories.min(), let i = levels.firstIndex(where: { $0.id == base }) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stories.map { ($0, levels[min(levels.count - 1, i + ($0 - lo))].id) })
    }
}
