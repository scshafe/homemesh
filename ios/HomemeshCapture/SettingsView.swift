import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { model.saveSettings(); dismiss() } }
        }
    }
}
