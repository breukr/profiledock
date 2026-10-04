import XCTest
import DockCore
@testable import AccountDock

extension CompanionIntegrationTests {
    @MainActor func testSeparateClaudeAccountIsAddedNextToTheSharedSignIn() throws {
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Claude", project: nil, bundledHelper: nil)
        XCTAssertThrowsError(try model.createCompanion(kind: .claude, name: "Again", project: nil, bundledHelper: nil))
        try model.createCompanion(kind: .claude, name: "Work", project: nil, separateAccount: true, bundledHelper: nil)
        try model.createCompanion(kind: .claude, name: "Client", project: nil, separateAccount: true, bundledHelper: nil)
        let claude = model.preferences.profiles.filter { $0.kind == .claude }
        XCTAssertEqual(claude.map(\.usesSeparateClaudeAccount), [false, true, true])
        let shared = claude[0], work = claude[1], client = claude[2]
        for directory in [work.claudeConfigDirectory(in: model.home)!, work.claudeUserDataDirectory(in: model.home)!] {
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        }
        XCTAssertNotEqual(work.claudeUserDataDirectory(in: model.home), client.claudeUserDataDirectory(in: model.home))
        // Account usage reads the shared Claude Code sign-in only, so separate accounts never borrow it.
        XCTAssertTrue(shared.usesClaudeAccountUsage)
        XCTAssertFalse(work.usesClaudeAccountUsage)
        XCTAssertEqual(model.claudeBridges.map(\.settings), [model.home.appendingPathComponent(".claude/settings.json"),
            work.claudeConfigDirectory(in: model.home)!.appendingPathComponent("settings.json"), client.claudeConfigDirectory(in: model.home)!.appendingPathComponent("settings.json")])
        XCTAssertTrue(try model.recognizeClaudeDesktop(application: nil) == false)

        var sharedSession = ClaudeSession(id: "shared", project: "/project")
        sharedSession.state = .working
        var workSession = ClaudeSession(id: "work", project: "/project")
        workSession.configDirectory = work.claudeConfigDirectory(in: model.home)!.standardizedFileURL.path
        var terminalSession = ClaudeSession(id: "terminal", project: "/project", tty: "/dev/ttys004")
        terminalSession.configDirectory = workSession.configDirectory
        model.companions.sessions = [sharedSession, workSession, terminalSession]
        XCTAssertEqual(model.companions.sessions(for: shared).map(\.id), ["shared"])
        XCTAssertEqual(model.companions.sessions(for: work).map(\.id), ["work"])
        XCTAssertEqual(model.companions.sessions(for: client).map(\.id), [])
        XCTAssertEqual(DockModel(home: model.home).preferences.profiles.filter(\.usesSeparateClaudeAccount).map(\.id), [work.id, client.id])
    }

    func testSeparateAccountBridgeWritesOnlyItsOwnSettings() throws {
        let home = try temporaryHome(), config = home.appendingPathComponent("Library/Application Support/Account Dock/Companions/work/claude-config")
        let shared = ClaudeBridge(home: home), separate = ClaudeBridge(home: home, configDirectory: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"printf work"}}"#.utf8).write(to: separate.settings)
        let helper = home.appendingPathComponent("fixture-helper")
        try Data("fixture executable".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try separate.setEnabled(true, bundledHelper: helper)
        XCTAssertTrue(separate.enabled)
        XCTAssertFalse(shared.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.settings.path))
        XCTAssertNotEqual(separate.originalStatusline, shared.originalStatusline)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: separate.originalStatusline)) as? [String: Any]
        XCTAssertEqual(saved?["command"] as? String, "printf work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.originalStatusline.path))
        try separate.setEnabled(false, bundledHelper: nil)
        XCTAssertFalse(separate.enabled)
    }
}
