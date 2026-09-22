import XCTest
import DockCore
@testable import AccountDock

final class ProfileMessageTests: XCTestCase {
    @MainActor func testRetryFindsTheSameAccountAfterRenameAndReorder() {
        let model = DockModel(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let work = Profile(id: "profile-work", name: "Work", color: "377CF6")
        let personal = Profile(id: "profile-personal", name: "Personal", color: "009B87")
        model.preferences.profiles = [work, personal]
        model.showProfileMessage("Could not open Work.", for: work)
        var renamed = work
        renamed.name = "Client Work"
        model.preferences.profiles = [personal, renamed]
        var selected: Profile?
        model.retryMessage { selected = $0 }
        XCTAssertEqual(selected, renamed)
        XCTAssertNil(model.message)
        XCTAssertNil(model.messageRecovery)
    }

    @MainActor func testRemovedAccountAndReplacedOrDismissedNoticesCannotRetryAnOldAction() {
        let model = DockModel(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let work = Profile(id: "profile-work", name: "Work", color: "377CF6")
        model.preferences.profiles = [work]
        for replacement in ["Another operation failed.", nil] {
            model.showProfileMessage("Could not open Work.", for: work)
            model.message = replacement
            model.retryMessage { _ in XCTFail("A replaced notice must not retain its old recovery action") }
        }
        model.showProfileMessage("Could not open Work.", for: work)
        model.preferences.profiles = []
        model.retryMessage { _ in XCTFail("A removed account must not be opened") }
    }

    @MainActor func testReopenThatActuallyActivatesDoesNotLeaveAnEarlyWarning() {
        let model = DockModel(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let work = Profile(id: "profile-work", name: "Work", color: "377CF6")
        model.completeActivation(of: work, attemptID: model.messageID, accepted: false, reopened: true, isActive: true)
        XCTAssertNil(model.message)
        model.completeActivation(of: work, attemptID: model.messageID, accepted: false, reopened: true, isActive: false)
        XCTAssertEqual(model.messageRecovery?.profileID, work.id)
        XCTAssertEqual(model.messageRecovery?.title, "Try Again")
    }

    @MainActor func testDelayedActivationFailureCannotReplaceANewerNotice() {
        let model = DockModel(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let work = Profile(id: "profile-work", name: "Work", color: "377CF6")
        let attemptID = model.messageID
        model.message = "A newer operation needs attention."
        model.completeActivation(of: work, attemptID: attemptID, accepted: false, reopened: false, isActive: false)
        XCTAssertEqual(model.message, "A newer operation needs attention.")
        XCTAssertNil(model.messageRecovery)
    }
}
