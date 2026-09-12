import XCTest
@testable import AccountDock

final class UsageCredentialsTests: XCTestCase {
    private func auth(account: String = "fixture-account", subject: String = "fixture-user", access: String = "fixture-access", mode: String = "chatgpt") throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["sub": subject]).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": mode, "tokens": ["access_token": access, "account_id": account, "id_token": "e30.\(body).fixture"]])
    }

    func testProfileAccountAndUserAllContributeToIdentity() throws {
        let path = URL(fileURLWithPath: "/fixture/profile-a/auth.json")
        let first = try UsageCredentials.parse(data: auth(), source: path)
        let moved = try UsageCredentials.parse(data: auth(), source: URL(fileURLWithPath: "/fixture/profile-b/auth.json"))
        let workspace = try UsageCredentials.parse(data: auth(account: "other-workspace"), source: path)
        let user = try UsageCredentials.parse(data: auth(subject: "other-user"), source: path)
        XCTAssertEqual(Set([first.identity, moved.identity, workspace.identity, user.identity]).count, 4)
        XCTAssertFalse(first.identity.contains("fixture-user"))
    }

    func testRoutineTokenRotationPreservesAccountIdentity() throws {
        let path = URL(fileURLWithPath: "/fixture/profile/auth.json")
        let first = try UsageCredentials.parse(data: auth(access: "old-access"), source: path)
        let refreshed = try UsageCredentials.parse(data: auth(access: "new-access"), source: path)
        XCTAssertEqual(first.identity, refreshed.identity)
        XCTAssertNotEqual(first.accessToken, refreshed.accessToken)
    }

    func testMissingIdentityApiKeysAndHeaderInjectionAreRejected() throws {
        let path = URL(fileURLWithPath: "/fixture/profile/auth.json")
        XCTAssertThrowsError(try UsageCredentials.parse(data: Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture"}}"#.utf8), source: path))
        XCTAssertThrowsError(try UsageCredentials.parse(data: auth(mode: "apikey"), source: path))
        XCTAssertThrowsError(try UsageCredentials.parse(data: auth(account: "account\r\nInjected: value"), source: path))
    }
}
