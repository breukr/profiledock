import XCTest
@testable import DockCore

final class UsageInsightsTests: XCTestCase {
    func testPricingSeparatesCachedAndWrittenInputWithoutCountingReasoningTwice() throws {
        let tokens = InsightTokens(input: 100_000, cached: 60_000, written: 10_000, output: 2_000)
        XCTAssertEqual(try XCTUnwrap(InsightPricing.estimate(model: "gpt-6-astra", tokens: tokens)), 0.585, accuracy: 0.00001)
        XCTAssertEqual(tokens.total, 102_000)
        XCTAssertNil(InsightPricing.estimate(model: "future-model", tokens: tokens))
        XCTAssertNil(InsightPricing.estimate(model: "gpt-5.5", tokens: tokens))
        XCTAssertNil(InsightPricing.estimate(model: "gpt-6-astra", tokens: .init(input: 2, cached: 3)))
    }

    func testLongContextAndDatedModelUseKnownRatesOnly() throws {
        let tokens = InsightTokens(input: 300_000, cached: 100_000, output: 10_000)
        XCTAssertEqual(try XCTUnwrap(InsightPricing.estimate(model: "gpt-6-astra-2026-09-01", tokens: tokens)), 4.95, accuracy: 0.00001)
        XCTAssertNil(InsightPricing.estimate(model: "gpt-6-astra-custom", tokens: tokens))
    }

    func testCombinedReportDeduplicatesCopiedRecordsAndMarksPartialCosts() {
        let now = Date(), tokens = InsightTokens(input: 100, output: 10)
        let samples = [
            InsightSample(id: "same", profileID: "one", sessionID: "task", date: now, model: "known", tokens: tokens, estimatedCost: 2),
            InsightSample(id: "same", profileID: "two", sessionID: "task", date: now, model: "known", tokens: tokens, estimatedCost: 2),
            InsightSample(id: "next", profileID: "two", sessionID: "other-task", date: now, model: "unknown", tokens: tokens, estimatedCost: nil)
        ]
        let combined = InsightReport.make(samples: samples, profileID: nil, period: .today, now: now)
        XCTAssertEqual(combined.tokens.total, 220)
        XCTAssertEqual(combined.cost, 2)
        XCTAssertEqual(combined.sessions.count, 2)
        XCTAssertEqual(combined.unpricedTokens, 110)
        XCTAssertNil(combined.averageCost)
        let bucket = combined.buckets.first { $0.tokens.total > 0 }!
        XCTAssertEqual(bucket.accounts["one"]?.tokens.total, 110)
        XCTAssertEqual(bucket.accounts["two"]?.tokens.total, 110)
        XCTAssertEqual(bucket.accounts.values.reduce(0) { $0 + $1.tokens.total }, bucket.tokens.total)
        XCTAssertEqual(bucket.accounts.values.reduce(0) { $0 + $1.cost }, bucket.cost)
        XCTAssertEqual(bucket.accounts.values.reduce(0) { $0 + $1.sessions.count }, bucket.sessions.count)
        let first = InsightReport.make(samples: samples, profileID: "one", period: .today, now: now)
        XCTAssertEqual(first.tokens.total, 110)
        XCTAssertEqual(first.averageCost, 2)
    }

    func testStackedSessionCountsDoNotDuplicateAThreadSeenInTwoProfiles() {
        let now = Date(), tokens = InsightTokens(input: 50)
        let samples = ["one", "two"].map { id in
            InsightSample(id: id, profileID: id, sessionID: "shared-thread", date: now, model: nil, tokens: tokens, estimatedCost: 1)
        }
        let report = InsightReport.make(samples: samples, profileID: nil, period: .today, now: now)
        let bucket = report.buckets.first { $0.tokens.total > 0 }!
        XCTAssertEqual(bucket.tokens.total, 100)
        XCTAssertEqual(bucket.accounts.count, 2)
        XCTAssertEqual(bucket.accounts.values.reduce(0) { $0 + $1.sessions.count }, 1)
    }

    func testLocalCalendarHandlesDaylightSavingAndMidnightBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T21:00:00Z"))
        let start = InsightsPeriod.today.start(now: now, calendar: calendar)
        let tokens = InsightTokens(input: 1)
        let samples = [start.addingTimeInterval(-1), start, now.addingTimeInterval(1)].enumerated().map { index, date in
            InsightSample(id: "\(index)", profileID: "one", sessionID: "task", date: date, model: nil, tokens: tokens, estimatedCost: nil)
        }
        let report = InsightReport.make(samples: samples, profileID: nil, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(report.tokens.total, 1)
        XCTAssertEqual(report.buckets.count, 23)
        XCTAssertEqual(InsightReport.make(samples: [], profileID: nil, period: .month, now: now, calendar: calendar).buckets.count, 30)
    }

    func testInsightsStayWithinShortAndWideScreensInEveryPlacement() {
        for size in [CGSize(width: 1024, height: 640), CGSize(width: 1512, height: 982), CGSize(width: 3840, height: 1600)] {
            let screen = CGRect(origin: .zero, size: size)
            for placement in DockPlacement.allCases {
                let layout = IslandLayout(screen: screen, notchHeight: 32, notchWidth: 180, count: 1, scale: 1,
                    hasMessage: true, showsResetDetails: true, placement: placement, visibleFrame: screen.insetBy(dx: 0, dy: 24), showsInsights: true)
                XCTAssertTrue(screen.contains(layout.expanded))
                XCTAssertGreaterThanOrEqual(layout.expanded.width, 520)
                XCTAssertLessThanOrEqual(layout.expanded.height, size.height)
            }
        }
    }
}
