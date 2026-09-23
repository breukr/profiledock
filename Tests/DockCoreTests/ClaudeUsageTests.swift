import XCTest
@testable import DockCore

final class ClaudeUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_164_800)
    func testAccountWindowsAndUnavailableResetSurface() throws {
        let data = Data(#"{"five_hour":{"utilization":35,"resets_at":"2026-09-23T13:59:59.737374+00:00"},"seven_day":{"utilization":10,"resets_at":"2026-09-25T22:59:59Z"},"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data, identity: "fixture", plan: "max", fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [90, 65])
        XCTAssertEqual(snapshot.windows.map(\.title), ["Week", "5 hours"])
        XCTAssertNotNil(snapshot.windows.last?.resetsAt)
        XCTAssertNil(snapshot.bankedResets, "An unavailable reset surface does not mean zero resets")
    }

    func testMissingAndInvalidMeasurementsNeverBecomeZeroUsage() throws {
        for payload in [#"{}"#, #"{"five_hour":{"utilization":false,"resets_at":"2026-09-25T00:00:00Z"}}"#, #"{"five_hour":{"utilization":0,"resets_at":"bad"}}"#] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(Data(payload.utf8), identity: "fixture", plan: nil, fetchedAt: now))
        }
    }

    func testBankedResetsIncludeSavedGrantNotYetUsableAndExcludeExpiredOrFutureGrants() throws {
        let grant: [String: Any] = ["id": "saved", "resets_left": 1, "starts_at": "2026-01-01T00:00:00Z", "ends_at": "2027-01-01T00:00:00Z", "usable_now": false, "use_requires_limit": true]
        var expired = grant; expired["id"] = "expired"; expired["ends_at"] = "2026-01-02T00:00:00Z"
        var future = grant; future["id"] = "future"; future["starts_at"] = "2027-01-01T00:00:00Z"
        let inventory = try XCTUnwrap(ClaudeUsageParser.resets(["eligible": true, "grants": [grant, expired, future]], now: now))
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory.usable, 0)
        XCTAssertEqual(inventory.expiries.count, 1)
        XCTAssertNil(ClaudeUsageParser.resets(["eligible": true, "grants": [grant, grant]], now: now))
        var malformed = grant; malformed["resets_left"] = true
        XCTAssertNil(ClaudeUsageParser.resets(["eligible": true, "grants": [malformed]], now: now))
        XCTAssertEqual(ClaudeUsageParser.resets(["eligible": true, "grants": []], now: now)?.count, 0)
        XCTAssertNil(ClaudeUsageParser.resets(["eligible": true], now: now))
    }
}
