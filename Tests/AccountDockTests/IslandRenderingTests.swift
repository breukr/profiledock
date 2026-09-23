import AppKit
import XCTest
import DockCore
@testable import AccountDock

private actor NoNetworkUsage: UsageFetching {
    func identity(for profile: Profile) async throws -> String { throw UsageLoadError.notSignedIn }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot { throw UsageLoadError.notSignedIn }
}

final class IslandRenderingTests: XCTestCase {
    @MainActor func testInsightsSpringKeepsCanvasFixedAndRapidReversalSettlesAtLatestSize() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        for placement in [DockPlacement.topCenter, .free] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = DockModel(home: directory), usage = UsageStore(client: NoNetworkUsage())
            model.preferences.placement = placement
            let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false,
                                          reduceMotion: { false }, settings: {})
            defer { island.shutdown(); usage.shutdown() }
            island.pointerMoved(to: CGPoint(x: island.layout.collapsed.midX, y: island.layout.collapsed.midY))
            try await Task.sleep(for: .milliseconds(180))
            let initial = island.panel.frame
            let surface = try XCTUnwrap(island.panel.contentView as? IslandSurface)
            island.presentation.setInsightsExpanded(true)
            let canvas = island.panel.frame
            XCTAssertTrue(surface.isResizing)
            XCTAssertTrue(canvas.contains(initial))
            XCTAssertTrue(canvas.contains(island.layout.expanded))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(island.panel.frame, canvas, "The native window does not resize on each animation frame")
            island.presentation.setInsightsExpanded(false)
            island.presentation.setInsightsExpanded(true)
            try await waitForResizeCompletion(surface)
            XCTAssertFalse(surface.isResizing)
            XCTAssertEqual(island.panel.frame.size, island.layout.expanded.size)
            XCTAssertEqual(island.panel.frame.minX, island.layout.expanded.minX, accuracy: 1)
            XCTAssertEqual(island.panel.frame.minY, island.layout.expanded.minY, accuracy: 1)
            XCTAssertEqual(surface.contentFrame, CGRect(origin: .zero, size: island.layout.expanded.size))
            XCTAssertTrue(island.expanded)
            island.presentation.setInsightsExpanded(false)
            try await waitForResizeCompletion(surface)
            XCTAssertFalse(surface.isResizing)
            XCTAssertEqual(island.panel.frame, initial, "Closing does not leave an oversized invisible window")
        }
    }

    @MainActor private func waitForResizeCompletion(_ surface: IslandSurface) async throws {
        // Core Animation completion delivery can lag on a busy CI runner.
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(2)
        while surface.isResizing && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor func testReducedMotionSkipsDrawerGeometryAndShutdownCancelsInFlightSpring() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory), usage = UsageStore(client: NoNetworkUsage())
        var reduceMotion = true
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false,
                                      reduceMotion: { reduceMotion }, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        island.pointerMoved(to: CGPoint(x: island.layout.collapsed.midX, y: island.layout.collapsed.midY))
        let surface = try XCTUnwrap(island.panel.contentView as? IslandSurface)
        island.presentation.setInsightsExpanded(true)
        XCTAssertFalse(surface.isResizing)
        XCTAssertEqual(island.panel.frame, island.layout.expanded)
        reduceMotion = false
        island.presentation.setInsightsExpanded(false)
        XCTAssertTrue(surface.isResizing)
        island.shutdown()
        XCTAssertFalse(surface.isResizing)
    }

    @MainActor func testNativeMenuAndSubmenuKeepStripOpenUntilDismissed() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No attached screen") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DockModel(home: directory), usage = UsageStore(client: NoNetworkUsage())
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        let inside = CGPoint(x: island.layout.collapsed.midX, y: island.layout.collapsed.midY)
        let outside = CGPoint(x: screen.frame.minX - 100, y: screen.frame.minY - 100)
        island.pointerMoved(to: inside)
        island.presentation.setInsightsExpanded(true)
        island.pointerMoved(to: outside) // An already pending close must also be cancelled.
        let menu = NSMenu(), submenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        try await Task.sleep(for: .milliseconds(160))
        island.pointerMoved(to: outside)
        XCTAssertTrue(island.expanded)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        island.pointerMoved(to: outside)
        XCTAssertTrue(island.expanded)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        island.pointerMoved(to: outside)
        try await Task.sleep(for: .milliseconds(160))
        island.pointerMoved(to: outside)
        XCTAssertFalse(island.expanded)
    }

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
