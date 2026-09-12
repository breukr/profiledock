import XCTest
@testable import DockCore

// Synthetic service fixtures only. No real account identifiers, tokens, or captured responses.
final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func window(_ duration: Int, used: Double) -> [String: Any] {
        ["limit_window_seconds": duration, "used_percent": used, "reset_at": 1_790_000_000]
    }
    private func response(primary: Any = NSNull(), secondary: Any = NSNull(), count: Any = NSNull(), account: String = "fixture-account") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["account_id": account, "plan_type": "fixture-plan", "rate_limit": ["primary_window": primary, "secondary_window": secondary], "rate_limit_reset_credits": ["available_count": count, "applicable_available_count": 0]])
    }
    private func parse(_ data: Data, resets: Data? = nil) throws -> UsageSnapshot {
        try UsageParser.parse(usage: data, resets: resets, expectedAccount: "fixture-account", identity: "fixture-identity", fetchedAt: now)
    }

    func testWeeklyOnlyPrimaryIsNotMislabeledAsFiveHours() throws {
        let result = try parse(response(primary: window(604800, used: 75), count: 1))
        XCTAssertEqual(result.windows.map(\.title), ["Week"])
        XCTAssertEqual(result.windows.first?.remainingPercent, 25)
        XCTAssertEqual(result.bankedResets, 1)
        XCTAssertEqual(result.applicableResets, 0)
    }

    func testBothWindowsAreKeptAndSortedWithWeeklyFirst() throws {
        let result = try parse(response(primary: window(18000, used: 30), secondary: window(604800, used: 40)))
        XCTAssertEqual(result.windows.map(\.title), ["Week", "5 hours"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [60, 70])
        XCTAssertEqual(result.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testUnknownCountsAndWindowsNeverBecomeZeroUsageOrZeroResets() throws {
        let missing = try parse(response())
        XCTAssertTrue(missing.windows.isEmpty)
        XCTAssertNil(missing.bankedResets)
        XCTAssertNil(missing.resetExpiries)
        let zero = try parse(response(primary: window(604800, used: 0), count: 0))
        XCTAssertEqual(zero.windows.first?.remainingPercent, 100)
        XCTAssertEqual(zero.bankedResets, 0)
    }

    func testOtherAccountAndMissingIdentityAreRejected() throws {
        XCTAssertThrowsError(try parse(response(primary: window(604800, used: 10), account: "other-account")))
        XCTAssertThrowsError(try parse(Data(#"{"rate_limit":null}"#.utf8)))
    }

    func testMalformedWindowDoesNotDiscardOtherValidWindow() throws {
        let result = try parse(response(primary: ["used_percent": "unavailable"], secondary: window(604800, used: 100)))
        XCTAssertEqual(result.windows.map(\.title), ["Week"])
        XCTAssertEqual(result.windows.first?.remainingPercent, 0)
        XCTAssertTrue(result.hasUnparsedWindows)
    }

    func testInvalidNegativeReadingIsUnknownAndOverLimitIsClamped() throws {
        let invalid = try parse(response(primary: window(604800, used: -5)))
        XCTAssertTrue(invalid.windows.isEmpty)
        XCTAssertTrue(invalid.hasUnparsedWindows)
        let exceeded = try parse(response(primary: window(604800, used: 120)))
        XCTAssertEqual(exceeded.windows.first?.remainingPercent, 0)
    }

    func testInventoryCountIsAuthoritativeAndExpiryRowsDoNotInventCount() throws {
        let inventory = Data(#"{"available_count":3,"credits":[{"status":"available","expires_at":"2027-01-01T00:00:00.123456Z"},{"status":"redeemed","expires_at":"2027-02-01T00:00:00Z"},{"status":"available","expires_at":"2020-01-01T00:00:00Z"}]}"#.utf8)
        let result = try parse(response(primary: window(604800, used: 60), count: 2), resets: inventory)
        XCTAssertEqual(result.bankedResets, 3)
        XCTAssertEqual(result.resetExpiries?.count, 1)
        let empty = try parse(response(count: 2), resets: Data(#"{"available_count":0,"credits":[]}"#.utf8))
        XCTAssertEqual(empty.bankedResets, 0)
        XCTAssertEqual(empty.resetExpiries, [])
    }

    func testUnavailableInventoryRetainsKnownSummaryCountOnly() throws {
        let result = try parse(response(count: 2), resets: Data("unavailable".utf8))
        XCTAssertEqual(result.bankedResets, 2)
        XCTAssertNil(result.resetExpiries)
    }
}
