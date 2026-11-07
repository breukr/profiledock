import XCTest
@testable import DockCore

final class AgentInboxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func context(_ entrypoint: String? = "cli", flags: AgentInboxFlags? = AgentInboxFlags(holdSeconds: 30)) -> ClaudeHookContext {
        ClaudeHookContext(configDirectory: "/fixture/config", tty: "/dev/ttys001", pid: 42, entrypoint: entrypoint, flags: flags, now: now)
    }
    private func base(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": "fixture-session", "cwd": "/fixture/project", "hook_event_name": event].merging(extra) { _, new in new }
    }
    private let question: [String: Any] = ["questions": [["question": "Which framework?", "header": "Framework", "multiSelect": false,
                                                          "options": [["label": "React", "description": "Component library"], ["label": "Vue", "description": "Progressive framework"]]]]]

    // MARK: Decision output (Claude Code's documented hook JSON)

    func testPermissionDecisionsMatchClaudeCodeHookJSON() {
        XCTAssertEqual(ClaudeAttentionHook.output(for: .allow, kind: .permission, toolInput: ["command": "ls"]),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(ClaudeAttentionHook.output(for: .deny(message: "Not on main"), kind: .permission, toolInput: nil),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Not on main"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(ClaudeAttentionHook.output(for: .deny(message: nil), kind: .permission, toolInput: nil),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"The user denied this from ProfileDock."},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertNil(ClaudeAttentionHook.output(for: .passThrough, kind: .permission, toolInput: nil))
        XCTAssertNil(ClaudeAttentionHook.output(for: .answer(["React"]), kind: .permission, toolInput: nil))
        XCTAssertNil(ClaudeAttentionHook.output(for: .allow, kind: .finished, toolInput: nil))
    }

    func testQuestionAnswersEchoTheInputAndMapEachQuestion() {
        XCTAssertEqual(ClaudeAttentionHook.output(for: .answer(["React"]), kind: .question, toolInput: question),
                       #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"answers":{"Which framework?":"React"},"#
                       + #""questions":[{"header":"Framework","multiSelect":false,"options":[{"description":"Component library","label":"React"},{"description":"Progressive framework","label":"Vue"}],"question":"Which framework?"}]}}}"#)
        XCTAssertEqual(ClaudeAttentionHook.output(for: .deny(message: nil), kind: .question, toolInput: question),
                       #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The user declined to answer from ProfileDock."}}"#)
        // "allow" alone does not answer a question, and answers must match the questions one to one.
        XCTAssertNil(ClaudeAttentionHook.output(for: .allow, kind: .question, toolInput: question))
        XCTAssertNil(ClaudeAttentionHook.output(for: .answer([]), kind: .question, toolInput: question))
        XCTAssertNil(ClaudeAttentionHook.output(for: .answer(["React", "Vue"]), kind: .question, toolInput: question))
        XCTAssertNil(ClaudeAttentionHook.output(for: .answer(["\u{1B}"]), kind: .question, toolInput: question))
        XCTAssertNil(ClaudeAttentionHook.output(for: .passThrough, kind: .question, toolInput: question))
    }

    // MARK: Payload parsing

    func testTerminalPermissionRequestIsHeldWithPreviewAndProcessFacts() throws {
        let payload = base("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build", "description": "Remove the build folder"]])
        guard case .hold(let item)? = ClaudeAttentionHook.outgoing(payload: payload, mode: "hook", context: context()) else { return XCTFail("Expected a held request") }
        XCTAssertEqual(item.kind, .permission); XCTAssertEqual(item.title, "Run a command?"); XCTAssertEqual(item.message, "Remove the build folder")
        XCTAssertEqual(item.preview, "rm -rf build"); XCTAssertEqual(item.toolName, "Bash"); XCTAssertEqual(item.cwd, "/fixture/project")
        XCTAssertEqual(item.configDirectory, "/fixture/config"); XCTAssertEqual(item.tty, "/dev/ttys001"); XCTAssertEqual(item.pid, 42); XCTAssertEqual(item.entrypoint, "cli")
        XCTAssertEqual(item.deadline, now.addingTimeInterval(30)); XCTAssertEqual(item.source, "claude"); XCTAssertEqual(item.sessionID, "fixture-session")
    }

    func testRequestsAreOnlyHeldForTerminalSessionsWithNotchAnswersOn() {
        let payload = base("PermissionRequest", ["tool_name": "Edit", "tool_input": ["file_path": "/fixture/project/a.swift"]])
        for context in [context("claude-desktop"), context(nil), context(flags: nil), context(flags: AgentInboxFlags(answerFromNotch: false)), context(flags: AgentInboxFlags(popups: false))] {
            guard case .post(.attention(let item, nil))? = ClaudeAttentionHook.outgoing(payload: payload, mode: "hook", context: context) else { return XCTFail("Expected a display-only item") }
            XCTAssertNil(item.deadline); XCTAssertEqual(item.title, "Edit a file?"); XCTAssertEqual(item.preview, "/fixture/project/a.swift")
        }
    }

    func testPreviewsAndTitlesPerTool() {
        XCTAssertEqual(ClaudeAttentionHook.preview(tool: "WebFetch", input: ["url": "https://example.com/a", "prompt": "x"]), "https://example.com/a")
        XCTAssertEqual(ClaudeAttentionHook.preview(tool: "mcp__fixture__lookup", input: ["b": 1, "a": "/x"]), #"{"a":"/x","b":1}"#)
        XCTAssertNil(ClaudeAttentionHook.preview(tool: "Custom", input: [:]))
        XCTAssertEqual(ClaudeAttentionHook.title(tool: "WebFetch"), "Open a web page?")
        XCTAssertEqual(ClaudeAttentionHook.title(tool: "mcp__fixture__lookup"), "Use lookup from fixture?")
        XCTAssertEqual(ClaudeAttentionHook.title(tool: "Custom"), "Use Custom?")
    }

    func testSubagentsMissingFieldsAndUnknownEventsAreIgnored() {
        let request = base("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request.merging(["agent_id": "sub-1"]) { _, new in new }, mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request.filter { $0.key != "session_id" }, mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request.merging(["session_id": "../escape"]) { _, new in new }, mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request.filter { $0.key != "tool_name" }, mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request.filter { $0.key != "hook_event_name" }, mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: base("SessionStart"), mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: base("Notification", ["notification_type": "auth_success"]), mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: request, mode: "statusline", context: context()))
        // A missing cwd only drops the folder label.
        guard case .hold(let item)? = ClaudeAttentionHook.outgoing(payload: request.filter { $0.key != "cwd" }, mode: "hook", context: context()) else { return XCTFail() }
        XCTAssertNil(item.cwd); XCTAssertEqual(item.message, "Claude wants to use Bash.")
    }

    func testOversizedAndControlCharacterTextIsCleanedAndBounded() {
        let payload = base("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "echo \u{1B}[31mred\u{07}" + String(repeating: "x", count: 10_000), "description": "Line\u{0}one\n\n\n\nnext"]])
        guard case .hold(let item)? = ClaudeAttentionHook.outgoing(payload: payload, mode: "hook", context: context()) else { return XCTFail() }
        XCTAssertFalse(item.preview!.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{07}" })
        XCTAssertEqual(item.preview!.count, 300); XCTAssertTrue(item.preview!.hasSuffix("…"))
        XCTAssertEqual(item.message, "Lineone\n\nnext")
        let stop = base("Stop", ["last_assistant_message": String(repeating: "word ", count: 2_000)])
        guard case .post(.attention(let done, _))? = ClaudeAttentionHook.outgoing(payload: stop, mode: "hook", context: context()) else { return XCTFail() }
        XCTAssertEqual(done.message.count, 500); XCTAssertNil(done.deadline)
    }

    func testQuestionsArriveOnlyThroughTheAskGroup() {
        let payload = base("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": question])
        guard case .hold(let item)? = ClaudeAttentionHook.outgoing(payload: payload, mode: "ask", context: context()) else { return XCTFail("Expected a held question") }
        XCTAssertEqual(item.kind, .question); XCTAssertEqual(item.message, "Which framework?")
        XCTAssertEqual(item.questions, [AttentionQuestion(header: "Framework", question: "Which framework?", options: [AttentionOption(label: "React", detail: "Component library"), AttentionOption(label: "Vue", detail: "Progressive framework")], multiSelect: false)])
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: payload, mode: "hook", context: context()), "The regular PreToolUse group never reports a question")
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: base("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), mode: "ask", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: base("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": question]), mode: "hook", context: context()))
        XCTAssertNil(ClaudeAttentionHook.outgoing(payload: base("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": []]]), mode: "ask", context: context()))
        let many = ["questions": (0..<6).map { ["question": "Q\($0)?", "options": (0..<12).map { ["label": "O\($0)"] }] }]
        XCTAssertEqual(ClaudeAttentionHook.questions(many).count, 4); XCTAssertEqual(ClaudeAttentionHook.questions(many)[0].options.count, 8)
        guard case .post(.attention(let shown, _))? = ClaudeAttentionHook.outgoing(payload: payload, mode: "ask", context: context("claude-desktop")) else { return XCTFail() }
        XCTAssertNil(shown.deadline, "The Desktop Code tab shows its own question UI")
    }

    func testFinishedWaitingAndClearingEvents() {
        guard case .post(.attention(let done, nil))? = ClaudeAttentionHook.outgoing(payload: base("Stop", ["last_assistant_message": "All tests pass."]), mode: "hook", context: context(), transcript: { _ in XCTFail(); return nil }) else { return XCTFail() }
        XCTAssertEqual(done.kind, .finished); XCTAssertEqual(done.title, "Done"); XCTAssertEqual(done.message, "All tests pass.")
        guard case .post(.attention(let fromTranscript, _))? = ClaudeAttentionHook.outgoing(payload: base("Stop", ["transcript_path": "/fixture/t.jsonl"]), mode: "hook", context: context(), transcript: { $0 == "/fixture/t.jsonl" ? "From the transcript" : nil }) else { return XCTFail() }
        XCTAssertEqual(fromTranscript.message, "From the transcript")
        guard case .post(.attention(let idle, nil))? = ClaudeAttentionHook.outgoing(payload: base("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]), mode: "hook", context: context()) else { return XCTFail() }
        XCTAssertEqual(idle.kind, .waiting); XCTAssertEqual(idle.message, "Claude is waiting for your input")
        guard case .post(.attention(let prompt, "permission_prompt"))? = ClaudeAttentionHook.outgoing(payload: base("Notification", ["notification_type": "permission_prompt"]), mode: "hook", context: context()) else { return XCTFail() }
        XCTAssertEqual(prompt.kind, .permission); XCTAssertNil(prompt.deadline)
        XCTAssertEqual(ClaudeAttentionHook.outgoing(payload: base("UserPromptSubmit", ["prompt": "PRIVATE"]), mode: "hook", context: context()), .post(.clear(source: "claude", sessionID: "fixture-session", includeFinished: true)))
        XCTAssertEqual(ClaudeAttentionHook.outgoing(payload: base("PostToolUse"), mode: "hook", context: context()), .post(.clear(source: "claude", sessionID: "fixture-session", includeFinished: false)))
    }

    // MARK: Transcript tail

    func testTranscriptTailFindsTheLastAssistantTextOnly() throws {
        func line(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        let lines = [
            try line(["type": "assistant", "message": ["content": [["type": "text", "text": "Older answer"]]]]),
            try line(["type": "assistant", "message": ["content": [["type": "text", "text": "Final summary"], ["type": "tool_use", "name": "Bash"]]]]),
            try line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "Subagent text"]]]]),
            try line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read"]]]]),
            try line(["type": "user", "message": ["content": "PRIVATE prompt"]]),
            "{not json",
        ]
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(tail: Data(lines.joined(separator: "\n").utf8), partial: false), "Final summary")
        XCTAssertNil(ClaudeTranscript.lastAssistantText(tail: Data(lines[4].utf8), partial: false))
        // A cut first line is skipped instead of misread.
        XCTAssertNil(ClaudeTranscript.lastAssistantText(tail: Data(lines[0].utf8), partial: true))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let filler = try (0..<400).map { try line(["type": "user", "message": ["content": String(repeating: "f", count: 300) + "\($0)"]]) }
        try (lines.prefix(2) + filler + [try line(["type": "assistant", "message": ["content": [["type": "text", "text": "At the very end"]]]])]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 65_536)
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(path: file.path), "At the very end")
        XCTAssertNil(ClaudeTranscript.lastAssistantText(path: file.deletingPathExtension().appendingPathExtension("txt").path))
        XCTAssertNil(ClaudeTranscript.lastAssistantText(path: "relative.jsonl"))
        XCTAssertNil(ClaudeTranscript.lastAssistantText(path: folder.appendingPathComponent("missing.jsonl").path))
    }

    // MARK: Protocol

    func testMessagesRoundTripThroughFramesAndOversizeIsRejected() throws {
        let item = AgentAttention(id: "fixture-id", source: "claude", sessionID: "s1", kind: .question, title: "Q", message: "Which?",
                                  questions: [AttentionQuestion(header: nil, question: "Which?", options: [AttentionOption(label: "A")], multiSelect: true)],
                                  receivedAt: now, deadline: now.addingTimeInterval(5))
        let messages: [AgentInboxMessage] = [.attention(item, notification: "permission_prompt"), .decision(id: "fixture-id", decision: .answer(["A"])),
                                             .decision(id: "x", decision: .deny(message: nil)), .clear(source: "claude", sessionID: "s1", includeFinished: true)]
        var stream = Data()
        for message in messages { stream.append(try AgentInbox.encode(message)) }
        var frames = AgentInboxFrames(), bodies: [Data] = []
        // Delivered in uneven pieces, as a socket may.
        for start in stride(from: 0, to: stream.count, by: 7) { bodies += try frames.append(stream.subdata(in: start..<min(start + 7, stream.count))) }
        XCTAssertEqual(try bodies.map(AgentInbox.decode), messages)

        var small = AgentInboxFrames(limit: 16)
        XCTAssertThrowsError(try small.append(AgentInboxFrames.frame(Data(repeating: 32, count: 17))))
        var partial = AgentInboxFrames()
        XCTAssertThrowsError(try partial.append(Data([0xFF, 0xFF, 0xFF, 0x00])), "A frame announcing more than 256 KB is refused before it arrives")
        XCTAssertThrowsError(try AgentInbox.decode(Data(#"{"type":"unknown"}"#.utf8)))
        XCTAssertThrowsError(try AgentInbox.encode(.clear(source: "claude", sessionID: String(repeating: "s", count: AgentInbox.frameLimit), includeFinished: false)))
    }

    func testSanitizedItemsKeepDeadlinesOnlyWhereADecisionIsPossible() {
        func make(_ kind: AttentionKind, id: String = "fixture-id", deadline: Date?) -> AgentAttention {
            AgentAttention(id: id, source: "claude", sessionID: "s1", kind: kind, title: "T", message: "M", tty: "/dev/console", pid: -1, deadline: deadline)
        }
        XCTAssertNotNil(make(.permission, deadline: now.addingTimeInterval(60)).sanitized(now: now)?.deadline)
        XCTAssertNil(make(.finished, deadline: now.addingTimeInterval(60)).sanitized(now: now)?.deadline)
        XCTAssertNil(make(.permission, deadline: now.addingTimeInterval(-1)).sanitized(now: now)?.deadline)
        XCTAssertNil(make(.permission, deadline: now.addingTimeInterval(3_600)).sanitized(now: now)?.deadline)
        XCTAssertNil(make(.permission, deadline: nil).sanitized(now: now)?.tty)
        XCTAssertNil(make(.permission, deadline: nil).sanitized(now: now)?.pid)
        XCTAssertNil(make(.permission, id: "../x", deadline: nil).sanitized(now: now))
        XCTAssertNil(make(.question, deadline: nil).sanitized(now: now), "A question without choices cannot be shown")
    }

    func testFlagsRoundTripAndClampTheHold() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(AgentInboxFlags.read(home: home))
        try AgentInboxFlags(popups: true, answerFromNotch: false, holdSeconds: 45).write(home: home)
        XCTAssertEqual(AgentInboxFlags.read(home: home), AgentInboxFlags(popups: true, answerFromNotch: false, holdSeconds: 45))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: AgentInbox.flagsFile(home: home).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: AgentInbox.directory(home: home).path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(AgentInboxFlags(holdSeconds: 100_000).holdSeconds, 600)
        XCTAssertEqual(AgentInbox.blockingTimeout(hold: 90), 105)
        try Data(#"{"popups":true,"answerFromNotch":true,"holdSeconds":-5}"#.utf8).write(to: AgentInbox.flagsFile(home: home))
        XCTAssertEqual(AgentInboxFlags.read(home: home)?.holdSeconds, 1)
    }

    func testClientFailsQuicklyWithoutAnApp() {
        let socket = URL(fileURLWithPath: "/tmp/pdi-missing-\(UUID().uuidString.prefix(8)).sock")
        let start = Date()
        XCTAssertFalse(AgentInboxClient.post(.clear(source: "claude", sessionID: "s1", includeFinished: false), socket: socket))
        XCTAssertNil(AgentInboxClient.request(AgentAttention(source: "claude", sessionID: "s1", kind: .permission, title: "T", message: "M", deadline: Date().addingTimeInterval(30)), socket: socket, deadline: Date().addingTimeInterval(30)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertNil(AgentInbox.address("/" + String(repeating: "a", count: 200)))
    }

    // MARK: Hook registration

    private func parsedHooks(_ data: Data) throws -> [String: [[String: Any]]] {
        try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
    }

    func testOnlyTheTwoWaitingGroupsGetTheLongTimeout() throws {
        let helper = URL(fileURLWithPath: "/fixture/helper")
        let hooks = try parsedHooks(ClaudeBridgeSettings.updating(nil, helper: helper, enabled: true, hold: 60))
        for (event, groups) in hooks {
            for group in groups {
                for hook in group["hooks"] as! [[String: Any]] {
                    let waits = event == "PermissionRequest" || group["matcher"] as? String == "AskUserQuestion"
                    XCTAssertEqual(hook["timeout"] as? Int, waits ? 75 : 5, "\(event) \(group["matcher"] ?? "")")
                }
            }
        }
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"])
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertEqual(preToolUse[1]["matcher"] as? String, "AskUserQuestion")
        XCTAssertEqual((preToolUse[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "'/fixture/helper' ask")
        XCTAssertEqual(hooks["PermissionRequest"]?.count, 1)
    }

    func testRegistrationIsIdempotentAndPreservesOtherToolsHooks() throws {
        let helper = URL(fileURLWithPath: "/fixture/helper")
        let original = Data(#"{"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"other-tool ask"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"other-tool permit","timeout":30}]}],"Stop":[{"hooks":[{"type":"command","command":"other-tool done"}]}]},"statusLine":{"type":"command","command":"other-tool status"}}"#.utf8)
        let first = try ClaudeBridgeSettings.updating(original, helper: helper, enabled: true, hold: 90)
        XCTAssertEqual(first, try ClaudeBridgeSettings.updating(first, helper: helper, enabled: true, hold: 90))
        let hooks = try parsedHooks(first)
        XCTAssertEqual(hooks["PreToolUse"]?.first?["hooks"] as? [[String: String]], [["type": "command", "command": "other-tool ask"]])
        XCTAssertEqual((hooks["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 30)
        // A new hold changes only ProfileDock's timeouts.
        let longer = try parsedHooks(ClaudeBridgeSettings.updating(first, helper: helper, enabled: true, hold: 120))
        XCTAssertEqual((longer["PermissionRequest"]?.last?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 135)
        XCTAssertEqual((longer["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 30)
        XCTAssertEqual(longer["PreToolUse"]?.count, 3)
        // Refreshing leaves the status line alone; disconnecting restores the original exactly.
        let refreshed = try ClaudeBridgeSettings.updating(Data(#"{"hooks":{}}"#.utf8), helper: helper, enabled: true, statusline: false)
        XCTAssertNil((try JSONSerialization.jsonObject(with: refreshed) as? [String: Any])?["statusLine"])
        let removed = try ClaudeBridgeSettings.updating(first, helper: helper, enabled: false)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, try JSONSerialization.jsonObject(with: original) as? NSDictionary)
    }
}
