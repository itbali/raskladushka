// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitcherCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwitcherCore", targets: ["SwitcherCore"])],
    targets: [
        .target(name: "SwitcherCore"),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"]),
    ]
)
