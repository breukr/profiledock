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

    func testOnlySeparateClaudeAccountsSignInToTheirOwnConfiguration() throws {
        let home = URL(fileURLWithPath: "/tmp/test"), claude = home.appendingPathComponent(".local/bin/claude").path
        var separate = Profile(id: "profile-work", name: "Work", color: "377CF6"); separate.provider = .claude; separate.separateClaudeAccount = true
        let command = try AccountSignInCommand.make(profile: separate, home: home, executableExists: { $0 == claude })
        XCTAssertEqual(command.arguments, ["auth", "login", "--claudeai"])
        XCTAssertEqual(command.environment["CLAUDE_CONFIG_DIR"], separate.claudeConfigPath(in: home))
        XCTAssertEqual(command.environment["CLAUDE_CONFIG_DIR"], home.appendingPathComponent("Library/Application Support/Account Dock/Companions/profile-work/claude-config").path)
        var shared = separate; shared.separateClaudeAccount = nil
        XCTAssertNil(try AccountSignInCommand.make(profile: shared, home: home, executableExists: { $0 == claude }).environment["CLAUDE_CONFIG_DIR"])
        var code = Profile(id: "project", name: "Project", color: "377CF6"); code.provider = .claudeCode
        XCTAssertNil(try AccountSignInCommand.make(profile: code, home: home, executableExists: { $0 == claude }).environment["CLAUDE_CONFIG_DIR"])
        let codex = try AccountSignInCommand.make(profile: Profile(id: "lamboo", name: "Lamboo", color: "377CF6"), home: home, executableExists: { _ in true })
        XCTAssertNil(codex.environment["CLAUDE_CONFIG_DIR"])
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


    func testClaudeReconnectPrefillsTheClaudeAppsOwnAccount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sign-in-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ json: String, to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: file)
        }
        let claude = home.appendingPathComponent(".local/bin/claude").path
        var shared = Profile(id: "claude", name: "Claude", color: "377CF6"); shared.provider = .claude
        var separate = shared; separate.id = "profile-work"; separate.separateClaudeAccount = true
        try write(#"{"lastKnownAccountUuid":"aaaaaaaa-0000-4000-8000-000000000001"}"#, to: home.appendingPathComponent("Library/Application Support/Claude/config.json"))
        try write(#"{"lastKnownAccountUuid":"bbbbbbbb-0000-4000-8000-000000000002"}"#, to: separate.claudeUserDataDirectory(in: home)!.appendingPathComponent("config.json"))
        try write(#"{"oauthAccount":{"accountUuid":"aaaaaaaa-0000-4000-8000-000000000001","emailAddress":"one@example.com"}}"#, to: home.appendingPathComponent(".claude.json"))
        try write(#"{"oauthAccount":{"accountUuid":"bbbbbbbb-0000-4000-8000-000000000002","emailAddress":"two@example.com"}}"#, to: separate.claudeConfigDirectory(in: home)!.appendingPathComponent(".claude.json"))
        XCTAssertEqual(try AccountSignInCommand.make(profile: shared, home: home, executableExists: { $0 == claude }).arguments, ["auth", "login", "--claudeai", "--email=one@example.com"])
        let work = try AccountSignInCommand.make(profile: separate, home: home, executableExists: { $0 == claude })
        XCTAssertEqual(work.arguments, ["auth", "login", "--claudeai", "--email=two@example.com"])
        XCTAssertEqual(work.environment["CLAUDE_CONFIG_DIR"], separate.claudeConfigPath(in: home))
        // Without a matching record there is nothing to pre-fill.
        try write(#"{"oauthAccount":{"accountUuid":"bbbbbbbb-0000-4000-8000-000000000002","emailAddress":"two@example.com"}}"#, to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(try AccountSignInCommand.make(profile: shared, home: home, executableExists: { $0 == claude }).arguments, ["auth", "login", "--claudeai"])
    }

    func testClaudeCLIIsFoundInNvmDesktopCopyOrLoginShellWithNodeOnPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sign-in-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var profile = Profile(id: "claude", name: "Claude", color: "377CF6"); profile.provider = .claude
        for folder in [".nvm/versions/node/v18.20.0/bin", ".nvm/versions/node/v22.11.0/bin", "Library/Application Support/Claude/claude-code/2.1.9/abc/claude.app/Contents/MacOS",
                       "Library/Application Support/Claude/claude-code/2.1.10/def/claude.app/Contents/MacOS"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let candidates = AccountSignInCommand.claudeCandidates(home: home)
        let nvm = home.appendingPathComponent(".nvm/versions/node/v22.11.0/bin/claude").path
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code/2.1.10/def/claude.app/Contents/MacOS/claude").path
        XCTAssertLessThan(candidates.firstIndex(of: nvm)!, candidates.firstIndex(of: home.appendingPathComponent(".nvm/versions/node/v18.20.0/bin/claude").path)!, "Newest Node first")
        XCTAssertLessThan(candidates.firstIndex(of: desktop)!, candidates.firstIndex(of: home.appendingPathComponent("Library/Application Support/Claude/claude-code/2.1.9/abc/claude.app/Contents/MacOS/claude").path)!)
        var asked = false
        let fromNvm = try AccountSignInCommand.make(profile: profile, home: home, executableExists: { $0 == nvm }, shellLookup: { asked = true; return .init() })
        XCTAssertEqual(fromNvm.executable.path, nvm)
        XCTAssertTrue(fromNvm.environment["PATH"]!.hasPrefix((nvm as NSString).deletingLastPathComponent + ":"), "The npm script finds its node")
        XCTAssertFalse(asked, "The login shell is only asked when no known location has claude")
        XCTAssertEqual(try AccountSignInCommand.make(profile: profile, home: home, executableExists: { $0 == desktop }, shellLookup: { .init() }).executable.path, desktop)
        // Last resort: the login shell's PATH, with its node, but only executable absolute paths.
        let shell = AccountSignInCommand.ShellTools(claude: "/fixture/custom/bin/claude", node: "/fixture/node/bin/node")
        let found = try AccountSignInCommand.make(profile: profile, home: home, executableExists: { $0.hasPrefix("/fixture/") }, shellLookup: { shell })
        XCTAssertEqual(found.executable.path, "/fixture/custom/bin/claude")
        XCTAssertEqual(found.environment["PATH"], "/fixture/custom/bin:/fixture/node/bin:" + AccountSignInCommand.basePath)
        XCTAssertThrowsError(try AccountSignInCommand.make(profile: profile, home: home, executableExists: { _ in false }, shellLookup: { shell }))
    }
}
