import XCTest
import DockCore
@testable import AccountDock

final class SessionLinksTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-links-" + UUID().uuidString)
            .appendingPathComponent("claude-code-sessions/acct-1/org-1")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        return url
    }
    private func record(_ folder: URL, local: String, cli: String, last: String? = nil, previous: [String] = [], extra: String = "") throws {
        var json: [String: Any] = ["sessionId": local, "cliSessionId": cli, "title": "Fixture \(extra)"]
        if let last { json["lastAssistantCliSessionId"] = last }
        if !previous.isEmpty { json["previousCliSessionIds"] = previous }
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("\(local).json"))
    }

    func testFindsDesktopSessionByAnyClaudeCodeSessionItUsed() throws {
        let folder = try root(), sessions = folder.deletingLastPathComponent().deletingLastPathComponent()
        try record(folder, local: "local_aaaa-1111", cli: "11111111-1111-1111-1111-111111111111")
        try record(folder, local: "local_bbbb-2222", cli: "22222222-2222-2222-2222-222222222222", last: "33333333-3333-3333-3333-333333333333",
                   previous: ["44444444-4444-4444-4444-444444444444"])
        XCTAssertEqual(SessionLinks.claudeLocalSession(forCLISession: "11111111-1111-1111-1111-111111111111", root: sessions), "local_aaaa-1111")
        XCTAssertEqual(SessionLinks.claudeLocalSession(forCLISession: "33333333-3333-3333-3333-333333333333", root: sessions), "local_bbbb-2222")
        XCTAssertEqual(SessionLinks.claudeLocalSession(forCLISession: "44444444-4444-4444-4444-444444444444", root: sessions), "local_bbbb-2222")
        XCTAssertNil(SessionLinks.claudeLocalSession(forCLISession: "99999999-9999-9999-9999-999999999999", root: sessions))
    }

    func testIgnoresRecordsThatOnlyMentionTheIdOrHaveAnInvalidLocalId() throws {
        let folder = try root(), sessions = folder.deletingLastPathComponent().deletingLastPathComponent()
        let id = "55555555-5555-5555-5555-555555555555"
        // The id appears in the title only: not a session that used it.
        try record(folder, local: "local_cccc-3333", cli: "66666666-6666-6666-6666-666666666666", extra: id)
        // A malformed local id is never turned into a link.
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_../../etc", "cliSessionId": id]).write(to: folder.appendingPathComponent("local_bad.json"))
        XCTAssertNil(SessionLinks.claudeLocalSession(forCLISession: id, root: sessions))
        XCTAssertNil(SessionLinks.claudeLocalSession(forCLISession: "../../x", root: sessions), "Ids with path characters are refused")
        XCTAssertNil(SessionLinks.claudeLocalSession(forCLISession: id, root: sessions.appendingPathComponent("missing")))
    }

    func testLinksUseTheAppsOwnRoutesAndRejectUnsafeIds() {
        XCTAssertEqual(SessionLinks.claudeURL(local: "local_d4ef62a5-53cf-4b01")?.absoluteString, "claude://code/continue?session=local_d4ef62a5-53cf-4b01")
        XCTAssertNil(SessionLinks.claudeURL(local: "local_x&session=last"))
        XCTAssertEqual(SessionLinks.codexURL(thread: "019a2b3c-4d5e-6f70")?.absoluteString, "codex://threads/019a2b3c-4d5e-6f70")
        XCTAssertNil(SessionLinks.codexURL(thread: "../settings"))
    }

    func testSeparateClaudeAccountsUseTheirOwnDesktopRecords() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        XCTAssertEqual(SessionLinks.claudeSessionsRoot(for: nil, home: home).path, "/Users/fixture/Library/Application Support/Claude/claude-code-sessions")
        var separate = Profile(id: "atlas", name: "Atlas", color: "377CF6"); separate.provider = .claude; separate.separateClaudeAccount = true
        XCTAssertTrue(SessionLinks.claudeSessionsRoot(for: separate, home: home).path.hasSuffix("electron-user-data/claude-code-sessions"))
        XCTAssertFalse(SessionLinks.claudeSessionsRoot(for: separate, home: home).path.contains("Application Support/Claude/"))
    }
}
