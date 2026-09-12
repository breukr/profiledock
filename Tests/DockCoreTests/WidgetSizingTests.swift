import XCTest
@testable import DockCore

final class WidgetSizingTests: XCTestCase {
    func testAutomaticAndCustomWidthsRemainBoundedWithManyProfiles() {
        for count in [0, 1, 5, 10, 25, 100] {
            let compact = WidgetSizing.compact(count: count, preferred: nil)
            XCTAssertTrue((160...360).contains(compact))
            let dots = WidgetSizing.visibleDots(count: count, width: compact, floating: true)
            XCTAssertLessThanOrEqual(dots, count)
            XCTAssertLessThan(Double(dots) * 11 + 138, compact + 12)
            let width = WidgetSizing.expanded(count: count, scale: 1, preferred: nil, insights: false)
            XCTAssertTrue((320...880).contains(width))
        }
        XCTAssertEqual(WidgetSizing.compact(count: 8, preferred: .nan), 230)
        XCTAssertEqual(WidgetSizing.expanded(count: 8, scale: 1, preferred: 600, insights: false), 600)
        XCTAssertEqual(WidgetSizing.expanded(count: 8, scale: 1, preferred: 320, insights: true), 520)
    }
    func testTilesShrinkToFitWithoutBecomingUnreadable() {
        XCTAssertEqual(WidgetSizing.tile(count: 3, available: 700, scale: 1), 132)
        XCTAssertEqual(WidgetSizing.tile(count: 5, available: 600, scale: 1), 112)
        XCTAssertEqual(WidgetSizing.tile(count: 20, available: 600, scale: 1), 104)
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 640)
        for placement in DockPlacement.allCases {
            let layout = IslandLayout(screen: screen, notchHeight: 0, notchWidth: 180, count: 50, scale: 1.3, hasMessage: false, placement: placement, compactWidth: 480, expandedWidth: 1400)
            XCTAssertTrue(screen.contains(layout.collapsed))
            XCTAssertTrue(screen.contains(layout.expanded))
        }
    }
    func testGridUsesRowsAndPagesWithinTheScreenBudget() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 1200)
        let full = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 20, scale: 1, hasMessage: false)
        XCTAssertEqual(full.profileColumns, 7)
        XCTAssertEqual(full.profileRows, 2)
        XCTAssertLessThan(full.profileRows * full.profileColumns, 20, "Additional accounts need a page, not horizontal overflow")
        let insights = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 20, scale: 1, hasMessage: false, showsInsights: true)
        XCTAssertEqual(insights.profileRows, 1)
        XCTAssertTrue(screen.contains(insights.expanded))
        XCTAssertGreaterThan(WidgetSizing.insightsHeight(width: 520, count: 5), WidgetSizing.insightsHeight(width: 1000, count: 5))
    }
}
