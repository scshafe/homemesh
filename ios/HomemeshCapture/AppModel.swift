import SwiftUI

/// The server settings and the house list, shared by every screen.
@MainActor
final class AppModel: ObservableObject {
    @Published var server = Settings.server.trimmed
    @Published var issuer = Settings.issuer.trimmed
    @Published var clientId = Settings.clientId.trimmed
    @Published var houses: [HouseSummary] = []
    @Published var message = ""
    @Published var busy = false

    var configured: Bool { !server.trimmed.isEmpty && !issuer.trimmed.isEmpty && !clientId.trimmed.isEmpty }

    func saveSettings() {
        server = server.trimmed
        issuer = issuer.trimmed
        clientId = clientId.trimmed
        Settings.server = server
        Settings.issuer = issuer
        Settings.clientId = clientId
    }

    func client() -> Client {
        let auth = Auth(issuer: issuer.trimmed, clientId: clientId.trimmed)
        return Client(server: server, token: { try await auth.freshIdToken() })
    }

    func uploader(house: String) -> Uploader {
        let auth = Auth(issuer: issuer.trimmed, clientId: clientId.trimmed)
        return Uploader(server: server, house: house, token: { try await auth.freshIdToken() })
    }

    func summary(_ id: String) -> HouseSummary? { houses.first { $0.id == id } }

    func refresh() async {
        guard configured else { houses = []; message = ""; return }
        busy = true
        defer { busy = false }
        do {
            houses = try await client().houses()
            message = ""
        } catch {
            message = "Could not load the houses: \(error.localizedDescription)"
        }
    }

    /// Creates a house from a display name; returns what went wrong, or nil when it worked.
    func createHouse(named name: String) async -> String? {
        let id = Naming.slug(name)
        guard !name.trimmed.isEmpty, !id.isEmpty else { return "Give the house a name." }
        do {
            _ = try await client().createHouse(id: id, name: name.trimmed)
            await refresh()
            return nil
        } catch {
            return "Could not create the house: \(error.localizedDescription)"
        }
    }

    /// Adds a floor; returns what went wrong, or nil when it worked.
    func addLevel(house: String, name: String, below: Bool = false) async -> String? {
        guard !name.trimmed.isEmpty else { return "Give the floor a name." }
        do {
            _ = try await client().addLevel(house: house, name: name.trimmed, below: below)
            await refresh()
            return nil
        } catch {
            return "Could not add the floor: \(error.localizedDescription)"
        }
    }
}
