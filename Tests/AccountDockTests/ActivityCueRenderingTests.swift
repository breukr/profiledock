import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class ActivityCueRenderingTests: XCTestCase {
    @MainActor func testMorphReturnsToStripWithoutResizingWindowOrDuplicatingStatus() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let strip = CGRect(x: 660, y: 100, width: 194, height: 32)
        let geometry = ActivityCueLayout(screen: screen, obstacle: strip, floating: true)
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        let view = ActivityCueSurface(frame: bounds, geometry: geometry, panelOrigin: geometry.frame.origin, signal: .finished, name: "Personal", fullName: "Personal", reduceMotion: false)
        view.reveal(expanded: true)
        XCTAssertEqual(view.statusText, "Done")
        XCTAssertEqual(view.environmentText, "Personal")
        XCTAssertTrue(view.hasGeometryAnimation)
        XCTAssertEqual(view.targetGeometry, view.expandedRect)
        XCTAssertEqual(view.frame, bounds)
        try capturePreview(view, name: "floating-completion")
        view.reveal(expanded: false)
        XCTAssertEqual(view.targetGeometry, view.collapsedRect)
        XCTAssertEqual(view.frame, bounds)
    }

    @MainActor func testReduceMotionUsesFadeWithoutExpandingOrRetractingGeometry() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let strip = CGRect(x: 661, y: 950, width: 190, height: 32)
        let geometry = ActivityCueLayout(screen: screen, obstacle: strip, statusWidth: 104)
        let view = ActivityCueSurface(frame: CGRect(origin: .zero, size: geometry.frame.size), geometry: geometry, panelOrigin: geometry.frame.origin, signal: .needsInput, name: "Work", fullName: "Work", reduceMotion: true)
        for expanded in [true, false] {
            view.reveal(expanded: expanded)
            if expanded { try capturePreview(view, name: "notch-input") }
            XCTAssertFalse(view.hasGeometryAnimation)
            XCTAssertEqual(view.targetGeometry, view.expandedRect)
        }
        XCTAssertEqual(view.statusText, "Needs you")
        XCTAssertEqual(view.environmentText, "Work")
        let labels = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        let status = try XCTUnwrap(labels.first { $0.stringValue == "Needs you" })
        XCTAssertEqual(labels.filter { $0.stringValue == "Needs you" }.count, 1)
        XCTAssertLessThanOrEqual(status.intrinsicContentSize.width, status.frame.width)
    }

    @MainActor func testLongEnvironmentNameTruncatesWithoutCrowdingStatus() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let strip = CGRect(x: 12, y: 90, width: 194, height: 32)
        let geometry = ActivityCueLayout(screen: screen, obstacle: strip, floating: true, statusWidth: 104, nameWidth: 180)
        let name = "An environment with a very long descriptive name"
        let view = ActivityCueSurface(frame: CGRect(origin: .zero, size: geometry.frame.size), geometry: geometry, panelOrigin: geometry.frame.origin, signal: .needsInput, name: name, fullName: name, reduceMotion: true)
        view.reveal(expanded: true)
        let labels = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        let status = try XCTUnwrap(labels.first { $0.stringValue == "Needs you" })
        let environment = try XCTUnwrap(labels.first { $0.stringValue == name })
        XCTAssertLessThan(status.frame.maxX, environment.frame.minX)
        XCTAssertEqual(environment.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(environment.maximumNumberOfLines, 1)
        XCTAssertLessThanOrEqual(status.intrinsicContentSize.width, status.frame.width)
        try capturePreview(view, name: "long-environment")
    }

    @MainActor private func capturePreview(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_CUES"] else { return }
        func settle(_ layer: CALayer?) { layer?.removeAllAnimations(); layer?.sublayers?.forEach { settle($0) }; layer?.mask?.removeAllAnimations() }
        view.layoutSubtreeIfNeeded(); settle(view.layer)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
    }
}
