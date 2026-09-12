import XCTest
import ServiceManagement
@testable import AccountDock

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registrations = 0
    var unregistrations = 0
    var failRegistration = false
    init(_ status: SMAppService.Status) { self.status = status }
    func register() throws {
        registrations += 1
        if failRegistration { throw NSError(domain: "LoginTest", code: 1) }
        status = .enabled
    }
    func unregister() throws { unregistrations += 1; status = .notRegistered }
}

final class LoginItemTests: XCTestCase {
    @MainActor func testFirstRegistrationHandlesMissingAndUnregisteredServices() async {
        for initial in [SMAppService.Status.notFound, .notRegistered] {
            let service = FakeLoginService(initial)
            let model = LoginItemModel(service: service)
            model.setEnabled(true)
            XCTAssertTrue(model.enabled)
            XCTAssertEqual(service.registrations, 1)
            model.setEnabled(true)
            XCTAssertEqual(service.registrations, 1)
        }
    }

    @MainActor func testUserDeniedPermissionIsNotSilentlyReenabled() async {
        let service = FakeLoginService(.requiresApproval)
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        XCTAssertFalse(model.enabled)
        XCTAssertTrue(model.requiresApproval)
        XCTAssertEqual(service.registrations, 0)
    }

    @MainActor func testDisableAndRefreshFollowSystemState() async {
        let service = FakeLoginService(.enabled)
        let model = LoginItemModel(service: service)
        model.setEnabled(false)
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(service.unregistrations, 1)
        model.setEnabled(false)
        XCTAssertEqual(service.unregistrations, 1)
        service.status = .enabled
        model.refresh()
        XCTAssertTrue(model.enabled)
    }

    @MainActor func testRegistrationFailureIsVisibleAndDoesNotClaimEnabled() async {
        let service = FakeLoginService(.notFound)
        service.failRegistration = true
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        XCTAssertFalse(model.enabled)
        XCTAssertNotNil(model.error)
    }
}
