import SwiftUI

struct HousesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var newName = ""
    @State private var creating = false
    @State private var path: String?

    var body: some View {
        List {
            if !model.message.isEmpty { Section { Text(model.message).font(.footnote) } }
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
        .navigationTitle("homemesh")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { showSettings = true } }
            ToolbarItem(placement: .topBarTrailing) { Button("New house", systemImage: "plus") { newName = ""; creating = true }.disabled(!model.configured) }
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) { SettingsView() }
        .alert("New house", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { Task { _ = await model.createHouse(named: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}
