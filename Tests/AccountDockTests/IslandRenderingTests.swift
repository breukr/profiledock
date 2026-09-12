import AppKit
import XCTest
import DockCore
@testable import AccountDock

private actor NoNetworkUsage: UsageFetching {
    func identity(for profile: Profile) async throws -> String { throw UsageLoadError.notSignedIn }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot { throw UsageLoadError.notSignedIn }
}

final class IslandRenderingTests: XCTestCase {
    @MainActor func testFreeStripGripDragsWithoutHoverOpeningAndPersistsPosition() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory), usage = UsageStore(client: NoNetworkUsage())
        model.preferences.placement = .free
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        let initial = island.layout.collapsed
        let grip = CGPoint(x: initial.minX + 15, y: initial.midY)
        island.pointerMoved(to: grip)
        XCTAssertFalse(island.expanded)
        island.drag(.began, at: grip)
        let moved = CGPoint(x: grip.x + 70, y: grip.y + 100)
        island.drag(.moved, at: moved)
        island.pointerMoved(to: moved)
        XCTAssertFalse(island.expanded)
        XCTAssertEqual(island.layout.collapsed.minX, initial.minX + 70, accuracy: 0.01)
        XCTAssertEqual(island.layout.collapsed.minY, initial.minY + 100, accuracy: 0.01)
        island.drag(.ended, at: moved)
        let restored = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: model.settingsURL))
        let key = IslandController.positionKey(for: screen)
        XCTAssertEqual(restored.floatingPositions?[key], model.floatingPosition(for: key))
        island.pointerMoved(to: CGPoint(x: island.layout.collapsed.midX, y: island.layout.collapsed.midY))
        XCTAssertTrue(island.expanded)
        XCTAssertTrue(screen.visibleFrame.contains(island.panel.frame))
    }

    @MainActor func testLegacyCornerPreferencesKeepTheirSideInFreeMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory)
        model.preferences.placement = .bottomLeft
        XCTAssertEqual(model.placement, .free)
        XCTAssertEqual(model.floatingPosition(for: "test-screen"), FloatingPosition(x: 0, y: 0))
        model.preferences.placement = .bottomRight
        XCTAssertEqual(model.floatingPosition(for: "test-screen"), FloatingPosition(x: 1, y: 0))
    }

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
