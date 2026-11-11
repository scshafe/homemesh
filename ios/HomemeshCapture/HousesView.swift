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
    @State private var exported: URL?
    @State private var exportReport: HousePackage.Report?

    var body: some View {
        List {
            if !model.message.isEmpty { Section { SuiNote(.warning, model.message) } }
            Section("Houses") {
                ForEach(model.houses) { h in
                    if let why = h.unreadable {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(h.name)
                            Text("This house is stored on the phone but cannot be read: \(why)").font(.footnote).foregroundStyle(.secondary)
                            Button("Export it to Files…", systemImage: "square.and.arrow.up") { Task { await export(h.id) } }.buttonStyle(.bordered)
                        }
                    } else {
                    NavigationLink(value: h) {
                        VStack(alignment: .leading) {
                            Text(h.name)
                            Text("\(h.levels.count) level(s), \(h.rooms) room(s), \(h.captures) scan(s)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    }
                }
            }
        }
        .fileMover(isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }), file: exported) { result in
            if case .failure(let e) = result, (e as? CocoaError)?.code != .userCancelled { note = .danger("Could not save the file: \(e.localizedDescription)") }
            else if case .success = result, let r = exportReport { note = .success("Saved to Files: \(LocalLibrary.describe(r)). Keep it; a newer version of homemesh may open it.") }
        }
        .overlay {
            if model.houses.isEmpty && model.message.isEmpty {
                SuiEmpty(title: "No houses yet", symbol: "house", detail: "Create one, then scan its rooms. Or look around the demo house first (Settings).") {
                    Button("New house") { newName = ""; creating = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("homemesh")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { showSettings = true } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New house", systemImage: "plus") { newName = ""; creating = true }
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

    private func export(_ id: String) async {
        note = .busy("Writing the house to a file…")
        do {
            let out = try await LocalLibrary.export(house: id)
            exportReport = out.report
            note = nil
            exported = out.url
        } catch {
            note = .danger("Could not export the house: \(error.localizedDescription)")
        }
    }

    private func importHouse(_ url: URL) async {
        note = .busy("Reading the file…")
        do {
            let r = try await LocalLibrary.importPackage(from: url)
            if r.differences.isEmpty {
                note = .success("Imported \(r.id): \(LocalLibrary.describe(r)). It matches what the file says.")
            } else {
                note = .warning("Imported \(r.id), but it differs from the file: " + r.differences.joined(separator: "; "))
            }
            await model.refresh()
        } catch {
            note = .danger("Could not import the file: \(error.localizedDescription)")
        }
    }
}
