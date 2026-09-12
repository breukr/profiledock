import XCTest
@testable import DockCore

final class ActivityFeedbackTests: XCTestCase {
    func testNoticesKeepEnvironmentNamesWithTheirOwnStateAndQueueBothKinds() {
        var batch = ActivityCueBatch()
        batch.insert(ActivityEvent(profileID: "personal", signal: .finished))
        batch.insert(ActivityEvent(profileID: "work", signal: .needsInput))
        batch.insert(ActivityEvent(profileID: "personal", signal: .finished))
        let input = batch.next()
        XCTAssertEqual(input?.signal, .needsInput)
        XCTAssertEqual(input?.profileIDs, ["work"])
        let done = batch.next()
        XCTAssertEqual(done?.signal, .finished)
        XCTAssertEqual(done?.profileIDs, ["personal"])
        XCTAssertNil(batch.next())
        batch.insert(ActivityEvent(profileID: "work", signal: .needsInput))
        batch.insert(ActivityEvent(profileID: "work", signal: .finished))
        XCTAssertEqual(batch.next()?.signal, .finished, "Do not show an input request that was already resolved")
    }

    func testNoticeCoalescesMatchingEnvironmentsAndMorphsFromTheStrip() {
        var batch = ActivityCueBatch()
        batch.insert(ActivityEvent(profileID: "work", signal: .finished))
        batch.insert(ActivityEvent(profileID: "personal", signal: .finished))
        XCTAssertEqual(batch.next()?.profileIDs, ["personal", "work"])
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        for x in [screen.minX + 12, screen.midX, screen.maxX - 206] {
            let strip = CGRect(x: x, y: screen.minY + 20, width: 194, height: 32)
            let cue = ActivityCueLayout(screen: screen, obstacle: strip, floating: true, nameWidth: 180)
            XCTAssertTrue(screen.contains(cue.frame)); XCTAssertTrue(cue.frame.contains(strip))
            XCTAssertEqual(cue.origin, strip)
            XCTAssertTrue(cue.frame.contains(cue.left)); XCTAssertTrue(cue.frame.contains(cue.right))
            XCTAssertLessThan(cue.left.maxX, cue.right.minX)
        }
    }
    func testWaitingTakesPriorityWhenAnotherTaskIsWorking() {
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(unread: 3, working: 2, waiting: 1, liveAvailable: true, appOpen: true), isOpen: true), .waiting)
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(unread: 3, working: 2, liveAvailable: true, appOpen: true), isOpen: true), .working)
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(unread: 3, liveAvailable: true, appOpen: true), isOpen: true), .unread)
    }
    func testUnavailableIsNeverShownAsIdle() {
        XCTAssertEqual(ProfileActivityState(summary: nil, isOpen: true), .unknown)
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(appOpen: true), isOpen: true), .unknown)
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(liveAvailable: true, appOpen: true), isOpen: true), .idle)
        XCTAssertEqual(ProfileActivityState(summary: nil, isOpen: false), .closed)
        XCTAssertEqual(ProfileActivityState(summary: ActivitySummary(unread: 2), isOpen: false), .unread)
    }
    func testOnlyNewLiveTransitionsAlert() {
        XCTAssertEqual(ActivitySignal.transition(from: .working, to: .waiting, isLivePatch: true), .needsInput)
        XCTAssertEqual(ActivitySignal.transition(from: .working, to: .idle, isLivePatch: true), .finished)
        XCTAssertEqual(ActivitySignal.transition(from: .waiting, to: .idle, isLivePatch: true), .finished)
        for previous in [TaskActivity.working, .waiting, .idle, .unavailable] {
            XCTAssertNil(ActivitySignal.transition(from: previous, to: .waiting, isLivePatch: false), "Startup and reconnect snapshots must stay quiet")
        }
        XCTAssertNil(ActivitySignal.transition(from: .unavailable, to: .idle, isLivePatch: true))
        XCTAssertNil(ActivitySignal.transition(from: .waiting, to: .working, isLivePatch: true))
        XCTAssertNil(ActivitySignal.transition(from: .waiting, to: .waiting, isLivePatch: true))
    }
    func testCuesRemainBesideNotchOrMenuBarAcrossDisplaySizesAndOrigins() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -3008, y: -100, width: 3008, height: 1692), CGRect(x: 1512, y: 982, width: 1920, height: 1080)] {
            for height in [24.0, 32, 38] {
                let obstacle = CGRect(x: screen.midX - 95, y: screen.maxY - height, width: 190, height: height)
                let layout = ActivityCueLayout(screen: screen, obstacle: obstacle)
                XCTAssertTrue(screen.contains(layout.left)); XCTAssertTrue(screen.contains(layout.right))
                XCTAssertLessThan(layout.left.maxX, obstacle.minX)
                XCTAssertGreaterThan(layout.right.minX, obstacle.maxX)
                XCTAssertLessThanOrEqual(layout.left.height, height)
            }
        }
    }
    func testDownloadProgressHandlesUnknownLengthsAndBounds() {
        XCTAssertNil(DownloadProgress(received: 20, expected: -1).fraction)
        XCTAssertEqual(DownloadProgress(received: 50, expected: 100).fraction, 0.5)
        XCTAssertEqual(DownloadProgress(received: 150, expected: 100).fraction, 1)
        XCTAssertEqual(DownloadProgress(received: -1, expected: 100).fraction, 0)
    }
}
