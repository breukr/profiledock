import XCTest
@testable import DockCore

final class CompanionTests: XCTestCase {
    func testCodingTerminalDetectionRequiresAnActualForegroundAgent() {
        let table = """
        ttys001 S+ /Users/fixture/.local/bin/claude
        ttys002 R+ /opt/bin/codex
        ttys003 S+ /bin/zsh
        ttys004 S /opt/bin/claude
        ttys005 T+ /opt/bin/codex
        ?? S+ /Applications/Claude.app/Contents/MacOS/Claude
        ttys006 S+ /opt/bin/not-claude
        ttys007 Z+ /opt/bin/claude
        ttys008 S+ /Users/fixture/Folder With Spaces/claude
        ttys009  S+   claude
        ttys010  R+   codex
        ttys011  S+   node
        """
        XCTAssertEqual(TerminalAgent.processes(table), ["/dev/ttys001": .claude, "/dev/ttys002": .codex, "/dev/ttys008": .claude, "/dev/ttys009": .claude, "/dev/ttys010": .codex])
    }
    func testExistingProfilesDecodeAsCodexAndKeepTheirHome() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"default","name":"Personal","color":"abcdef"}"#.utf8))
        XCTAssertEqual(profile.kind, .codex)
        XCTAssertEqual(profile.home(in: URL(fileURLWithPath: "/fixture")).path, "/fixture/.codex")
        var claude = profile; claude.provider = .claude
        XCTAssertNotEqual(claude.home(in: URL(fileURLWithPath: "/fixture")), profile.home(in: URL(fileURLWithPath: "/fixture")))
    }
    func testReorderBothDirectionsAndStaleIDsPreserveEntries() {
        let profiles = ["a", "b", "c", "d"].map { Profile(id: $0, name: $0, color: "123456") }
        XCTAssertEqual(ProfileOrder.move(profiles, id: "a", to: "c").map(\.id), ["b", "c", "a", "d"])
        XCTAssertEqual(ProfileOrder.move(profiles, id: "d", to: "b").map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(ProfileOrder.move(profiles, id: "missing", to: "b"), profiles)
        XCTAssertEqual(ProfileOrder.move(profiles, id: "a", to: "a"), profiles)
    }
    func testBridgeSettingsMergeIsIdempotentAndDisconnectPreservesOtherHooks() throws {
        let helper = URL(fileURLWithPath: "/fixture/it's here/helper")
        let original = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"Stop":[{"matcher":"custom","hooks":[{"type":"command","command":"echo original"}]}]},"statusLine":{"type":"command","command":"echo status"}}"#.utf8)
        let first = try ClaudeBridgeSettings.updating(original, helper: helper, enabled: true)
        let second = try ClaudeBridgeSettings.updating(first, helper: helper, enabled: true)
        XCTAssertEqual(first, second)
        let removed = try ClaudeBridgeSettings.updating(second, helper: helper, enabled: false)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        XCTAssertTrue(ClaudeBridgeSettings.command(helper: helper, mode: "hook").contains("'\\''"))
        XCTAssertThrowsError(try ClaudeBridgeSettings.updating(Data(#"{"hooks":{"Stop":"invalid"}}"#.utf8), helper: helper, enabled: true))
    }
    func testClaudeStateLifecycleIgnoresIrrelevantNotificationsAndStatuslineDoesNotChangeState() {
        let now = Date()
        var session = ClaudeSession(id: "test", project: "/project", now: now)
        session.apply(["hook_event_name": "UserPromptSubmit"], statusline: false, now: now)
        XCTAssertEqual(session.state, .working)
        session.apply(["hook_event_name": "Notification", "notification_type": "auth_success"], statusline: false, now: now)
        XCTAssertEqual(session.state, .working)
        session.apply(["hook_event_name": "PermissionRequest"], statusline: false, now: now)
        XCTAssertEqual(session.state, .waiting)
        session.apply([:], statusline: true, now: now)
        XCTAssertEqual(session.state, .waiting)
        session.apply(["hook_event_name": "PostToolUse"], statusline: false, now: now)
        session.apply(["hook_event_name": "Stop"], statusline: false, now: now)
        XCTAssertEqual(session.completedAt, now)
        XCTAssertEqual(session.state, .idle)
        session.apply(["hook_event_name": "SessionEnd"], statusline: false, now: now)
        XCTAssertEqual(session.state, .closed)
    }
    func testSubagentEventsCountRunningAgentsWithoutChangingSessionState() {
        let now = Date()
        var session = ClaudeSession(id: "test", project: "/project", now: now)
        session.apply(["hook_event_name": "UserPromptSubmit"], statusline: false, now: now)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"], statusline: false, now: now)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "a2"], statusline: false, now: now)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "a2"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 2)
        XCTAssertEqual(session.state, .working)
        // A subagent's own tool calls are still ignored.
        session.apply(["hook_event_name": "PermissionRequest", "agent_id": "a1"], statusline: false, now: now)
        XCTAssertEqual(session.state, .working)
        session.apply(["hook_event_name": "Stop"], statusline: false, now: now)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.runningSubagents(now: now), 2, "The main turn ending does not end its background subagents")
        session.apply(["hook_event_name": "SubagentStop", "agent_id": "a1"], statusline: false, now: now)
        session.apply(["hook_event_name": "SubagentStop", "agent_id": "unknown"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 1)
        session.apply(["hook_event_name": "SubagentStop", "agent_id": "a2"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 0)
        XCTAssertNil(session.subagents)
    }
    func testSubagentCountIgnoresStaleEntriesAndResetsWithTheSession() {
        let now = Date()
        var session = ClaudeSession(id: "test", project: "/project", now: now)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "lost"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now.addingTimeInterval(ClaudeSession.subagentStaleAfter - 1)), 1)
        XCTAssertEqual(session.runningSubagents(now: now.addingTimeInterval(ClaudeSession.subagentStaleAfter + 1)), 0)
        session.apply(["hook_event_name": "SessionEnd"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 0)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "again"], statusline: false, now: now)
        session.apply(["hook_event_name": "SessionStart"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 0)
        session.apply(["hook_event_name": "SubagentStart", "agent_id": "../escape"], statusline: false, now: now)
        XCTAssertEqual(session.runningSubagents(now: now), 0, "Agent IDs use the same validation as session IDs")
    }
    func testOnlySessionPayloadsAndSubagentLifecycleReachTheStore() {
        XCTAssertTrue(ClaudeSession.isSessionPayload(["hook_event_name": "Stop"]))
        XCTAssertTrue(ClaudeSession.isSessionPayload(["hook_event_name": "SubagentStart", "agent_id": "a1"]))
        XCTAssertTrue(ClaudeSession.isSessionPayload(["hook_event_name": "SubagentStop", "agent_id": "a1"]))
        XCTAssertFalse(ClaudeSession.isSessionPayload(["hook_event_name": "PreToolUse", "agent_id": "a1"]))
        XCTAssertFalse(ClaudeSession.isSessionPayload(["hook_event_name": "Stop", "agent_id": "a1"]))
        XCTAssertFalse(ClaudeSession.isSessionPayload(["hook_event_name": "SubagentStop", "agent_id": 7]))
    }
    func testBridgeInstallsSubagentHooksAndRemovesThemOnDisconnect() throws {
        let helper = URL(fileURLWithPath: "/fixture/helper")
        let enabled = try JSONSerialization.jsonObject(with: ClaudeBridgeSettings.updating(nil, helper: helper, enabled: true)) as? [String: Any]
        let hooks = try XCTUnwrap(enabled?["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SubagentStart"]); XCTAssertNotNil(hooks["SubagentStop"])
        let removed = try ClaudeBridgeSettings.updating(ClaudeBridgeSettings.updating(nil, helper: helper, enabled: true), helper: helper, enabled: false)
        XCTAssertTrue(((try JSONSerialization.jsonObject(with: removed) as? [String: Any])?["hooks"] as? [String: Any])?.isEmpty == true)
    }
    func testMissingExpiredAndMalformedUsageNeverBecomesZero() {
        let now = Date(timeIntervalSince1970: 1000)
        var session = ClaudeSession(id: "test", project: "/project", now: now)
        session.apply(["rate_limits": ["five_hour": ["used_percentage": 24.0, "resets_at": 2000.0], "seven_day": ["used_percentage": -1.0, "resets_at": 3000.0]]], statusline: true, now: now)
        XCTAssertEqual(session.snapshot(identity: "id", now: now)?.windows.first?.remainingPercent, 76)
        XCTAssertEqual(session.snapshot(identity: "id", now: Date(timeIntervalSince1970: 2001))?.windows, [])
        session.apply([:], statusline: true, now: now)
        XCTAssertEqual(session.snapshot(identity: "id", now: now)?.windows, [])
        XCTAssertNil(session.snapshot(identity: "id", now: now)?.bankedResets)
    }
    func testStoredEventsDiscardPromptsAndRejectTraversalAndSymlinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeSessionStore(home: home)
        _ = try store.record(payload: ["session_id": "fixture", "cwd": "/project", "hook_event_name": "UserPromptSubmit", "prompt": "PRIVATE PROMPT", "tool_input": ["token": "SECRET"]], statusline: false, process: nil, tty: "/dev/ttys001")
        let text = try String(contentsOf: store.root.appendingPathComponent("fixture.json"))
        XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("SECRET"))
        XCTAssertEqual(store.read().first?.tty, "/dev/ttys001")
        XCTAssertThrowsError(try store.record(payload: ["session_id": "../escape", "cwd": "/project"], statusline: false, process: nil, tty: nil))
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("linked.json"), withDestinationURL: store.root.appendingPathComponent("fixture.json"))
        XCTAssertThrowsError(try store.record(payload: ["session_id": "linked", "cwd": "/project"], statusline: false, process: nil, tty: nil))
        XCTAssertEqual(store.read().count, 1)
    }
}
