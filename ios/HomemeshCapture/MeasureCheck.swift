import SwiftUI

/// Type what a tape says about this wall; the difference to the scan is kept with the house (accuracy check).
struct MeasureCheckSection: View {
    let houseId: String
    let wall: PlanWall
    let level: String
    let doc: HouseDoc
    let onSaved: (HouseDoc) -> Void
    @Binding var status: SuiMessage?
    @State private var what = ""
    @State private var tape = ""
    @State private var last: HouseDoc.Check?

    var body: some View {
        Section("Measure check") {
            Text("Scan says \(String(format: "%.3f", wall.length)) m.").font(.footnote)
            TextField("What you measured (for example Kitchen north wall)", text: $what)
            HStack {
                Text("Tape reading (m)")
                TextField("4.000", text: $tape).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button("Record") { record() }.disabled(what.trimmed.isEmpty || Double(tape.replacingOccurrences(of: ",", with: ".")) == nil)
            if let c = last {
                Text("Recorded: scan \(String(format: "%.3f", c.scanned)) m, tape \(String(format: "%.3f", c.measured)) m: \(String(format: "%+.1f", c.error * 100)) cm (\(String(format: "%+.1f", c.percent)) %).")
                    .font(.footnote)
            }
            let a = Accuracy(doc.checks)
            if a.count > 0 { NavigationLink("Accuracy so far (\(a.count) reading(s))") { AccuracyView(houseId: houseId) } }
        }
        .onAppear { if what.isEmpty { what = "Wall \(wall.id)" } }
        .onChange(of: wall.id) { what = "Wall \(wall.id)"; tape = ""; last = nil }
    }

    private func record() {
        guard let m = Double(tape.replacingOccurrences(of: ",", with: ".")) else { return }
        var d = doc
        last = d.addCheck(what: what, level: level, wall: wall.id, scanned: wall.length, measured: m)
        tape = ""
        status = .success("Reading recorded.")
        onSaved(d)
    }
}

/// The readings so far with the mean error, and whether it clears the bar for dropping blueprints.
struct AccuracyView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var doc: HouseDoc?
    @State private var note = ""

    var body: some View {
        List {
            if let doc {
                let a = Accuracy(doc.checks)
                Section("Summary") {
                    row("Readings", "\(a.count)")
                    row("Mean error", String(format: "%.1f %% (%.1f cm)", a.meanAbsPercent, a.meanAbsMetres * 100))
                    row("Bias (scan minus tape)", String(format: "%+.1f %%", a.meanSignedPercent))
                    row("Worst", String(format: "%.1f %%", a.worstPercent))
                    Text(a.count < 5 ? "Take at least five readings of walls of different lengths."
                         : a.passes ? "Within about 2 % or 3 cm: the scan is better than a hand-traced blueprint."
                         : "Not within 2 % or 3 cm yet: keep the blueprint as the underlay and correct the walls that are off.")
                        .font(.footnote)
                }
                Section("Readings") {
                    ForEach(doc.checks, id: \.id) { c in
                        VStack(alignment: .leading) {
                            Text(c.what)
                            Text("scan \(String(format: "%.3f", c.scanned)) m, tape \(String(format: "%.3f", c.measured)) m, \(String(format: "%+.1f", c.percent)) %")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !note.isEmpty { Text(note).font(.footnote) }
        }
        .navigationTitle("Accuracy")
        .task {
            do { doc = try HouseDoc(data: try await model.client().call("GET", "/api/houses/\(houseId)")) } catch { note = "Could not load: \(error.localizedDescription)" }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).monospacedDigit() }
    }
}
