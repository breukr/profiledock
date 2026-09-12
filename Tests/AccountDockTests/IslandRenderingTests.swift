import AppKit
import XCTest
import DockCore
@testable import AccountDock

private actor NoNetworkUsage: UsageFetching {
    func identity(for profile: Profile) async throws -> String { throw UsageLoadError.notSignedIn }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot { throw UsageLoadError.notSignedIn }
}

final class IslandRenderingTests: XCTestCase {
    @MainActor func testHoverKeepsNativeWindowAndContentSizeFixedAtTopEdge() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory)
        let usage = UsageStore(client: NoNetworkUsage())
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        let initial = island.panel.frame
        let bounds = island.panel.contentView?.bounds
        XCTAssertEqual(bounds?.size, island.layout.expanded.size)
        for _ in 0..<240 { island.pointerMoved(to: CGPoint(x: screen.frame.midX, y: screen.frame.maxY)) }
        XCTAssertTrue(island.expanded)
        XCTAssertEqual(island.panel.frame, initial)
        XCTAssertEqual(island.panel.contentView?.bounds, bounds)
        XCTAssertEqual(island.diagnostics["animationCount"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(island.preferredFPS, 60)
    }

    @MainActor func testResetDisclosureGrowsDownwardAndRemainsInsideStableHoverRegion() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory)
        let usage = UsageStore(client: NoNetworkUsage())
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        island.pointerMoved(to: CGPoint(x: screen.frame.midX, y: screen.frame.maxY))
        let initial = island.panel.frame
        island.presentation.toggleResetDetails("default")
        XCTAssertEqual(island.panel.frame.maxY, initial.maxY)
        XCTAssertEqual(island.panel.frame.height, initial.height + IslandLayout.resetDetailsHeight)
        XCTAssertEqual(island.panel.contentView?.bounds.size, island.layout.expanded.size)
        let detailsPoint = CGPoint(x: initial.midX, y: island.panel.frame.minY + 15)
        XCTAssertTrue(island.layout.containsPointer(detailsPoint, expandedOrClosing: true))
        for _ in 0..<240 { island.pointerMoved(to: detailsPoint) }
        XCTAssertTrue(island.expanded)
        island.presentation.toggleResetDetails("test")
        island.presentation.toggleResetDetails("default")
        XCTAssertEqual(island.panel.frame.height, initial.height + IslandLayout.resetDetailsHeight)
        XCTAssertEqual(island.presentation.resetDetails, ["test"])
        island.presentation.toggleResetDetails("test")
        XCTAssertEqual(island.panel.frame, initial)
    }
}
