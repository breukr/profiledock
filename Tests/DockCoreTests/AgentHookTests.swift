import XCTest
@testable import DockCore

/// Reply holds, other agents' payloads and their hook registrations. All content is fictional; files live in temp folders.
final class AgentHookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let helper = URL(fileURLWithPath: "/fixture/Account Dock/ProfileDockClaude")

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-hooks-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func claude(_ entrypoint: String? = "cli", flags: AgentInboxFlags? = AgentInboxFlags(), markers: StopReplyMarkers? = nil, at time: Date? = nil) -> ClaudeHookContext {
        ClaudeHookContext(tty: "/dev/ttys001", pid: 42, entrypoint: entrypoint, flags: flags, now: time ?? now, replyMarkers: markers)
    }
    private func stop(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "fixture-session", "cwd": "/fixture/project", "hook_event_name": "Stop", "last_assistant_message": "Wrote the Atlas report."].merging(extra) { _, new in new }
    }

    // MARK: Golden Stop output

    func testReplyPrintsTheDocumentedStopOutputForClaudeAndCodex() {
        let golden = #"{"decision":"block","reason":"Also update docs/notes.md"}"#
        XCTAssertEqual(ClaudeAttentionHook.output(for: .reply("Also update docs/notes.md"), kind: .finished, toolInput: nil), golden)
        XCTAssertEqual(StopReply.output(for: .reply("  Also update docs/notes.md\n")), golden, "Codex uses the same documented shape")
        XCTAssertEqual(StopReply.output(for: .reply("Line one\u{1B}\n\n\n\nLine two")), #"{"decision":"block","reason":"Line one\n\nLine two"}"#)
        for decision: AttentionDecision in [.passThrough, .allow, .deny(message: "no"), .answer(["A"]), .reply("   ")] {
            XCTAssertNil(StopReply.output(for: decision), "\(decision)")
            XCTAssertNil(ClaudeAttentionHook.output(for: decision, kind: .finished, toolInput: nil))
        }
        XCTAssertNil(ClaudeAttentionHook.output(for: .reply("x"), kind: .permission, toolInput: nil), "A reply never answers a permission request")
        XCTAssertEqual(StopReply.output(for: .reply(String(repeating: "a", count: 9_000)))?.count, #"{"decision":"block","reason":""}"#.count + 8_000)
    }

    // MARK: When a finished turn waits

    func testFinishedTurnsWaitOnlyWhereAReplyCanReachTheSession() throws {
        guard case .hold(let held)? = ClaudeAttentionHook.outgoing(payload: stop(), mode: "hook", context: claude()) else { return XCTFail("Expected a held turn") }
        XCTAssertEqual(held.kind, .finished); XCTAssertEqual(held.deadline, now.addingTimeInterval(12)); XCTAssertEqual(held.message, "Wrote the Atlas report.")
        XCTAssertEqual(StopReply.limit(receivedAt: held.receivedAt), now.addingTimeInterval(600))
        guard case .hold? = ClaudeAttentionHook.outgoing(payload: stop(), mode: "hook", context: claude("claude-desktop")) else { return XCTFail("Desktop chats can be continued") }
        for context in [claude(nil), claude("claude-vscode"), claude(flags: nil), claude(flags: AgentInboxFlags(popups: false)), claude(flags: AgentInboxFlags(replyHoldSeconds: 0))] {
            guard case .post(.attention(let item, nil))? = ClaudeAttentionHook.outgoing(payload: stop(), mode: "hook", context: context) else { return XCTFail("Expected Done without waiting") }
            XCTAssertNil(item.deadline)
        }
        // "Answer permissions from the notch" is a separate switch.
        guard case .hold? = ClaudeAttentionHook.outgoing(payload: stop(), mode: "hook", context: claude(flags: AgentInboxFlags(answerFromNotch: false))) else { return XCTFail() }
    }

    func testAContinuedTurnWaitsAgainOnlyAfterAPopUpReply() throws {
        let markers = StopReplyMarkers(directory: temporaryFolder()), live = Date()
        let continued = stop(["stop_hook_active": true])
        guard case .post? = ClaudeAttentionHook.outgoing(payload: continued, mode: "hook", context: claude(markers: markers, at: live)) else { return XCTFail("Another tool's loop is not slowed down") }
        markers.mark(source: "claude", sessionID: "fixture-session")
        guard case .hold? = ClaudeAttentionHook.outgoing(payload: continued, mode: "hook", context: claude(markers: markers, at: live)) else { return XCTFail("A reply's own turn can be answered again") }
        guard case .post? = ClaudeAttentionHook.outgoing(payload: continued, mode: "hook", context: claude(markers: markers, at: live)) else { return XCTFail("The marker is used once") }
        markers.mark(source: "codex", sessionID: "fixture-session")
        XCTAssertFalse(markers.consume(source: "claude", sessionID: "fixture-session"), "Markers are per agent")
        XCTAssertFalse(markers.consume(source: "codex", sessionID: "fixture-session", now: Date().addingTimeInterval(7_200)), "Old markers are ignored")
        markers.mark(source: "claude", sessionID: "../escape")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: markers.directory.path), [])
    }

    func testCodexStopWaitsInATerminalOrTheCodexAppAndPermissionsNever() {
        let flags = AgentInboxFlags()
        func context(_ entrypoint: String?) -> CodexHookContext { CodexHookContext(codexHome: "/fixture/.codex", tty: "/dev/ttys002", pid: 7, entrypoint: entrypoint, flags: flags, now: now) }
        guard case .hold(let item)? = CodexAttentionHook.outgoing(payload: stop(["turn_id": "turn-1"]), context: context("cli")) else { return XCTFail() }
        XCTAssertEqual(item.source, "codex"); XCTAssertEqual(item.tty, "/dev/ttys002"); XCTAssertEqual(item.pid, 7); XCTAssertEqual(item.deadline, now.addingTimeInterval(12))
        guard case .hold? = CodexAttentionHook.outgoing(payload: stop(), context: context("codex-desktop")) else { return XCTFail() }
        guard case .post? = CodexAttentionHook.outgoing(payload: stop(), context: context("ide")) else { return XCTFail() }
        let permission: [String: Any] = ["session_id": "thr-fixture", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "make"]]
        guard case .post(.attention(let request, _))? = CodexAttentionHook.outgoing(payload: permission, context: context("cli")) else { return XCTFail() }
        XCTAssertNil(request.deadline)
    }

    func testCodexEntrypointComesFromTheProcessTree() {
        let terminal = AgentProcessInfo(pid: 10, name: "codex", path: "/opt/homebrew/bin/codex", tty: "/dev/ttys004")
        let app = AgentProcessInfo(pid: 11, name: "codex", path: "/Applications/Codex.app/Contents/Resources/codex", tty: nil)
        let shell = AgentProcessInfo(pid: 9, name: "zsh", path: "/bin/zsh", tty: "/dev/ttys004")
        XCTAssertEqual(AgentProcess.agent(in: [shell, terminal]), terminal)
        XCTAssertEqual(AgentProcess.agent(in: [shell, terminal], names: ["codex"]), terminal)
        XCTAssertEqual(AgentProcess.codexEntrypoint(agent: terminal, host: "/System/Applications/Utilities/Terminal.app"), "cli")
        XCTAssertEqual(AgentProcess.hostApplication(in: [app]), "/Applications/Codex.app")
        XCTAssertEqual(AgentProcess.codexEntrypoint(agent: app, host: "/Applications/Codex.app"), "codex-desktop")
        XCTAssertEqual(AgentProcess.codexEntrypoint(agent: app, host: "/Applications/ChatGPT.app"), "codex-desktop")
        XCTAssertEqual(AgentProcess.codexEntrypoint(agent: app, host: "/Applications/Visual Studio Code.app"), "ide")
        XCTAssertNil(AgentProcess.codexEntrypoint(agent: nil, host: nil))
        XCTAssertFalse(AgentProcess.ancestors().isEmpty, "The test runner has a parent process")
    }

    // MARK: Inbox messages and switches

    func testExtendMessagesAndReplyFlagsRoundTrip() throws {
        let message = AgentInboxMessage.extend(id: "req-1", until: now)
        let frame = try AgentInbox.encode(message)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as? NSDictionary, ["type": "extend", "id": "req-1", "until": 1_800_000_000] as NSDictionary)
        XCTAssertEqual(try AgentInbox.decode(Data(frame.dropFirst(4))), message)
        XCTAssertEqual(try AgentInbox.decode(Data(#"{"type":"decision","id":"r","decision":{"reply":{"_0":"Go on"}}}"#.utf8)), .decision(id: "r", decision: .reply("Go on")))

        let home = temporaryFolder()
        try Data(#"{"popups":true,"answerFromNotch":true,"holdSeconds":90}"#.utf8).write(to: { try! FileManager.default.createDirectory(at: AgentInbox.directory(home: home), withIntermediateDirectories: true); return AgentInbox.flagsFile(home: home) }())
        XCTAssertEqual(AgentInboxFlags.read(home: home)?.replyHoldSeconds, 12, "A file from before the key existed reads as the default")
        try AgentInboxFlags(replyHoldSeconds: 0).write(home: home)
        XCTAssertEqual(AgentInboxFlags.read(home: home)?.holdsReplies, false)
        XCTAssertEqual(AgentInboxFlags(replyHoldSeconds: 5_000).replyHoldSeconds, 600)
        XCTAssertEqual(AgentInboxFlags(replyHoldSeconds: -3).replyHoldSeconds, 0)
        XCTAssertEqual(AgentInbox.replyTimeout, 615)
    }

    func testRegistrySourcesWithDashesPassSanitizing() {
        func item(_ source: String) -> AgentAttention { AgentAttention(source: source, sessionID: "s1", kind: .finished, title: "Done", message: "") }
        XCTAssertEqual(item("cursor-cli").sanitized(now: now)?.source, "cursor-cli")
        XCTAssertNil(item("Cursor").sanitized(now: now)); XCTAssertNil(item("-x").sanitized(now: now)); XCTAssertNil(item("a/b").sanitized(now: now))
    }

    // MARK: Other agents' payloads (fictional fixtures)

    private func attention(_ agent: String, _ payload: [String: Any], tty: String? = "/dev/ttys005") -> (AgentAttention, String?)? {
        guard case .attention(let item, let notification)? = AgentHookAdapters.message(agent: agent, payload: payload, context: AgentHookContext(tty: tty, pid: 99, now: now)) else { return nil }
        return (item, notification)
    }

    func testGeminiPayloads() throws {
        let base: [String: Any] = ["session_id": "gem-1", "cwd": "/fixture/meridian", "transcript_path": "/fixture/t.json", "timestamp": "2026-11-07T10:00:00Z"]
        let (done, _) = try XCTUnwrap(attention("gemini", base.merging(["hook_event_name": "AfterAgent", "prompt": "PRIVATE prompt", "prompt_response": "Refactored the Veldkamp parser."]) { $1 }))
        XCTAssertEqual(done.source, "gemini"); XCTAssertEqual(done.kind, .finished); XCTAssertEqual(done.message, "Refactored the Veldkamp parser.")
        XCTAssertEqual(done.cwd, "/fixture/meridian"); XCTAssertEqual(done.tty, "/dev/ttys005"); XCTAssertEqual(done.pid, 99); XCTAssertEqual(done.entrypoint, "cli"); XCTAssertNil(done.deadline)
        let (ask, type) = try XCTUnwrap(attention("gemini", base.merging(["hook_event_name": "Notification", "notification_type": "ToolPermission", "message": "Allow shell command?",
                                                                     "details": ["tool_name": "run_shell_command", "command": "make fixture"]]) { $1 }))
        XCTAssertEqual(ask.kind, .permission); XCTAssertEqual(ask.title, "Run a command?"); XCTAssertEqual(ask.preview, "make fixture"); XCTAssertEqual(type, "permission_prompt")
        XCTAssertEqual(AgentHookAdapters.message(agent: "gemini", payload: base.merging(["hook_event_name": "BeforeAgent"]) { $1 }, context: AgentHookContext()), .clear(source: "gemini", sessionID: "gem-1", includeFinished: true))
        XCTAssertEqual(AgentHookAdapters.message(agent: "gemini", payload: base.merging(["hook_event_name": "AfterTool"]) { $1 }, context: AgentHookContext()), .clear(source: "gemini", sessionID: "gem-1", includeFinished: false))
        XCTAssertNil(AgentHookAdapters.message(agent: "gemini", payload: base.merging(["hook_event_name": "BeforeTool"]) { $1 }, context: AgentHookContext()))
    }

    func testCursorPayloadsTellTheAppFromTheCLI() throws {
        let stop: [String: Any] = ["conversation_id": "668320d2-2fd8-4888-b33c-2a466fec86e7", "generation_id": "g1", "hook_event_name": "stop", "status": "completed",
                                   "loop_count": 0, "workspace_roots": ["/fixture/rijnstaal"], "cursor_version": "2.0.0", "user_email": NSNull()]
        let (app, _) = try XCTUnwrap(attention("cursor", stop, tty: nil))
        XCTAssertEqual(app.source, "cursor"); XCTAssertEqual(app.kind, .finished); XCTAssertEqual(app.cwd, "/fixture/rijnstaal"); XCTAssertNil(app.entrypoint)
        XCTAssertEqual(try XCTUnwrap(attention("cursor", stop)).0.source, "cursor-cli")
        XCTAssertEqual(try XCTUnwrap(attention("cursor", stop.merging(["status": "error"]) { $1 })).0.title, "Stopped")
        XCTAssertEqual(AgentHookAdapters.message(agent: "cursor", payload: stop.merging(["status": "aborted"]) { $1 }, context: AgentHookContext()),
                       .clear(source: "cursor", sessionID: "668320d2-2fd8-4888-b33c-2a466fec86e7", includeFinished: true))
    }

    func testClaudeCompatiblePayloadsFromCopilotDroidAndQwen() throws {
        for agent in ["copilot", "droid", "qwen"] {
            let base: [String: Any] = ["session_id": "\(agent)-1", "cwd": "/fixture/noordhaven", "transcript_path": "/fixture/t.jsonl", "permission_mode": "default"]
            let (done, _) = try XCTUnwrap(attention(agent, base.merging(["hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "Done with the sync."]) { $1 }))
            XCTAssertEqual(done.source, agent); XCTAssertEqual(done.kind, .finished); XCTAssertNil(done.deadline)
            let (prompt, type) = try XCTUnwrap(attention(agent, base.merging(["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Allow edit?"]) { $1 }))
            XCTAssertEqual(prompt.kind, .permission); XCTAssertEqual(prompt.message, "Allow edit?"); XCTAssertEqual(type, "permission_prompt")
            XCTAssertEqual(try XCTUnwrap(attention(agent, base.merging(["hook_event_name": "Notification", "notification_type": "idle_prompt"]) { $1 })).0.kind, .waiting)
            XCTAssertEqual(AgentHookAdapters.message(agent: agent, payload: base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "PRIVATE"]) { $1 }, context: AgentHookContext()),
                           .clear(source: agent, sessionID: "\(agent)-1", includeFinished: true))
            XCTAssertNil(AgentHookAdapters.message(agent: agent, payload: base.merging(["hook_event_name": "Stop", "agent_id": "sub"]) { $1 }, context: AgentHookContext()), "Subagents stay out")
        }
        let (request, _) = try XCTUnwrap(attention("qwen", ["session_id": "qwen-2", "hook_event_name": "PermissionRequest", "tool_name": "run_shell_command",
                                                           "tool_input": ["command": "npm test", "description": "Run the tests"]]))
        XCTAssertEqual(request.title, "Run a command?"); XCTAssertEqual(request.preview, "npm test"); XCTAssertEqual(request.message, "Run the tests"); XCTAssertNil(request.deadline)
        // Copilot's camelCase payload names are accepted too.
        XCTAssertNotNil(attention("copilot", ["sessionId": "cop-3", "hook_event_name": "Stop"]))
    }

    func testOpenCodePluginEvents() throws {
        let (done, _) = try XCTUnwrap(attention("opencode", ["hook_event_name": "session.idle", "session_id": "ses_fixture01", "cwd": "/fixture/atlas"]))
        XCTAssertEqual(done.source, "opencode"); XCTAssertEqual(done.kind, .finished)
        let (permission, _) = try XCTUnwrap(attention("opencode", ["hook_event_name": "permission.asked", "session_id": "ses_fixture01", "permission": "bash",
                                                                  "patterns": ["git status", "git diff"], "title": "Run git"]))
        XCTAssertEqual(permission.title, "Run a command?"); XCTAssertEqual(permission.preview, "git status && git diff"); XCTAssertEqual(permission.message, "Run git")
        let (question, _) = try XCTUnwrap(attention("opencode", ["hook_event_name": "question.asked", "session_id": "ses_fixture01",
                                                                "questions": [["question": "Which port?", "header": "Port", "options": [["label": "3000"], ["label": "8080", "description": "Alt"]], "multiple": false]]]))
        XCTAssertEqual(question.kind, .question); XCTAssertNil(question.deadline); XCTAssertEqual(question.questions.first?.options.map(\.label), ["3000", "8080"])
        XCTAssertEqual(AgentHookAdapters.message(agent: "opencode", payload: ["hook_event_name": "permission.replied", "session_id": "ses_fixture01"], context: AgentHookContext()),
                       .clear(source: "opencode", sessionID: "ses_fixture01", includeFinished: false))
        XCTAssertNil(AgentHookAdapters.message(agent: "unknown", payload: ["hook_event_name": "Stop", "session_id": "s"], context: AgentHookContext()))
        XCTAssertNil(AgentHookAdapters.message(agent: "opencode", payload: ["hook_event_name": "session.idle", "session_id": "../x"], context: AgentHookContext()))
    }

    // MARK: Registrations in other agents' settings

    private func json(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]) }

    func testGroupedRegistrationsAreIdempotentAndKeepOtherToolsEntries() throws {
        let other = #"{"type":"command","command":"/fixture/other-bridge --source x","timeout":5000}"#
        for target in [AgentHookTarget.gemini, .droid, .qwen] {
            let original = Data(#"{"general":{"vimMode":true},"hooks":{"Stop":[{"hooks":[\#(other)]}],"AfterAgent":[{"hooks":[\#(other)]}],"Notification":[{"matcher":"*","hooks":[\#(other)]}]}}"#.utf8)
            let first = try XCTUnwrap(AgentHookConfig.updating(original, target: target, helper: helper, enabled: true))
            XCTAssertTrue(AgentHookConfig.sameJSON(try AgentHookConfig.updating(first, target: target, helper: helper, enabled: true), first), "\(target.id) idempotent")
            XCTAssertTrue(AgentHookConfig.isConnected(first, target: target, helper: helper)); XCTAssertFalse(AgentHookConfig.isConnected(original, target: target, helper: helper))
            let file = try json(first), hooks = try XCTUnwrap(file["hooks"] as? [String: [[String: Any]]])
            XCTAssertEqual((file["general"] as? [String: Bool])?["vimMode"], true)
            XCTAssertEqual(Set(hooks.keys), Set(target.events.map(\.name) + ["Stop", "AfterAgent", "Notification"]))
            for event in target.events {
                let groups = try XCTUnwrap(hooks[event.name]), ours = try XCTUnwrap((groups.last?["hooks"] as? [[String: Any]])?.first)
                XCTAssertEqual(ours["command"] as? String, AgentHookConfig.command(helper: helper, agent: target.id))
                XCTAssertEqual(ours["timeout"] as? Int, target.id == "gemini" ? 5_000 : 5, "Display-only hooks never get a long timeout")
                XCTAssertEqual(groups.last?["matcher"] as? String, event.matcher)
                if ["Stop", "AfterAgent", "Notification"].contains(event.name) { XCTAssertEqual(groups.count, 2, "Other tool's group kept") }
            }
            let removed = try AgentHookConfig.updating(first, target: target, helper: helper, enabled: false)
            XCTAssertTrue(AgentHookConfig.sameJSON(removed, original), "\(target.id) disconnect restores the original")
            XCTAssertTrue(AgentHookConfig.hasEntries(first, target: target, helper: helper)); XCTAssertFalse(AgentHookConfig.hasEntries(original, target: target, helper: helper))
            XCTAssertThrowsError(try AgentHookConfig.updating(Data(#"{"hooks":[]}"#.utf8), target: target, helper: helper, enabled: true))
            XCTAssertThrowsError(try AgentHookConfig.updating(Data("not json".utf8), target: target, helper: helper, enabled: true))
        }
        // A settings file without hooks gets them, and loses the key again on disconnect.
        let plain = Data(#"{"model":"fixture"}"#.utf8)
        let connected = try AgentHookConfig.updating(plain, target: .qwen, helper: helper, enabled: true)
        XCTAssertTrue(AgentHookConfig.sameJSON(try AgentHookConfig.updating(connected, target: .qwen, helper: helper, enabled: false), plain))
        // Droid's hooks.json may list the events at the top level.
        let topLevel = Data(#"{"Stop":[{"hooks":[\#(other)]}]}"#.utf8)
        let droid = try json(AgentHookConfig.updating(topLevel, target: .droid, helper: helper, enabled: true, fileName: "hooks.json"))
        XCTAssertNil(droid["hooks"]); XCTAssertEqual((droid["Stop"] as? [Any])?.count, 2)
    }

    func testCursorRegistrationKeepsTheFlatFormat() throws {
        let original = Data(#"{"version":1,"hooks":{"stop":[{"command":"/fixture/other-bridge --source cursor"}],"beforeShellExecution":[{"command":"/fixture/audit.sh"}]}}"#.utf8)
        let first = try XCTUnwrap(AgentHookConfig.updating(original, target: .cursor, helper: helper, enabled: true))
        XCTAssertTrue(AgentHookConfig.sameJSON(try AgentHookConfig.updating(first, target: .cursor, helper: helper, enabled: true), first))
        let hooks = try XCTUnwrap(try json(first)["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["stop"]?.count, 2); XCTAssertEqual(hooks["beforeShellExecution"]?.count, 1, "No permission hook: an empty answer could block Cursor's commands")
        XCTAssertEqual(hooks["stop"]?.last?["command"] as? String, AgentHookConfig.command(helper: helper, agent: "cursor")); XCTAssertEqual(hooks["stop"]?.last?["timeout"] as? Int, 5)
        XCTAssertTrue(AgentHookConfig.sameJSON(try AgentHookConfig.updating(first, target: .cursor, helper: helper, enabled: false), original))
        XCTAssertEqual(try json(AgentHookConfig.updating(nil, target: .cursor, helper: helper, enabled: true))["version"] as? Int, 1)
    }

    func testOwnedFilesForCopilotAndOpenCode() throws {
        let copilot = try json(AgentHookConfig.updating(nil, target: .copilot, helper: helper, enabled: true))
        XCTAssertEqual(copilot["version"] as? Int, 1)
        let hooks = try XCTUnwrap(copilot["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), ["Stop", "Notification", "UserPromptSubmit", "PostToolUse"])
        XCTAssertEqual(hooks["Stop"]?.first?["bash"] as? String, AgentHookConfig.command(helper: helper, agent: "copilot")); XCTAssertEqual(hooks["Stop"]?.first?["timeoutSec"] as? Int, 5)
        XCTAssertNil(try AgentHookConfig.updating(Data("{}".utf8), target: .copilot, helper: helper, enabled: false), "Disconnecting removes the whole file")

        let plugin = String(decoding: try XCTUnwrap(AgentHookConfig.updating(nil, target: .opencode, helper: helper, enabled: true)), as: UTF8.self)
        XCTAssertTrue(plugin.contains(#"const [HELPER] = ["/fixture/Account Dock/ProfileDockClaude"];"#))
        XCTAssertTrue(plugin.contains("profiledock-opencode-plugin 1")); XCTAssertTrue(plugin.contains(#"spawn(HELPER, ["agent", "opencode"]"#))
        for event in ["session.idle", "permission.asked", "permission.updated", "question.asked", "permission.replied", "question.replied", "question.rejected"] {
            XCTAssertTrue(plugin.contains("\"\(event)\""), event)
        }
        XCTAssertTrue(plugin.contains("existsSync(HELPER)"), "Fail-open when ProfileDock is gone")
        XCTAssertEqual(plugin.components(separatedBy: "export ").count, 2, "One export, so OpenCode loads it once")
        XCTAssertTrue(AgentHookConfig.isConnected(Data(plugin.utf8), target: .opencode, helper: helper))
        XCTAssertFalse(AgentHookConfig.isConnected(Data((plugin + "// edited").utf8), target: .opencode, helper: helper))
    }

    func testCommandsFailOpenAndQuoteThePath() throws {
        XCTAssertEqual(AgentHookConfig.command(helper: helper, agent: "gemini"),
                       #"/bin/sh -c '[ -x '\''/fixture/Account Dock/ProfileDockClaude'\'' ] && '\''/fixture/Account Dock/ProfileDockClaude'\'' agent gemini; exit 0'"#)
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = folder.appendingPathComponent("gone/ProfileDockClaude")
        let shell = Process(), output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh"); shell.arguments = ["-c", AgentHookConfig.command(helper: missing, agent: "qwen")]
        shell.standardOutput = output; shell.standardInput = FileHandle.nullDevice
        try shell.run(); shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0, "A removed helper never fails the agent's hook")
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
