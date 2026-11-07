import XCTest
import Darwin
import DockCore
@testable import AccountDock

/// End to end: the packaged hook helper, the inbox socket and `AttentionCenter`, with a fictional home under /tmp
/// (socket paths must stay under 104 bytes). Nothing reads or writes the real agents' settings.
@MainActor
final class ReplyHoldTests: XCTestCase {
    private struct HelperResult: Sendable { let output: String; let status: Int32; let elapsed: TimeInterval }

    private func shortHome() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("pdr-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func started(_ home: URL) throws -> (InboxServer, AttentionCenter) {
        let attention = AttentionCenter(), server = InboxServer(home: home, attention: attention)
        try server.start()
        addTeardownBlock { @MainActor in server.stop() }
        return (server, attention)
    }
    private func until(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private var helper: URL {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROFILEDOCK_CLAUDE_HELPER_PATH"] ?? checkout.appendingPathComponent(".build/debug/ProfileDockClaude").path)
    }
    private func run(_ arguments: [String], home: URL, payload: [String: Any], environment: [String: String] = [:]) async throws -> HelperResult {
        let helper = self.helper
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "Build ProfileDockClaude before running this test")
        let input = try JSONSerialization.data(withJSONObject: payload)
        return try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = helper; process.arguments = arguments + ["--home", home.path]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(environment) { _, new in new }
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            let start = Date()
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return HelperResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus, elapsed: Date().timeIntervalSince(start))
        }.value
    }
    private func stop(_ session: String = "fixture-session", _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": session, "cwd": "/fixture/project", "hook_event_name": "Stop", "last_assistant_message": "Updated the Meridian dashboard."].merging(extra) { _, new in new }
    }

    // MARK: Claude Code

    func testAReplyTypedInThePopUpContinuesAClaudeTurn() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(replyHoldSeconds: 30).write(home: home)
        async let first = run(["hook"], home: home, payload: stop(), environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
        try await until { attention.items.first?.awaitsDecision == true }
        let item = try XCTUnwrap(attention.items.first)
        XCTAssertEqual(item.kind, .finished); XCTAssertEqual(item.message, "Updated the Meridian dashboard.")
        attention.respond(item.id, .reply("Also add a dark theme"))
        let replied = try await first
        XCTAssertEqual(replied.output, #"{"decision":"block","reason":"Also add a dark theme"}"# + "\n"); XCTAssertEqual(replied.status, 0)

        // The reply's own turn ends with stop_hook_active and may be answered again, once.
        async let second = run(["hook"], home: home, payload: stop("fixture-session", ["stop_hook_active": true]), environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
        try await until { attention.items.first?.awaitsDecision == true }
        attention.respond(attention.items[0].id, .passThrough)
        let passed = try await second
        XCTAssertEqual(passed.output, "")
        let third = try await run(["hook"], home: home, payload: stop("fixture-session", ["stop_hook_active": true]), environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
        XCTAssertEqual(third.output, ""); XCTAssertLessThan(third.elapsed, 3, "Without a new reply a continued turn is not held")
    }

    func testTheAppCanRefuseTheHoldAndDoneIsStillShown() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        server.shouldHold = { _ in false }
        try AgentInboxFlags(replyHoldSeconds: 30).write(home: home)
        let result = try await run(["hook"], home: home, payload: stop(), environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"])
        XCTAssertEqual(result.output, ""); XCTAssertLessThan(result.elapsed, 3)
        try await until { !attention.items.isEmpty }
        XCTAssertEqual(attention.items[0].kind, .finished); XCTAssertFalse(attention.items[0].awaitsDecision)
    }

    func testATimedOutOrReleasedHoldKeepsTheDoneItem() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        try AgentInboxFlags(replyHoldSeconds: 1).write(home: home)
        let timedOut = try await run(["hook"], home: home, payload: stop("timed-out"), environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
        XCTAssertEqual(timedOut.output, ""); XCTAssertGreaterThanOrEqual(timedOut.elapsed, 0.9)
        try await until { attention.items.first.map { !$0.awaitsDecision } == true }
        XCTAssertEqual(attention.items.map(\.sessionID), ["timed-out"])

        // Switching to the session's terminal or app ends the wait at once.
        try AgentInboxFlags(replyHoldSeconds: 30).write(home: home)
        async let released = run(["hook"], home: home, payload: stop("released"), environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"])
        try await until { attention.items.contains { $0.sessionID == "released" && $0.awaitsDecision } }
        server.releaseHeldReplies { $0.sessionID == "released" }
        let result = try await released
        XCTAssertEqual(result.output, ""); XCTAssertLessThan(result.elapsed, 5)
        try await until { attention.items.contains { $0.sessionID == "released" && !$0.awaitsDecision } }
    }

    // MARK: Codex and extension

    func testCodexReplyWaitsLongerWhileTheUserTypes() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(replyHoldSeconds: 1).write(home: home)
        async let result = run(["codex"], home: home, payload: stop("thr-fixture", ["turn_id": "turn-1"]), environment: ["PROFILEDOCK_FIXTURE_ENTRYPOINT": "cli"])
        try await until { attention.items.first?.awaitsDecision == true }
        let item = try XCTUnwrap(attention.items.first)
        XCTAssertEqual(item.source, "codex")
        attention.extendHold(item.id, until: Date().addingTimeInterval(5))
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertTrue(attention.items.first?.awaitsDecision == true, "Still waiting past the first second")
        attention.respond(item.id, .reply("Ship it"))
        let finished = try await result
        XCTAssertEqual(finished.output, #"{"decision":"block","reason":"Ship it"}"# + "\n"); XCTAssertGreaterThan(finished.elapsed, 1.5)
        XCTAssertTrue(ClaudeSessionStore(home: home).read().isEmpty, "Codex sessions are never recorded as Claude sessions")
    }

    func testExtensionIsCappedAtTenMinutesAfterTheTurnEnded() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        let socket = server.socketURL, start = Date()
        let request = Task.detached {
            AgentInboxClient.request(AgentAttention(id: "capped", source: "claude", sessionID: "s1", kind: .finished, title: "Done", message: "", deadline: Date().addingTimeInterval(20)),
                                     socket: socket, deadline: Date().addingTimeInterval(20), limit: StopReply.limit(receivedAt: Date()))
        }
        try await until { attention.items.first?.awaitsDecision == true }
        attention.extendHold("capped", until: start.addingTimeInterval(3_600))
        try await until { (attention.items.first?.deadline ?? .distantFuture) < start.addingTimeInterval(700) }
        let deadline = try XCTUnwrap(attention.items.first?.deadline)
        XCTAssertEqual(deadline.timeIntervalSince(start), 600, accuracy: 2, "The countdown shows the real, capped deadline")
        attention.respond("capped", .reply("Go on"))
        let decision = await request.value
        XCTAssertEqual(decision, .reply("Go on"))
    }

    func testTheHelperCapsAnExtensionOnItsOwn() async throws {
        // A fake app that asks for an hour more: the helper still gives up at its own limit.
        let path = "/tmp/pdx-" + UUID().uuidString.prefix(8).lowercased() + ".sock"
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(AgentInbox.address(path))
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        addTeardownBlock { Darwin.close(listener); unlink(path) }
        let fake = Task.detached {
            let peer = Darwin.accept(listener, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 4_096)
            _ = Darwin.read(peer, &buffer, buffer.count)
            let frame = try AgentInbox.encode(.extend(id: "fake", until: Date().addingTimeInterval(3_600)))
            _ = frame.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, frame.count) }
            Thread.sleep(forTimeInterval: 4)
            Darwin.close(peer)
        }
        let start = Date()
        let decision = await Task.detached {
            AgentInboxClient.request(AgentAttention(id: "fake", source: "codex", sessionID: "s1", kind: .finished, title: "Done", message: "", deadline: Date().addingTimeInterval(0.5)),
                                     socket: URL(fileURLWithPath: path), deadline: Date().addingTimeInterval(0.5), limit: Date().addingTimeInterval(1.5))
        }.value
        XCTAssertNil(decision)
        XCTAssertEqual(Date().timeIntervalSince(start), 1.5, accuracy: 0.6)
        fake.cancel()
    }

    // MARK: Other agents

    func testOtherAgentsAreReportedWithoutBeingRecordedOrHeld() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(replyHoldSeconds: 30).write(home: home)
        let result = try await run(["agent", "gemini"], home: home, payload: ["session_id": "gem-1", "cwd": "/fixture/atlas", "hook_event_name": "AfterAgent", "prompt_response": "Ready."])
        XCTAssertEqual(result.output, ""); XCTAssertEqual(result.status, 0); XCTAssertLessThan(result.elapsed, 3)
        try await until { !attention.items.isEmpty }
        XCTAssertEqual(attention.items[0].source, "gemini"); XCTAssertEqual(attention.items[0].kind, .finished); XCTAssertFalse(attention.items[0].awaitsDecision)
        XCTAssertTrue(ClaudeSessionStore(home: home).read().isEmpty)
        let unknown = try await run(["agent", "nonexistent"], home: home, payload: ["session_id": "x", "hook_event_name": "Stop"])
        XCTAssertEqual(unknown.output, ""); XCTAssertEqual(unknown.status, 0)
    }

    // MARK: Hold policy

    func testHoldPolicyRespectsTerminalsAndTheSessionsOwnApp() {
        let terminal: (String?) -> Bool = { $0 == "com.apple.Terminal" }
        func item(_ source: String, _ entrypoint: String?) -> AgentAttention { AgentAttention(source: source, sessionID: "s1", kind: .finished, title: "Done", message: "", entrypoint: entrypoint) }
        XCTAssertFalse(AttentionHoldPolicy.allows(item("claude", "cli"), frontmost: "com.apple.Terminal", isTerminal: terminal))
        XCTAssertTrue(AttentionHoldPolicy.allows(item("claude", "cli"), frontmost: "com.apple.Safari", isTerminal: terminal))
        XCTAssertTrue(AttentionHoldPolicy.allows(item("claude", "cli"), frontmost: "com.anthropic.claudefordesktop", isTerminal: terminal))
        XCTAssertFalse(AttentionHoldPolicy.allows(item("claude", "claude-desktop"), frontmost: "com.anthropic.claudefordesktop", isTerminal: terminal))
        XCTAssertFalse(AttentionHoldPolicy.allows(item("codex", "codex-desktop"), frontmost: "com.openai.codex", isTerminal: terminal))
        XCTAssertFalse(AttentionHoldPolicy.allows(item("codex", "cli"), frontmost: "com.openai.chat", isTerminal: terminal))
        XCTAssertTrue(AttentionHoldPolicy.allows(item("codex", "codex-desktop"), frontmost: nil, isTerminal: terminal))
    }
}

/// Connecting other agents edits only ProfileDock's own entries, in a temporary home.
final class AgentHookBridgeTests: XCTestCase {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pd-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func bundled(_ home: URL) throws -> URL {
        let url = home.appendingPathComponent("bundled-helper")
        try Data("fixture helper".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func backups(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(AgentHookBridge.backupMarker) }
    }

    func testConnectingKeepsOtherEntriesBacksUpOnceAndDisconnectsCleanly() throws {
        let home = try home(), bridge = AgentHookBridge(home: home), helper = try bundled(home)
        let original = #"{"ui":{"theme":"fixture"},"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"/fixture/other --source gemini","timeout":5000}]}]}}"#
        try write(original, ".gemini/settings.json", in: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.appendingPathComponent(".gemini/settings.json").path)
        XCTAssertEqual(bridge.status("gemini"), .notConnected)
        XCTAssertThrowsError(try bridge.setConnected("gemini", true, bundledHelper: nil), "No helper, no connection")
        XCTAssertEqual(bridge.status("gemini"), .notConnected)

        try bridge.setConnected("gemini", true, bundledHelper: helper)
        XCTAssertEqual(bridge.status("gemini"), .connected)
        XCTAssertEqual(try Data(contentsOf: bridge.helper), Data("fixture helper".utf8))
        let settings = home.appendingPathComponent(".gemini/settings.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int, 0o644, "The agent's file keeps its permissions")
        let connected = try Data(contentsOf: settings)
        try bridge.setConnected("gemini", true, bundledHelper: helper)
        XCTAssertEqual(try Data(contentsOf: settings), connected, "Connecting twice changes nothing")
        let text = String(decoding: connected, as: UTF8.self)
        XCTAssertTrue(text.contains("/fixture/other --source gemini")); XCTAssertTrue(text.contains("fixture"))

        try bridge.setConnected("gemini", false, bundledHelper: nil)
        Thread.sleep(forTimeInterval: 0.02)
        try bridge.setConnected("gemini", true, bundledHelper: helper)
        Thread.sleep(forTimeInterval: 0.02)
        try bridge.setConnected("gemini", false, bundledHelper: nil)
        XCTAssertEqual(bridge.status("gemini"), .notConnected)
        XCTAssertTrue(AgentHookConfig.sameJSON(try Data(contentsOf: settings), Data(original.utf8)))
        let names = backups(settings.deletingLastPathComponent())
        XCTAssertEqual(names.count, 2, "The original and the newest backup")
        XCTAssertTrue(try names.contains { try Data(contentsOf: settings.deletingLastPathComponent().appendingPathComponent($0)) == Data(original.utf8) })
    }

    func testOwnedFilesAreCreatedAndRemovedWithoutBackups() throws {
        let home = try home(), bridge = AgentHookBridge(home: home), helper = try bundled(home)
        try bridge.setConnected("copilot", true, bundledHelper: helper)
        try bridge.setConnected("opencode", true, bundledHelper: helper)
        XCTAssertEqual(bridge.status("copilot"), .connected); XCTAssertEqual(bridge.status("opencode"), .connected)
        let plugins = home.appendingPathComponent(".config/opencode/plugins")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: plugins.path), ["profiledock.js"], "OpenCode loads every file there, so no backups")
        try bridge.setConnected("copilot", false, bundledHelper: nil); try bridge.setConnected("opencode", false, bundledHelper: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/profiledock.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: plugins.path), [])
        // A file with our name that ProfileDock did not write is never replaced or removed.
        try write("export const Mine = async () => ({});", ".config/opencode/plugins/profiledock.js", in: home)
        XCTAssertThrowsError(try bridge.setConnected("opencode", false, bundledHelper: nil))
        XCTAssertThrowsError(try bridge.setConnected("opencode", true, bundledHelper: helper))
        XCTAssertEqual(try String(contentsOf: plugins.appendingPathComponent("profiledock.js"), encoding: .utf8), "export const Mine = async () => ({});")
    }

    func testDroidUsesHooksJSONOnlyWhenItExistsAndLinksAreRefused() throws {
        let home = try home(), bridge = AgentHookBridge(home: home), helper = try bundled(home)
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/fixture/other"}]}]}}"#, ".factory/settings.json", in: home)
        try bridge.setConnected("droid", true, bundledHelper: helper)
        XCTAssertEqual(bridge.file("droid")?.lastPathComponent, "settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".factory/hooks.json").path), "Creating hooks.json would hide settings.json hooks")
        try write(#"{"hooks":{}}"#, ".factory/hooks.json", in: home)
        XCTAssertEqual(bridge.file("droid")?.lastPathComponent, "hooks.json"); XCTAssertEqual(bridge.status("droid"), .notConnected)

        let target = home.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".qwen"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".qwen/settings.json"), withDestinationURL: target)
        XCTAssertThrowsError(try bridge.setConnected("qwen", true, bundledHelper: helper))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        try write(#"{"hooks":[]}"#, ".cursor/hooks.json", in: home)
        if case .unreadable = bridge.status("cursor") {} else { XCTFail("An unexpected shape is reported, not rewritten") }
    }

    func testCodexOlderEntriesAreReportedAndRefreshedOnlyWhenConnected() throws {
        let home = try home(), bridge = AgentHookBridge(home: home), helper = try bundled(home)
        bridge.refreshConnected(bundledHelper: helper)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path), "Refreshing never connects anything")
        let legacy = ClaudeBridgeSettings.command(helper: bridge.helper, mode: "codex")
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(legacy)","timeout":5}]}]}}"#, ".codex/hooks.json", in: home)
        XCTAssertEqual(bridge.status("codex"), .outdated)
        bridge.refreshConnected(bundledHelper: helper)
        XCTAssertEqual(bridge.status("codex"), .connected)
        let hooks = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".codex/hooks.json"))) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["Stop"]?.count, 1); XCTAssertEqual((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 615)
    }
}
