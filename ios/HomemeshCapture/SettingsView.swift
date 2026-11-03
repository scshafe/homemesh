import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics = Diagnostics.enabled
    @State private var demoNote: String?

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
                    Toggle("Keep the houses on this phone", isOn: $model.useLocal)
                    Button("Add the demo house") { demo() }
                    if let demoNote { SuiNote(.info, demoNote) }
                } header: { Text("Where the houses live") } footer: {
                    Text("On this phone, nothing is sent anywhere: no server and no sign-in. Copy a house over from the server with \"Copy to this phone\" on its screen, then switch this on.")
                }
                Section("Server") {
                    TextField("https://homemesh.<tailnet>", text: $model.server).textInputAutocapitalization(.never).keyboardType(.URL)
                }
                Section("Sign-in (Pocket ID)") {
                    TextField("Pocket ID address (https://…)", text: $model.issuer).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Client id", text: $model.clientId).textInputAutocapitalization(.never)
                    Button("Sign out") { Auth.signOut(); model.message = "Signed out." }
                }
                Section {
                    Toggle("Send crash and event logs to the server", isOn: $diagnostics)
                        .onChange(of: diagnostics) { _, on in Diagnostics.enabled = on }
                } header: { Text("Diagnostics") } footer: {
                    Text("Scan phases, errors and crash reports (no room names, no scans) go to your homemesh server, so you do not have to fetch logs from the phone.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { model.saveSettings(); dismiss() } }
        }
    }
}
