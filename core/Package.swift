// swift-tools-version: 6.2
import PackageDescription

// The on-device engine (docs/design-standalone-app.md). Foundation only: no UIKit, SwiftUI, RoomPlan or simd,
// so it builds and tests on Linux as well as in Xcode.
let package = Package(
    name: "HomemeshCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "HomemeshCore", targets: ["HomemeshCore"])],
    targets: [
        .target(name: "HomemeshCore"),
        .testTarget(name: "HomemeshCoreTests", dependencies: ["HomemeshCore"], resources: [.copy("Golden")]),
    ]
)
