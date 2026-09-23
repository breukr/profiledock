// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccountDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AccountDock", targets: ["AccountDock"]), .executable(name: "ProfileDockClaude", targets: ["ProfileDockClaude"]), .executable(name: "ProfileDockShim", targets: ["ProfileDockShim"]), .executable(name: "ProfileDockContext", targets: ["ProfileDockContext"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "DockCore"),
        .executableTarget(name: "ProfileDockClaude", dependencies: ["DockCore"]),
        .executableTarget(name: "ProfileDockShim", dependencies: ["DockCore"]),
        .target(name: "ContextCore", dependencies: ["DockCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ProfileDockContext", dependencies: ["ContextCore"]),
        .executableTarget(name: "AccountDock", dependencies: ["DockCore", "ContextCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ContextCoreTests", dependencies: ["ContextCore"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
        .testTarget(name: "AccountDockTests", dependencies: ["AccountDock"])
    ],
    swiftLanguageModes: [.v5]
)
