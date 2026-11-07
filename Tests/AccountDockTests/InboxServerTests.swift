import XCTest
import Darwin
import DockCore
@testable import AccountDock

/// Exercises the inbox socket and the packaged hook helper with a fictional home. Socket paths must stay under
/// 104 bytes, so homes live in a short folder under /tmp and are removed afterwards.
@MainActor
final class InboxServerTests: XCTestCase {
    private struct HelperResult: Sendable { let output: String; let status: Int32; let elapsed: TimeInterval }

    private func shortHome() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("pdi-" + UUID().uuidString.prefix(8).lowercased())
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
    private func run(_ mode: String = "hook", home: URL, payload: [String: Any], entrypoint: String? = "cli") async throws -> HelperResult {
        let helper = self.helper
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "Build ProfileDockClaude before running this test")
        let input = try JSONSerialization.data(withJSONObject: payload)
        return try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = helper; process.arguments = [mode, "--home", home.path]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(entrypoint.map { ["CLAUDE_CODE_ENTRYPOINT": $0] } ?? [:]) { _, new in new }
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            let start = Date()
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return HelperResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus, elapsed: Date().timeIntervalSince(start))
        }.value
    }
    private func permission(_ session: String = "fixture-session") -> [String: Any] {
        ["session_id": session, "cwd": "/fixture/project", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "make fixture"]]
    }
    private func item(_ id: String, kind: AttentionKind = .permission, session: String = "s1", title: String = "T", deadline: Date? = nil) -> AgentAttention {
        AgentAttention(id: id, source: "claude", sessionID: session, kind: kind, title: title, message: "M", deadline: deadline)
    }

    // MARK: Helper end to end

    func testHelperWithoutAppPrintsNothingAndReturnsQuickly() async throws {
        let home = try shortHome()
        try AgentInboxFlags(holdSeconds: 30).write(home: home)
        _ = try await run(home: home, payload: permission()) // The first launch of a fresh binary pays for its signature check.
        let result = try await run(home: home, payload: permission())
        XCTAssertEqual(result.output, ""); XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(result.elapsed, 0.3)
        // Session metadata is still recorded as before.
        XCTAssertEqual(ClaudeSessionStore(home: home).read().first?.state, .waiting)
    }

    func testAllowFromTheNotchPrintsTheDocumentedDecision() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(holdSeconds: 30).write(home: home)
        async let result = run(home: home, payload: permission())
        try await until { attention.items.first?.awaitsDecision == true }
        let item = try XCTUnwrap(attention.items.first)
        XCTAssertEqual(item.preview, "make fixture"); XCTAssertEqual(item.entrypoint, "cli")
        attention.respond(item.id, .allow)
        let finished = try await result
        XCTAssertEqual(finished.output, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"# + "\n")
        XCTAssertEqual(finished.status, 0)
        attention.respond(item.id, .deny(message: nil)) // A second answer for the same id is ignored.
        XCTAssertTrue(attention.items.isEmpty)
    }

    func testDenyAndQuestionAnswersReachTheHook() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(holdSeconds: 30).write(home: home)
        async let denied = run(home: home, payload: permission())
        try await until { attention.items.first?.awaitsDecision == true }
        attention.respond(attention.items[0].id, .deny(message: "Use the fixture target"))
        let deniedOutput = try await denied.output
        XCTAssertEqual(deniedOutput, #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Use the fixture target"},"hookEventName":"PermissionRequest"}}"# + "\n")

        let question: [String: Any] = ["session_id": "fixture-session", "cwd": "/fixture/project", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                                       "tool_input": ["questions": [["question": "Ship it?", "header": "Ship", "options": [["label": "Yes"], ["label": "No"]], "multiSelect": false]]]]
        async let answered = run("ask", home: home, payload: question)
        try await until { attention.items.first?.kind == .question }
        XCTAssertEqual(attention.items[0].questions.first?.options.map(\.label), ["Yes", "No"])
        attention.respond(attention.items[0].id, .answer(["Yes"]))
        let answeredOutput = try await answered.output
        XCTAssertEqual(answeredOutput, #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"answers":{"Ship it?":"Yes"},"questions":[{"header":"Ship","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}],"question":"Ship it?"}]}}}"# + "\n")
    }

    func testTimeoutAndDismissPrintNothingAndRemoveTheItem() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(holdSeconds: 1).write(home: home)
        async let timedOut = run(home: home, payload: permission())
        try await until { !attention.items.isEmpty }
        let late = attention.items[0].id
        let result = try await timedOut
        XCTAssertEqual(result.output, ""); XCTAssertEqual(result.status, 0); XCTAssertGreaterThanOrEqual(result.elapsed, 0.9)
        try await until { attention.items.isEmpty }
        attention.respond(late, .allow) // Too late: ignored.

        try AgentInboxFlags(holdSeconds: 30).write(home: home)
        async let dismissed = run(home: home, payload: permission())
        try await until { !attention.items.isEmpty }
        attention.dismiss(attention.items[0].id)
        let dismissedResult = try await dismissed
        XCTAssertEqual(dismissedResult.output, ""); XCTAssertLessThan(dismissedResult.elapsed, 5)
    }

    func testDesktopSessionsAndDisabledAnswersNeverBlock() async throws {
        let home = try shortHome(), (_, attention) = try started(home)
        try AgentInboxFlags(holdSeconds: 30).write(home: home)
        let desktop = try await run(home: home, payload: permission("desktop-session"), entrypoint: "claude-desktop")
        XCTAssertEqual(desktop.output, ""); XCTAssertLessThan(desktop.elapsed, 2)
        try await until { attention.items.contains { $0.sessionID == "desktop-session" } }
        XCTAssertFalse(attention.items[0].awaitsDecision)

        try AgentInboxFlags(answerFromNotch: false, holdSeconds: 30).write(home: home)
        let off = try await run(home: home, payload: permission("terminal-session"))
        XCTAssertEqual(off.output, ""); XCTAssertLessThan(off.elapsed, 2)
        try await until { attention.items.contains { $0.sessionID == "terminal-session" } }
        XCTAssertEqual(attention.needsDecisionCount, 0)

        // The finished turn reaches the app; prompt text never does and nothing new is written to disk.
        let stop = try await run(home: home, payload: ["session_id": "terminal-session", "cwd": "/fixture/project", "hook_event_name": "Stop", "last_assistant_message": "PRIVATE summary"])
        XCTAssertEqual(stop.output, "")
        try await until { attention.items.contains { $0.kind == .finished } }
        XCTAssertEqual(attention.items.first { $0.kind == .finished }?.message, "PRIVATE summary")
        let files = try FileManager.default.subpathsOfDirectory(atPath: home.path).map { home.appendingPathComponent($0) }
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("PRIVATE"), file.lastPathComponent)
        }
    }

    // MARK: Server

    func testSocketIsPrivateAndRemovedOnStop() throws {
        let home = try shortHome(), attention = AttentionCenter(), server = InboxServer(home: home, attention: attention)
        try server.start()
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: AgentInbox.directory(home: home).path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fm.attributesOfItem(atPath: server.socketURL.path)[.posixPermissions] as? Int, 0o600)
        server.stop()
        XCTAssertFalse(fm.fileExists(atPath: server.socketURL.path))
        // A stale socket from an earlier run is replaced; a regular file in its place is left alone.
        try server.start(); server.stop()
        try Data("not a socket".utf8).write(to: server.socketURL)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try Data(contentsOf: server.socketURL), Data("not a socket".utf8))
    }

    func testReusedIdsUnknownDecisionsAndOversizedFramesAreRejected() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        XCTAssertTrue(AgentInboxClient.post(.attention(item("once", title: "First"), notification: nil), socket: server.socketURL))
        try await until { attention.items.count == 1 }
        XCTAssertTrue(AgentInboxClient.post(.attention(item("once", session: "s2", title: "Second"), notification: nil), socket: server.socketURL))
        attention.onDecision?("never-seen", .allow) // Unknown ids are ignored.
        let socket = server.socketURL
        let reused = await Task.detached { AgentInboxClient.request(AgentAttention(id: "once", source: "claude", sessionID: "s3", kind: .permission, title: "T", message: "M", deadline: Date().addingTimeInterval(20)), socket: socket, deadline: Date().addingTimeInterval(20)) }.value
        XCTAssertNil(reused, "A reused id ends the connection instead of waiting")
        XCTAssertEqual(attention.items.map(\.title), ["First"])

        // A frame over 256 KB closes the connection without posting anything.
        let fd = try XCTUnwrap(AgentInboxClient.connect(socket, timeout: 0.1))
        defer { close(fd) }
        XCTAssertTrue(AgentInboxClient.write(Data([0x01, 0x00, 0x08, 0x00]) + Data(repeating: 0x20, count: 1_024), to: fd, until: Date().addingTimeInterval(1)))
        try await Task.sleep(nanoseconds: 100_000_000)
        var byte: UInt8 = 0
        XCTAssertTrue(AgentInboxClient.wait(fd, for: Int16(POLLIN), until: Date().addingTimeInterval(1)))
        XCTAssertEqual(Darwin.read(fd, &byte, 1), 0, "The server closed the connection")
        XCTAssertEqual(attention.items.count, 1)
    }

    func testClosingAWaitingConnectionExpiresItsItem() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        let fd = try XCTUnwrap(AgentInboxClient.connect(server.socketURL, timeout: 0.1))
        XCTAssertTrue(AgentInboxClient.write(try AgentInbox.encode(.attention(item("held", deadline: Date().addingTimeInterval(30)), notification: nil)), to: fd, until: Date().addingTimeInterval(1)))
        try await until { attention.needsDecisionCount == 1 }
        close(fd)
        try await until { attention.items.isEmpty }
        attention.respond("held", .allow)
        XCTAssertTrue(attention.items.isEmpty)
    }

    func testClearKeepsHeldRequestsAndPermissionPromptsAreNotShownTwice() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        let socket = server.socketURL
        let held = Task.detached { AgentInboxClient.request(AgentAttention(id: "held", source: "claude", sessionID: "s1", kind: .permission, title: "Run a command?", message: "M", toolName: "Bash", deadline: Date().addingTimeInterval(20)), socket: socket, deadline: Date().addingTimeInterval(20)) }
        try await until { attention.needsDecisionCount == 1 }
        AgentInboxClient.post(.attention(item("prompt", session: "s1", title: "Needs your approval"), notification: "permission_prompt"), socket: socket)
        AgentInboxClient.post(.attention(item("idle", kind: .waiting, session: "s2"), notification: nil), socket: socket)
        AgentInboxClient.post(.attention(item("done", kind: .finished, session: "s3"), notification: nil), socket: socket)
        try await until { attention.items.count == 3 }
        XCTAssertFalse(attention.items.contains { $0.id == "prompt" }, "Claude's later notification for the same prompt is skipped")

        AgentInboxClient.post(.clear(source: "claude", sessionID: "s1", includeFinished: true), socket: socket)
        AgentInboxClient.post(.clear(source: "claude", sessionID: "s2", includeFinished: false), socket: socket)
        AgentInboxClient.post(.clear(source: "claude", sessionID: "s3", includeFinished: false), socket: socket)
        try await until { attention.items.count == 2 }
        XCTAssertEqual(Set(attention.items.map(\.id)), ["held", "done"])
        attention.respond("held", .allow)
        let decision = await held.value
        XCTAssertEqual(decision, .allow)
    }

    func testShouldHoldCanReleaseARequestAtOnce() async throws {
        let home = try shortHome(), (server, attention) = try started(home)
        server.shouldHold = { _ in false }
        let socket = server.socketURL
        let decision = await Task.detached { AgentInboxClient.request(AgentAttention(id: "released", source: "claude", sessionID: "s1", kind: .permission, title: "T", message: "M", deadline: Date().addingTimeInterval(20)), socket: socket, deadline: Date().addingTimeInterval(20)) }.value
        XCTAssertEqual(decision, .passThrough)
        XCTAssertTrue(attention.items.isEmpty)
    }

    func testServiceWritesFlagsFromPreferences() throws {
        var preferences = Preferences()
        XCTAssertEqual(AgentInboxService.flags(for: preferences), AgentInboxFlags(popups: true, answerFromNotch: true, holdSeconds: 90))
        preferences.attentionPopups = false; preferences.answerPermissionsFromNotch = true; preferences.attentionHoldSeconds = 20
        XCTAssertEqual(AgentInboxService.flags(for: preferences), AgentInboxFlags(popups: false, answerFromNotch: true, holdSeconds: 20))
        XCTAssertFalse(AgentInboxService.flags(for: preferences).holds)
        let home = try shortHome(), model = DockModel(home: home)
        model.preferences.attentionHoldSeconds = 45
        let service = AgentInboxService(model: model, attention: AttentionCenter())
        service.start(bundledHelper: nil)
        addTeardownBlock { @MainActor in service.stop() }
        XCTAssertNil(service.lastError)
        XCTAssertEqual(AgentInboxFlags.read(home: home)?.holdSeconds, 45)
        model.preferences.answerPermissionsFromNotch = false
        service.preferencesChanged(bundledHelper: nil)
        XCTAssertEqual(AgentInboxFlags.read(home: home)?.answerFromNotch, false)
    }
}

/// The launch refresh keeps an existing Claude Code connection current without touching anything else.
final class ClaudeBridgeRefreshTests: XCTestCase {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func helper(_ home: URL, _ contents: String) throws -> URL {
        let url = home.appendingPathComponent("bundled-helper")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func backups(_ bridge: ClaudeBridge) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bridge.settings.deletingLastPathComponent().path).filter { $0.hasPrefix(ClaudeBridge.backupPrefix) }
    }

    func testRefreshReplacesAChangedHelperAndAddsMissingGroupsOnce() throws {
        let home = try home(), bridge = ClaudeBridge(home: home)
        XCTAssertFalse(try bridge.refresh(bundledHelper: helper(home, "v1")), "Nothing happens before the user connects")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.settings.path))

        // A connection made by an older version: 5-second hooks only, no question group, and another tool's hooks.
        try FileManager.default.createDirectory(at: bridge.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hooks: [String: Any] = [:]
        for event in ClaudeBridgeSettings.events {
            hooks[event] = [["hooks": [["type": "command", "command": ClaudeBridgeSettings.command(helper: bridge.helper, mode: "hook"), "timeout": 5]]]]
        }
        hooks["Stop"] = (hooks["Stop"] as! [[String: Any]]) + [["hooks": [["type": "command", "command": "other-tool done"]]]]
        let old: [String: Any] = ["hooks": hooks, "statusLine": ["type": "command", "command": "other-tool status"], "theme": "dark"]
        try JSONSerialization.data(withJSONObject: old).write(to: bridge.settings)
        try FileManager.default.createDirectory(at: bridge.directory, withIntermediateDirectories: true)
        try Data("v0".utf8).write(to: bridge.helper)

        XCTAssertTrue(try bridge.refresh(bundledHelper: helper(home, "v1"), hold: 60))
        XCTAssertEqual(try Data(contentsOf: bridge.helper), Data("v1".utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.settings)) as? [String: Any])
        let updated = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(updated["PreToolUse"]?.last?["matcher"] as? String, "AskUserQuestion")
        XCTAssertEqual((updated["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 75)
        XCTAssertTrue(updated["Stop"]?.contains { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "other-tool done" } == true)
        XCTAssertEqual((json["statusLine"] as? [String: String])?["command"], "other-tool status")
        XCTAssertEqual(json["theme"] as? String, "dark")
        XCTAssertTrue(bridge.enabled)

        XCTAssertFalse(try bridge.refresh(bundledHelper: helper(home, "v1"), hold: 60), "An up-to-date connection is not rewritten")
        XCTAssertTrue(try bridge.refresh(bundledHelper: helper(home, "v1"), hold: 120))
        XCTAssertEqual(try backups(bridge).count, 1, "Only the newest backup is kept")
    }

    func testConnectingKeepsOnlyTheNewestBackup() throws {
        let home = try home(), bridge = ClaudeBridge(home: home)
        try FileManager.default.createDirectory(at: bridge.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: bridge.settings)
        let bundled = try helper(home, "fixture")
        try bridge.setEnabled(true, bundledHelper: bundled)
        try bridge.setEnabled(false, bundledHelper: nil)
        try bridge.setEnabled(true, bundledHelper: bundled, hold: 30)
        let names = try backups(bridge)
        XCTAssertEqual(names.count, 1)
        let latest = try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.settings.deletingLastPathComponent().appendingPathComponent(names[0]))) as? [String: Any]
        XCTAssertEqual(latest?["theme"] as? String, "dark"); XCTAssertEqual((latest?["hooks"] as? [String: Any])?.isEmpty, true, "The newest backup is the disconnected state")
    }
}
