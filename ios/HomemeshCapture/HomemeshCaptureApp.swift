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
        }
    }
}
