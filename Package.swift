// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccountDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AccountDock", targets: ["AccountDock"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "DockCore"),
        .executableTarget(name: "AccountDock", dependencies: ["DockCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
        .testTarget(name: "AccountDockTests", dependencies: ["AccountDock"])
    ],
    swiftLanguageModes: [.v5]
)
