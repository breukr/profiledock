import XCTest
@testable import DockCore

final class HoverHoldTests: XCTestCase {
    func testHeldIslandStaysOpenUntilDeadlineThenCollapsesNormally() {
        var intent = HoverIntent()
        intent.hold(until: 10)
        XCTAssertTrue(intent.update(inside: false, now: 5))
        XCTAssertEqual(intent.collapseDeadline, 10, "The controller schedules its collapse check at the hold deadline")
        XCTAssertTrue(intent.update(inside: false, now: 10), "The ordinary exit delay still applies")
        XCTAssertFalse(intent.update(inside: false, now: 10 + HoverIntent.exitDelay))
    }
    func testPointerTakesOverAndReleaseCollapsesAfterExitDelay() {
        var intent = HoverIntent()
        intent.hold(until: 100)
        XCTAssertTrue(intent.update(inside: true, now: 1))
        XCTAssertNil(intent.holdUntil)
        XCTAssertTrue(intent.update(inside: false, now: 2))
        XCTAssertFalse(intent.update(inside: false, now: 2 + HoverIntent.exitDelay), "Leaving after hovering collapses without waiting for the old hold")
        intent.hold(until: 100); intent.releaseHold()
        XCTAssertTrue(intent.update(inside: false, now: 3))
        XCTAssertFalse(intent.update(inside: false, now: 3 + HoverIntent.exitDelay))
    }
}
