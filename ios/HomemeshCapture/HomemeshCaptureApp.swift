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
                DiagnosticsCollector.shared.start()   // the logs stay on this phone until the owner shares them
                let saved = await LeftoverScans.adopt(into: model.library)
                if saved > 0 { await model.refresh() }
            }
        }
    }
}
