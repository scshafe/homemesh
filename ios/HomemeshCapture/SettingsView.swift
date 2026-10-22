import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics = Diagnostics.enabled

    var body: some View {
        NavigationStack {
            Form {
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
