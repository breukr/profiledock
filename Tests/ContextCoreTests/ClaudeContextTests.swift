import XCTest
import DockCore
@testable import ContextCore

final class ClaudeContextTests: XCTestCase {
    private func fixture() throws -> (URL, Profile) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        var profile = Profile(id: "profile-claude", name: "Assistant", color: "123456"); profile.provider = .claude
        try FileManager.default.createDirectory(at: profile.home(in: home), withIntermediateDirectories: true)
        let prefs = home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json")
        struct Preferences: Encodable { let profiles: [Profile] }
        try JSONEncoder().encode(Preferences(profiles: [profile])).write(to: prefs)
        return (home, profile)
    }
    private func transcript(home: URL, id: String, cwd: String, text: String) throws {
        let folder = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "cwd": cwd, "timestamp": "2026-09-23T08:00:00Z", "message": ["role": "user", "content": text]],
            ["type": "assistant", "uuid": "a1", "cwd": cwd, "timestamp": "2026-09-23T08:01:00Z", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hidden reasoning"], ["type": "text", "text": "Searchable reply"], ["type": "tool_use", "input": "hidden tool input"]]]],
            ["type": "user", "uuid": "m1", "cwd": cwd, "isMeta": true, "message": ["role": "user", "content": "hidden meta"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: folder.appendingPathComponent(id + ".jsonl"))
    }
    func testSearchAndPaginationExcludeToolReasoningAndMetaMessages() throws {
        let (home, profile) = try fixture()
        try transcript(home: home, id: "session-one", cwd: "/project", text: "Unique launch checklist")
        let service = ContextService(registry: ContextRegistry(home: home), caller: profile.id)
        let found = try service.search(query: "launch checklist", sources: [profile.id])
        XCTAssertEqual(found.hits.count, 2, "The conversation title can match both visible messages")
        XCTAssertEqual(found.hits.first?.thread.id, "session-one")
        let page = try service.read(source: profile.id, threadID: "session-one", limit: 1)
        XCTAssertEqual(page.messages.count, 1)
        let next = try service.read(source: profile.id, threadID: "session-one", cursor: XCTUnwrap(page.nextCursor), limit: 10)
        XCTAssertEqual(next.messages.map(\.text), ["Searchable reply"])
        XCTAssertEqual(try service.search(query: "hidden", sources: [profile.id]).hits.count, 0)
    }
    func testClaudeProjectScopeNeverReadsAnotherProject() throws {
        let (home, _) = try fixture()
        try transcript(home: home, id: "allowed", cwd: "/allowed", text: "Shared word")
        try transcript(home: home, id: "other", cwd: "/other", text: "Shared word")
        let history = ContextHistory(root: home.appendingPathComponent(".claude"), deadline: Date().addingTimeInterval(5), claude: true, project: "/allowed")
        XCTAssertEqual(try history.threads(since: nil, includeArchived: true).0.map(\.id), ["allowed"])
        XCTAssertEqual(try history.threads(since: nil, includeArchived: true, threadID: "other").0.count, 0)
    }
    func testClaudeConnectionRoundTripPreservesOtherServersAndDoesNotInvokeCodex() throws {
        let (home, profile) = try fixture(), registry = ContextRegistry(home: home)
        let config = home.appendingPathComponent(".claude.json")
        let original: [String: Any] = ["theme": "dark", "mcpServers": ["other": ["command": "/fixture/other"]]]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        let helper = home.appendingPathComponent("helper")
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let connection = ContextConnection(registry: registry, codex: URL(fileURLWithPath: "/unused"), run: { _, _, _ in
            XCTFail("Claude must never invoke the Codex CLI"); return ContextCommandResult(status: 1, output: "", error: "unexpected")
        })
        let context = ContextProfile(profile)
        try connection.connect(context, helper: helper, skill: ContextConnection.skillMarker)
        XCTAssertTrue(try connection.isConnected(context))
        try connection.disconnect(context)
        XCTAssertFalse(try connection.isConnected(context))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary, original as NSDictionary)
    }
}
