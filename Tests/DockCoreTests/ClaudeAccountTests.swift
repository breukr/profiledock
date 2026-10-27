import XCTest
@testable import DockCore

final class ClaudeAccountTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")
    private func claude(_ id: String, separate: Bool) -> Profile {
        var profile = Profile(id: id, name: id, color: "C97B5D"); profile.provider = .claude
        if separate { profile.separateClaudeAccount = true }
        return profile
    }

    func testSeparateAccountGetsItsOwnFoldersAndLaunchArguments() throws {
        let separate = claude("profile-work", separate: true), shared = claude("profile-claude", separate: false)
        let companions = "/Users/example/Library/Application Support/Account Dock/Companions/profile-work"
        XCTAssertEqual(separate.claudeConfigDirectory(in: home)?.path, companions + "/claude-config")
        XCTAssertEqual(separate.claudeUserDataDirectory(in: home)?.path, companions + "/electron-user-data")
        let app = URL(fileURLWithPath: "/Applications/Claude.app")
        XCTAssertEqual(ProfileLaunch.claudeArguments(profile: separate, home: home, application: app),
                       ["-n", "--env", "CLAUDE_CONFIG_DIR=\(companions)/claude-config", "-a", app.path, "--args", "--user-data-dir=\(companions)/electron-user-data"])
        XCTAssertNil(shared.claudeConfigDirectory(in: home))
        XCTAssertNil(ProfileLaunch.claudeArguments(profile: shared, home: home, application: app))
        // The flag means nothing outside Claude Desktop, and older saved profiles decode without it.
        var codex = Profile(id: "test", name: "Test", color: "123456"); codex.separateClaudeAccount = true
        XCTAssertNil(codex.claudeConfigDirectory(in: home))
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"c","name":"Claude","color":"C97B5D","provider":"claude"}"#.utf8))
        XCTAssertFalse(decoded.usesSeparateClaudeAccount)
    }

    func testRunningClaudeInstancesMapOnlyToTheirOwnAccount() {
        let profiles = [Profile(id: "default", name: "Personal", color: "123456"), claude("shared", separate: false), claude("work", separate: true)]
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let work = claude("work", separate: true).claudeUserDataDirectory(in: home)!.path
        XCTAssertEqual(ProcessIdentity.claudeProfileID(arguments: [executable], profiles: profiles, home: home), "shared")
        XCTAssertEqual(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir=/Users/example/Library/Application Support/Claude"], profiles: profiles, home: home), "shared")
        XCTAssertEqual(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir=\(work)"], profiles: profiles, home: home), "work")
        XCTAssertEqual(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir", work + "/"], profiles: profiles, home: home), "work")
        XCTAssertNil(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir=/tmp/unknown"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir=relative"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.claudeProfileID(arguments: [executable, "--user-data-dir"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.claudeProfileID(arguments: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.claudeProfileID(arguments: [executable], profiles: [claude("work", separate: true)], home: home), "Another account's tile never claims the shared instance")
        // A separate Claude folder is never mistaken for a ChatGPT profile.
        XCTAssertEqual(ProcessIdentity.profileID(arguments: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "--user-data-dir=\(work)"], profiles: profiles, home: home), nil)
    }

    func testSessionsRecordTheirConfigurationAndKeepSeparateStatusLines() throws {
        XCTAssertNil(ClaudeBridgeSettings.configDirectory(environment: [:], home: home))
        XCTAssertNil(ClaudeBridgeSettings.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "relative"], home: home))
        XCTAssertNil(ClaudeBridgeSettings.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/Users/example/.claude/"], home: home))
        XCTAssertEqual(ClaudeBridgeSettings.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/fixture/work/"], home: home), "/fixture/work")
        let shared = ClaudeBridgeSettings.originalStatuslineName(configDirectory: nil)
        let work = ClaudeBridgeSettings.originalStatuslineName(configDirectory: "/fixture/work")
        XCTAssertEqual(shared, "original-statusline.json")
        XCTAssertNotEqual(work, shared)
        XCTAssertNotEqual(work, ClaudeBridgeSettings.originalStatuslineName(configDirectory: "/fixture/other"))
        XCTAssertEqual(work, ClaudeBridgeSettings.originalStatuslineName(configDirectory: "/fixture/work"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeSessionStore(home: root)
        _ = try store.record(payload: ["session_id": "work-session", "cwd": "/project", "hook_event_name": "UserPromptSubmit"], statusline: false, process: nil, tty: nil, configDirectory: "/fixture/work")
        _ = try store.record(payload: ["session_id": "shared-session", "cwd": "/project", "hook_event_name": "UserPromptSubmit"], statusline: false, process: nil, tty: nil)
        let sessions = Dictionary(uniqueKeysWithValues: store.read().map { ($0.id, $0.configDirectory) })
        XCTAssertEqual(sessions["work-session"], .some("/fixture/work"))
        XCTAssertEqual(sessions["shared-session"], .some(nil))
    }


    func testDesktopAccountAndEmailComeFromEachInstancesOwnFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ json: String, to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: file)
        }
        let shared = claude("shared", separate: false), separate = claude("profile-work", separate: true)
        var code = Profile(id: "project", name: "Project", color: "C97B5D"); code.provider = .claudeCode
        XCTAssertNil(ClaudeDesktopAccount.accountID(for: shared, home: home), "No Desktop sign-in yet")
        try write(#"{"lastKnownAccountUuid":"AAAAAAAA-0000-4000-8000-000000000001"}"#, to: home.appendingPathComponent("Library/Application Support/Claude/config.json"))
        try write(#"{"lastKnownAccountUuid":"bbbbbbbb-0000-4000-8000-000000000002"}"#, to: separate.claudeUserDataDirectory(in: home)!.appendingPathComponent("config.json"))
        XCTAssertEqual(ClaudeDesktopAccount.accountID(for: shared, home: home), "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(ClaudeDesktopAccount.accountID(for: separate, home: home), "bbbbbbbb-0000-4000-8000-000000000002")
        // Claude Code project tiles have no Desktop app of their own: they run on the CLI sign-in itself.
        XCTAssertNil(ClaudeDesktopAccount.dataDirectory(for: code, home: home))
        XCTAssertNil(ClaudeDesktopAccount.accountID(for: code, home: home))
        try write(#"{"lastKnownAccountUuid":"not-a-uuid"}"#, to: home.appendingPathComponent("Library/Application Support/Claude/config.json"))
        XCTAssertNil(ClaudeDesktopAccount.accountID(for: shared, home: home))

        // The email is used only when the configuration last saw the same account.
        try write(#"{"oauthAccount":{"accountUuid":"aaaaaaaa-0000-4000-8000-000000000001","emailAddress":"one@example.com"}}"#, to: home.appendingPathComponent(".claude.json"))
        try write(#"{"oauthAccount":{"accountUuid":"bbbbbbbb-0000-4000-8000-000000000002","emailAddress":"two@example.com"}}"#, to: separate.claudeConfigDirectory(in: home)!.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeDesktopAccount.email(for: shared, accountID: "AAAAAAAA-0000-4000-8000-000000000001", home: home), "one@example.com")
        XCTAssertEqual(ClaudeDesktopAccount.email(for: separate, accountID: "bbbbbbbb-0000-4000-8000-000000000002", home: home), "two@example.com")
        XCTAssertNil(ClaudeDesktopAccount.email(for: shared, accountID: "bbbbbbbb-0000-4000-8000-000000000002", home: home))
        try write(#"{"oauthAccount":{"accountUuid":"aaaaaaaa-0000-4000-8000-000000000001","emailAddress":"--sso@example.com"}}"#, to: home.appendingPathComponent(".claude.json"))
        XCTAssertNil(ClaudeDesktopAccount.email(for: shared, accountID: "aaaaaaaa-0000-4000-8000-000000000001", home: home), "Never passes an option-like value")
    }
}
