import XCTest
@testable import DockCore

final class ActivityTests: XCTestCase {
    func testSnapshotAndUnrelatedPatchesAdvanceRevisionWithoutRetainingTranscript() {
        var state = ActivityProjection()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 4, "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": []], "hasUnreadTurn": false, "turns": ["private content"]]]))
        XCTAssertEqual(state.activity, .working)
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 4, "revision": 5, "patches": [["op": "add", "path": ["turns", 0, "text"], "value": "discard this"]]]))
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.activity, .working)
        XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 5, "revision": 6, "patches": [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]], ["op": "replace", "path": ["hasUnreadTurn"], "value": true]]]))
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.unread, true)
    }
    func testApprovalAndInputAreWaitingThenResumeAfterFlagRemoval() {
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            var state = ActivityProjection()
            XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": [flag]]]]))
            XCTAssertEqual(state.activity, .waiting)
            XCTAssertTrue(state.apply(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]]]]))
            XCTAssertEqual(state.activity, .working)
        }
    }
    func testRevisionGapCannotLeaveAStuckSpinner() {
        var state = ActivityProjection()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 2, "conversationState": ["threadRuntimeStatus": ["type": "active"]]]))
        XCTAssertFalse(state.apply(["type": "patches", "baseRevision": 3, "revision": 4, "patches": []]))
        XCTAssertEqual(state.activity, .unavailable)
        XCTAssertNil(state.revision)
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 9, "conversationState": ["threadRuntimeStatus": ["type": "idle"]]]))
        XCTAssertEqual(state.activity, .idle)
    }
    func testFragmentedAndConcatenatedIPCFrames() throws {
        let first = try ActivityFrames.encode(["type": "first"])
        let second = try ActivityFrames.encode(["type": "second"])
        var decoder = ActivityFrames()
        XCTAssertTrue(try decoder.append(Data(first.prefix(3))).isEmpty)
        XCTAssertEqual(try decoder.append(Data(first.dropFirst(3)) + second).compactMap { $0["type"] as? String }, ["first", "second"])
    }
    func testOversizedFrameRejectedBeforeItsBodyArrives() {
        var decoder = ActivityFrames()
        XCTAssertThrowsError(try decoder.append(Data([255, 255, 255, 255])))
    }
    func testUnreadCountDoesNotTurnUnknownIntoZeroAndCapsVisualBadgeOnly() {
        XCTAssertNil(ActivitySummary().unread)
        XCTAssertNil(ActivitySummary(unread: 0).badge)
        XCTAssertEqual(ActivitySummary(unread: 3).badge, "3")
        let many = ActivitySummary(unread: 418)
        XCTAssertEqual(many.badge, "99+")
        XCTAssertEqual(many.unread, 418)
    }
}
