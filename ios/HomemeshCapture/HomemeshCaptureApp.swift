import SwiftUI

@main
struct HomemeshCaptureApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HousesView()
                    .navigationDestination(for: HouseSummary.self) { HouseView(houseId: $0.id) }
            }
            .environmentObject(model)
            .task {
                Diagnostics.launched()
                if model.configured && !model.useLocal { DiagnosticsUploader.shared.start { model.client() } }   // on this phone the logs stay here
            }
        }
    }
}
