import XCTest
import DockCore
@testable import AccountDock

final class AccountSignInTests: XCTestCase {
    func testCodexReconnectUsesOnlySelectedProfileAndFileCredentials() throws {
        let home = URL(fileURLWithPath: "/tmp/home with 'quotes' and $symbols")
        let profile = Profile(id: "lamboo", name: "Name ; $(unsafe)", color: "377CF6")
        let command = try AccountSignInCommand.make(profile: profile, home: home, executableExists: { $0 == "/opt/homebrew/bin/codex" })
        XCTAssertEqual(command.environment["CODEX_HOME"], home.appendingPathComponent(".codex-lamboo").path)
        XCTAssertEqual(command.arguments, ["-c", "cli_auth_credentials_store=\"file\"", "login"])
        XCTAssertNil(command.environment["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(command.environment["OPENAI_API_KEY"])
        XCTAssertNil(command.environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertFalse(command.arguments.contains(profile.name))
    }

    func testClaudeReconnectUsesSubscriptionLoginAndNoCodexOverrides() throws {
        let home = URL(fileURLWithPath: "/tmp/test")
        var profile = Profile(id: "claude", name: "Claude", color: "377CF6"); profile.provider = .claude
        let command = try AccountSignInCommand.make(profile: profile, home: home, executableExists: { $0 == home.appendingPathComponent(".local/bin/claude").path })
        XCTAssertEqual(command.arguments, ["auth", "login", "--claudeai"])
        XCTAssertNil(command.environment["CODEX_HOME"])
        XCTAssertNil(command.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(command.environment["ANTHROPIC_API_KEY"])
    }

    func testInvalidAndUnsupportedProfilesCannotStartLogin() {
        XCTAssertThrowsError(try AccountSignInCommand.make(profile: Profile(id: "../other", name: "Invalid", color: "377CF6"), home: URL(fileURLWithPath: "/tmp"), executableExists: { _ in true }))
        var terminal = Profile(id: "terminal", name: "Terminal", color: "377CF6"); terminal.provider = .terminal
        XCTAssertThrowsError(try AccountSignInCommand.make(profile: terminal, home: URL(fileURLWithPath: "/tmp"), executableExists: { _ in true }))
        XCTAssertThrowsError(try AccountSignInCommand.make(profile: Profile(id: "a", name: "A", color: "377CF6"), home: URL(fileURLWithPath: "/tmp"), executableExists: { _ in false }))
    }

    func testRunnerSuccessFailureTimeoutAndCancellation() async throws {
        func command(_ path: String, _ arguments: [String] = []) -> AccountSignInCommand {
            AccountSignInCommand(executable: URL(fileURLWithPath: path), arguments: arguments, environment: [:])
        }
        try await AccountSignInRunner().signIn(command("/usr/bin/true"))
        do { try await AccountSignInRunner().signIn(command("/usr/bin/false")); XCTFail("Nonzero exit must fail") }
        catch { XCTAssertEqual((error as? AccountSignInError)?.message, AccountSignInError.failed.message) }
        do { try await AccountSignInRunner(timeout: 0.05).signIn(command("/bin/sleep", ["10"])); XCTFail("Must time out") }
        catch { XCTAssertEqual((error as? AccountSignInError)?.message, AccountSignInError.timedOut.message) }
        let task = Task { try await AccountSignInRunner().signIn(command("/bin/sleep", ["10"])) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let beforeStart = Task { try await AccountSignInRunner().signIn(command("/bin/sleep", ["10"])) }
        beforeStart.cancel()
        do { try await beforeStart.value; XCTFail("Must cancel before launching") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
