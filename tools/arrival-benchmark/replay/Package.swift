// swift-tools-version: 5.9
import PackageDescription

// Replays recorded public feeds through the App's own TransitCore code, so the score
// measures exactly what riders are shown, not a reimplementation of it.
let package = Package(
    name: "ArrivalReplay",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../../ios/TransitCore")],
    targets: [.executableTarget(name: "ArrivalReplay", dependencies: ["TransitCore"])]
)
