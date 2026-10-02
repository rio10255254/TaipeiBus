// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TransitCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TransitCore", targets: ["TransitCore"])],
    targets: [
        .target(name: "TransitCore"),
        .testTarget(name: "TransitCoreTests", dependencies: ["TransitCore"])
    ]
)
