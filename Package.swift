// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccountDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AccountDock", targets: ["AccountDock"])],
    targets: [
        .target(name: "DockCore"),
        .executableTarget(name: "AccountDock", dependencies: ["DockCore"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
        .testTarget(name: "AccountDockTests", dependencies: ["AccountDock"])
    ],
    swiftLanguageModes: [.v5]
)
