import XCTest
import CoreGraphics
@testable import DockCore

final class IslandTests: XCTestCase {
    func testExactTopEdgeStaysInsideForBothDisplayTypes() {
        for notch in [0.0, 38.0] {
            let screen = CGRect(x: -1800, y: 220, width: 1800, height: 1200)
            let layout = IslandLayout(screen: screen, notchHeight: notch, notchWidth: 220, count: 5, scale: 1, hasMessage: false)
            var hover = HoverIntent()
            for time in stride(from: 0.0, through: 3.0, by: 1.0 / 120) {
                let edge = CGPoint(x: screen.midX, y: screen.maxY)
                XCTAssertTrue(hover.update(inside: layout.containsPointer(edge, expandedOrClosing: hover.expanded), now: time))
                XCTAssertNil(hover.collapseDeadline)
            }
            XCTAssertTrue(layout.containsPointer(CGPoint(x: layout.expanded.minX, y: screen.maxY), expandedOrClosing: true))
            XCTAssertFalse(layout.containsPointer(CGPoint(x: screen.midX, y: screen.maxY + 4), expandedOrClosing: true))
        }
    }

    func testOnlyCollapsedRegionStartsHoverAndClosingRegionAllowsReentry() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 5, scale: 1, hasMessage: false)
        let belowNotch = CGPoint(x: screen.midX, y: layout.expanded.midY)
        XCTAssertFalse(layout.containsPointer(belowNotch, expandedOrClosing: false))
        XCTAssertTrue(layout.containsPointer(belowNotch, expandedOrClosing: true))
        XCTAssertFalse(layout.containsPointer(CGPoint(x: screen.midX, y: layout.expanded.minY - 5), expandedOrClosing: true))
    }

    func testNotchKeepsTopEdgeAndCameraClear() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 5, scale: 1, hasMessage: false)
        XCTAssertEqual(layout.collapsed.maxY, screen.maxY)
        XCTAssertEqual(layout.expanded.maxY, screen.maxY)
        XCTAssertEqual(layout.collapsed.midX, screen.midX)
        XCTAssertEqual(layout.expanded.midX, screen.midX)
        XCTAssertEqual(layout.collapsed.height, 32)
        XCTAssertEqual(layout.collapsed.width, 180)
    }

    func testExternalMonitorWithNegativeOriginAndSizes() {
        let screen = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        for scale in [0.85, 1, 1.3] {
            let layout = IslandLayout(screen: screen, notchHeight: 0, notchWidth: 0, count: 5, scale: scale, hasMessage: true, menuBarHeight: 26)
            XCTAssertEqual(layout.collapsed.maxY, screen.maxY)
            XCTAssertEqual(layout.expanded.maxY, screen.maxY)
            XCTAssertEqual(layout.collapsed.height, 26)
            XCTAssertTrue(screen.contains(layout.expanded))
            XCTAssertEqual(layout.expanded.midX, screen.midX)
        }
    }

    func testHoverOpensImmediatelyAndClosesWithoutMoreMouseMovement() {
        var hover = HoverIntent()
        XCTAssertTrue(hover.update(inside: true, now: 0))
        XCTAssertNil(hover.collapseDeadline)
        XCTAssertTrue(hover.update(inside: false, now: 1))
        let deadline = hover.collapseDeadline!
        XCTAssertTrue(hover.update(inside: false, now: deadline - 0.001))
        XCTAssertFalse(hover.update(inside: false, now: deadline))
        XCTAssertNil(hover.collapseDeadline)
    }

    func testReentryCancelsCollapseAndRepeatedExitDoesNotPostponeIt() {
        var hover = HoverIntent()
        XCTAssertTrue(hover.update(inside: true, now: 0))
        XCTAssertTrue(hover.update(inside: false, now: 1))
        let deadline = hover.collapseDeadline
        XCTAssertTrue(hover.update(inside: false, now: 1.05))
        XCTAssertEqual(hover.collapseDeadline, deadline)
        XCTAssertTrue(hover.update(inside: true, now: 1.08))
        XCTAssertNil(hover.collapseDeadline)
        XCTAssertTrue(hover.update(inside: true, now: 2))
        XCTAssertTrue(hover.update(inside: false, now: 3))
        XCTAssertFalse(hover.update(inside: false, now: 3.2))
        XCTAssertTrue(hover.update(inside: true, now: 3.21))
    }

    func testClosedIslandDoesNotScheduleIdleWakeups() {
        var hover = HoverIntent()
        for time in [0.0, 0.1, 10.0] {
            XCTAssertFalse(hover.update(inside: false, now: time))
            XCTAssertNil(hover.collapseDeadline)
        }
    }

    func testOldPreferencesRemainCompatibleWithOptionalLogo() throws {
        let old = Data(#"{"id":"test","name":"Work","color":"009B87"}"#.utf8)
        let profile = try JSONDecoder().decode(Profile.self, from: old)
        XCTAssertNil(profile.iconFilename)
        let customized = Profile(id: profile.id, name: profile.name, color: profile.color, iconFilename: "test.png")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(customized)), customized)
    }
}
