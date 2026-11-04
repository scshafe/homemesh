import HomemeshCore
import SwiftUI

/// Walls from typed measurements: a start, then for each wall a direction and a length. For fixing a scanned wall or filling a gap with a tape
/// measure in hand, not for drawing a whole house.
struct NumbersSheet: View {
    struct Step: Identifiable { let id = UUID(); var heading = "East"; var angle = ""; var length = "" }

    var start: Pt?
    let onMake: (_ points: [Pt], _ closed: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var x = ""
    @State private var y = ""
    @State private var steps = [Step()]
    @State private var close = false

    private func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    private var heading: [(String, WallOps.Heading)] { [("East", .east), ("North", .north), ("West", .west), ("South", .south)] }

    var points: [Pt]? {
        guard let sx = number(x), let sy = number(y) else { return nil }
        var parts: [(heading: WallOps.Heading, length: Double)] = []
        for s in steps {
            guard let len = number(s.length), len > 0 else { continue }
            if s.heading == "Angle" { guard let a = number(s.angle) else { continue }; parts.append((.angle(a), len)) }
            else if let h = heading.first(where: { $0.0 == s.heading })?.1 { parts.append((h, len)) }
        }
        if parts.isEmpty { return nil }
        return WallOps.byNumbers(start: Vec2(sx, sy), steps: parts).map { Pt($0.x, $0.y) }
    }

    private var summary: String {
        guard let pts = points else { return "Enter a start and at least one length." }
        let gap = hypot(pts[pts.count - 1].x - pts[0].x, pts[pts.count - 1].y - pts[0].y)
        return "\(pts.count - 1) wall(s)." + (close ? (gap < 0.02 ? " The loop closes." : String(format: " The last wall ends %.2f m from the start: it will be joined by one more wall.", gap)) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Start, in plan metres") {
                    HStack {
                        TextField("x (m)", text: $x).keyboardType(.numbersAndPunctuation).accessibilityLabel("Start x in metres")
                        TextField("y (m)", text: $y).keyboardType(.numbersAndPunctuation).accessibilityLabel("Start y in metres")
                    }
                }
                Section {
                    ForEach($steps) { $s in
                        HStack {
                            Picker("Direction", selection: $s.heading) { ForEach(["East", "North", "West", "South", "Angle"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                            if s.heading == "Angle" { TextField("deg", text: $s.angle).keyboardType(.numbersAndPunctuation).frame(width: 56) }
                            TextField("length (m)", text: $s.length).keyboardType(.decimalPad)
                        }
                    }
                    .onDelete { steps.remove(atOffsets: $0); if steps.isEmpty { steps = [Step()] } }
                    Button("Add a wall", systemImage: "plus") { steps.append(Step()) }
                } header: { Text("Walls") } footer: { Text("East is to the right on the plan, north up. An angle is in degrees from east, counter-clockwise.") }
                Section { Toggle("Close the loop", isOn: $close) }
                Section { Text(summary).font(.footnote) }
            }
            .navigationTitle("Walls by numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { if let p = points { onMake(p, close); dismiss() } }.disabled(points == nil) }
            }
            .onAppear { if let s = start, x.isEmpty { x = String(format: "%.2f", s.x); y = String(format: "%.2f", s.y) } else if x.isEmpty { x = "0"; y = "0" } }
        }
    }
}
