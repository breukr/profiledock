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
            XCTAssertTrue((320...1200).contains(width))
        }
        XCTAssertEqual(WidgetSizing.compact(count: 8, preferred: .nan), 230)
        XCTAssertEqual(WidgetSizing.expanded(count: 8, scale: 1, preferred: 600, insights: false), 600)
        XCTAssertEqual(WidgetSizing.expanded(count: 8, scale: 1, preferred: 320, insights: true), 520)
    }
    func testCardWidthStaysWithinBoundsAtEveryWidthAndScale() {
        // (strip width, scale) -> (columns, card width); the strip has 16 pt padding on both sides.
        let expected: [Double: [Double: (Int, Double)]] = [
            360: [0.85: (1, 289), 1: (1, 328), 1.3: (1, 328)],
            680: [0.85: (3, 209), 1: (2, 319), 1.3: (2, 319)],
            1040: [0.85: (4, 244), 1: (4, 244), 1.3: (3, 329)],
        ]
        for (width, scales) in expected {
            for (scale, value) in scales {
                let available = width - 2 * WidgetSizing.stripPadding
                let columns = WidgetSizing.columns(count: 12, available: available, scale: scale)
                let card = WidgetSizing.cardWidth(columns: columns, available: available, scale: scale)
                XCTAssertEqual(columns, value.0, "columns at \(width) x \(scale)")
                XCTAssertEqual(card, value.1, "card width at \(width) x \(scale)")
                XCTAssertLessThanOrEqual(card, CardMetrics.maxWidth(scale: scale))
                XCTAssertGreaterThanOrEqual(card, min(available, CardMetrics.minWidth(scale: scale)))
                XCTAssertLessThanOrEqual(Double(columns) * card + Double(columns - 1) * WidgetSizing.gridGap, available)
            }
        }
        // Wide strips cap cards at the maximum width instead of stretching them; the grid stays leading-aligned.
        XCTAssertEqual(WidgetSizing.cardWidth(columns: 1, available: 900, scale: 1), 340)
        XCTAssertEqual(WidgetSizing.columns(count: 2, available: 1400, scale: 1), 2, "Never more columns than profiles")
    }
    func testAutomaticColumnsBalanceRowsAndWidthFitsThem() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 20].map(WidgetSizing.automaticColumns), [1, 2, 3, 4, 3, 3, 4, 4, 3, 4, 4, 4, 4])
        for scale in [0.85, 1.0, 1.3] {
            for count in [1, 2, 5, 8, 10] {
                let width = WidgetSizing.gridWidth(columns: WidgetSizing.automaticColumns(count: count), scale: scale)
                guard width <= 1200 else { continue }
                XCTAssertEqual(WidgetSizing.columns(count: count, available: width - 32, scale: scale), WidgetSizing.automaticColumns(count: count))
            }
        }
    }
    func testCardHeightFollowsGeometryExactly() {
        // 12 padding + 36 header + 10 + two 14 pt rows with a 6 pt gap + 6 + 20 footer + 12 padding.
        XCTAssertEqual(CardMetrics.height(usageRows: 2, scale: 1), 130)
        XCTAssertEqual(CardMetrics.height(usageRows: 1, scale: 1), 110)
        XCTAssertEqual(CardMetrics.height(usageRows: 2, scale: 0.85), 126, "The text column sets the header height on small scales")
        XCTAssertEqual(CardMetrics.height(usageRows: 2, scale: 1.3), 141)
    }
    func testLayoutsStayOnScreenWithManyProfiles() {
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
        // 20 profiles: four balanced columns, four rows of horizontal cards, the rest on a second page.
        XCTAssertEqual(full.profileColumns, 4)
        XCTAssertEqual(full.profileRows, 4)
        XCTAssertLessThan(full.profileRows * full.profileColumns, 20, "Additional accounts need a page, not horizontal overflow")
        let insights = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 20, scale: 1, hasMessage: false, showsInsights: true)
        XCTAssertEqual(insights.profileRows, 2)
        XCTAssertTrue(screen.contains(insights.expanded))
        XCTAssertGreaterThan(WidgetSizing.insightsHeight(width: 520, count: 5), WidgetSizing.insightsHeight(width: 1000, count: 5))
    }
}
