import HomemeshCore
import SwiftUI
import UniformTypeIdentifiers

struct HousesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var newName = ""
    @State private var creating = false
    @State private var path: String?
    @State private var importing = false
    @State private var note: SuiMessage?

    var body: some View {
        List {
            if !model.message.isEmpty { Section { SuiNote(.warning, model.message) } }
            Section("Houses") {
                ForEach(model.houses) { h in
                    NavigationLink(value: h) {
                        VStack(alignment: .leading) {
                            Text(h.name)
                            Text("\(h.levels.count) level(s), \(h.rooms) room(s), \(h.captures) scan(s)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.houses.isEmpty && model.message.isEmpty {
                if model.configured {
                    SuiEmpty(title: "No houses yet", symbol: "house", detail: "Create one, then scan its rooms.") {
                        Button("New house") { newName = ""; creating = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    SuiEmpty(title: "Not set up", symbol: "gearshape", detail: "Give the app your server and sign-in details first.") {
                        Button("Settings") { showSettings = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("homemesh")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { showSettings = true } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New house", systemImage: "plus") { newName = ""; creating = true }.disabled(!model.configured)
                    Button("Import a house from Files…", systemImage: "square.and.arrow.down") { importing = true }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .suiMessage($note)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            Task { await importHouse(url) }
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) { SettingsView() }
        .sheet(isPresented: $creating) {
            SuiNameSheet(title: "New house", prompt: "Name (for example Home)", confirm: "Create", noun: "house",
                         isTaken: { n in model.houses.contains { $0.id == Naming.slug(n) || $0.name.lowercased() == n.lowercased() } },
                         save: { await model.createHouse(named: $0) })
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private func importHouse(_ url: URL) async {
        note = .busy("Reading the file…")
        do {
            let r = try await LocalLibrary.importPackage(from: url)
            if r.differences.isEmpty {
                note = .success("Imported \(r.id): \(LocalLibrary.describe(r)). It matches what the file says. \(model.useLocal ? "" : "Switch on \"Keep the houses on this phone\" in Settings to see it.")")
            } else {
                note = .warning("Imported \(r.id), but it differs from the file: " + r.differences.joined(separator: "; "))
            }
            await model.refresh()
        } catch {
            note = .danger("Could not import the file: \(error.localizedDescription)")
        }
    }
}
