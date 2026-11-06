import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var demoNote: String?
    @State private var report: URL?
    @State private var reportNote: String?

    private func demo() {
        do {
            let added = try LocalLibrary.addDemoHouses()
            demoNote = added.isEmpty ? "The demo houses are already on this phone." : "Added: " + added.joined(separator: ", ") + "."
            Task { await model.refresh() }
        } catch { demoNote = "Could not add the demo houses: \(error.localizedDescription)" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Add the demo house") { demo() }
                    if let demoNote { SuiNote(.info, demoNote) }
                } header: { Text("Houses") } footer: {
                    Text("Your houses are kept on this phone and nothing is sent anywhere. Export a house to Files from its screen for a second copy.")
                }
                Section {
                    if let report {
                        ShareLink(item: report) { Label("Share the diagnostics file", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("Prepare a diagnostics file") { prepare() }
                    }
                    if let reportNote { SuiNote(.danger, reportNote) }
                } header: { Text("Diagnostics") } footer: {
                    Text("Scan phases, errors, memory warnings and crash reports (no room names, no scans). They stay on this phone; share the file when you want someone to look at them.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func prepare() {
        do { report = try DiagnosticsCollector.shared.report(); reportNote = nil } catch { reportNote = "Could not prepare the file: \(error.localizedDescription)" }
    }
}
