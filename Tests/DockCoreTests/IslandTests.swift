import XCTest
import CoreGraphics
@testable import DockCore

final class IslandTests: XCTestCase {
    func testFreePositionKeepsStripAndPanelVisibleAcrossEdgesSizesAndScreenOrigins() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -2560, y: -600, width: 2560, height: 1440), CGRect(x: 1920, y: 200, width: 900, height: 1440)] {
            let visible = screen.insetBy(dx: 65, dy: 40)
            for x in [0.0, 0.25, 0.5, 0.75, 1] {
                for y in [0.0, 0.25, 0.5, 0.75, 1] {
                    for count in [1, 5, 20] {
                        let layout = IslandLayout(screen: screen, notchHeight: 38, notchWidth: 190, count: count, scale: 1.3, hasMessage: true, showsResetDetails: true, placement: .free, visibleFrame: visible, position: FloatingPosition(x: x, y: y), usageRows: 1)
                        XCTAssertTrue(visible.contains(layout.collapsed)); XCTAssertTrue(visible.contains(layout.expanded))
                        XCTAssertTrue(layout.expanded.contains(layout.collapsed))
                        XCTAssertFalse(layout.containsPointer(CGPoint(x: screen.midX, y: screen.maxY), expandedOrClosing: false))
                        XCTAssertEqual(layout.notchHeight, 0)
                        if y == 0 { XCTAssertTrue(layout.opensUpward) }
                        if y == 1 { XCTAssertFalse(layout.opensUpward) }
                        let cues = ActivityCueLayout(screen: visible, obstacle: layout.collapsed, floating: true)
                        XCTAssertTrue(visible.contains(cues.left)); XCTAssertTrue(visible.contains(cues.right))
                        XCTAssertFalse(cues.left.intersects(layout.collapsed))
                    }
                }
            }
        }
    }

    func testPositionClampsAndRestoresProportionallyAfterDisplayResize() throws {
        let position = FloatingPosition(x: 0.25, y: 0.75)
        let restored = try JSONDecoder().decode(FloatingPosition.self, from: JSONEncoder().encode(position))
        for available in [CGRect(x: -1900, y: 80, width: 1800, height: 1000), CGRect(x: 20, y: -500, width: 1300, height: 750)] {
            let size = CGSize(width: 194, height: 32)
            let origin = restored.origin(in: available, size: size)
            let roundTrip = FloatingPosition(origin: origin, available: available, size: size)
            XCTAssertEqual(roundTrip.x, position.x, accuracy: 0.0001)
            XCTAssertEqual(roundTrip.y, position.y, accuracy: 0.0001)
        }
        XCTAssertEqual(FloatingPosition(x: -5, y: 5), FloatingPosition(x: 0, y: 1))
        XCTAssertEqual(DockPlacement.allCases, [.topCenter, .free])
    }

    func testSingleUsageMeterDoesNotReserveAnEmptySecondRow() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let one = IslandLayout(screen: screen, notchHeight: 0, notchWidth: 0, count: 5, scale: 1, hasMessage: false, usageRows: 1)
        let two = IslandLayout(screen: screen, notchHeight: 0, notchWidth: 0, count: 5, scale: 1, hasMessage: false, usageRows: 2)
        XCTAssertEqual(two.expanded.height - one.expanded.height, 56)
        XCTAssertEqual(two.expanded.maxY, one.expanded.maxY)
    }

    func testLowerPlacementsStayInsideDockInsetsAndNeverHoverAtNotch() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        for visible in [screen.insetBy(dx: 0, dy: 80), CGRect(x: -1820, y: -200, width: 1820, height: 1048), CGRect(x: -1920, y: -200, width: 1820, height: 1048)] {
            for placement in [DockPlacement.bottomLeft, .bottomRight] {
                let normal = IslandLayout(screen: screen, notchHeight: 38, notchWidth: 190, count: 12, scale: 1.3, hasMessage: false, placement: placement, visibleFrame: visible)
                let details = IslandLayout(screen: screen, notchHeight: 38, notchWidth: 190, count: 12, scale: 1.3, hasMessage: false, showsResetDetails: true, placement: placement, visibleFrame: visible)
                XCTAssertTrue(visible.contains(normal.collapsed))
                XCTAssertTrue(visible.contains(normal.expanded))
                XCTAssertEqual(normal.notchHeight, 0)
                XCTAssertEqual(normal.expanded.minY, details.expanded.minY)
                XCTAssertGreaterThan(details.expanded.maxY, normal.expanded.maxY)
                XCTAssertTrue(normal.containsPointer(CGPoint(x: normal.collapsed.midX, y: normal.collapsed.midY), expandedOrClosing: false))
                XCTAssertFalse(normal.containsPointer(CGPoint(x: normal.collapsed.midX, y: screen.maxY), expandedOrClosing: false))
                XCTAssertFalse(normal.containsPointer(CGPoint(x: normal.expanded.midX, y: normal.expanded.maxY + 1), expandedOrClosing: true))
                let cues = ActivityCueLayout(screen: screen, obstacle: normal.collapsed, floating: true)
                XCTAssertGreaterThan(cues.left.minY, normal.collapsed.maxY)
                XCTAssertTrue(visible.contains(cues.left)); XCTAssertTrue(visible.contains(cues.right))
            }
        }
    }
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
