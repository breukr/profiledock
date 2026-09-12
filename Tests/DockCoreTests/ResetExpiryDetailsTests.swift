import XCTest
import DockCore

final class ResetExpiryDetailsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testCountdownChangesAcrossDaysHoursMinutesAndExpiry() {
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now.addingTimeInterval(6 * 86400 + 20 * 3600), now: now), "Expires in 6d 20h")
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now.addingTimeInterval(3660), now: now), "Expires in 1h 1m")
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now.addingTimeInterval(120), now: now), "Expires in 2 min")
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now.addingTimeInterval(30), now: now), "Expires within 1 min")
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now, now: now), "Expired")
        XCTAssertEqual(ResetExpiryDetails.countdown(until: now.addingTimeInterval(-30), now: now), "Expired")
    }

    func testSoonestFirstKeepsSeparateResetsWithTheSameExpiryAndExposesMissingDetails() {
        let first = now.addingTimeInterval(3600), later = now.addingTimeInterval(86400)
        let details = ResetExpiryDetails(count: 4, expiries: [later, first, first])
        XCTAssertEqual(details.dates, [first, first, later])
        XCTAssertEqual(details.message, "1 reset: expiry unknown.")
        XCTAssertNil(ResetExpiryDetails(count: 3, expiries: [later, first, first]).message)
    }

    func testUnknownZeroAndInconsistentInventoryStayDistinct() {
        XCTAssertEqual(ResetExpiryDetails(count: nil, expiries: nil).message, "Reset count unknown.")
        XCTAssertEqual(ResetExpiryDetails(count: 0, expiries: nil).message, "No saved resets.")
        XCTAssertEqual(ResetExpiryDetails(count: 2, expiries: nil).message, "2 resets: expiry unknown.")
        let inconsistent = ResetExpiryDetails(count: 1, expiries: [now, now])
        XCTAssertEqual(inconsistent.dates, [])
        XCTAssertEqual(inconsistent.message, "Expiry times are refreshing.")
    }
}
