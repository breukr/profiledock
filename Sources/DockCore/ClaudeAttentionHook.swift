import Foundation

/// Facts about the hook process that are not in Claude Code's payload.
public struct ClaudeHookContext: Sendable {
    public var configDirectory: String?
    public var tty: String?
    public var pid: Int32?
    /// `CLAUDE_CODE_ENTRYPOINT`: "cli" for a terminal session, "claude-desktop" for the Desktop Code tab, and so on.
    public var entrypoint: String?
    /// The app's switches. Nil when the app never wrote them: nothing is held.
    public var flags: AgentInboxFlags?
    public var now: Date
    /// Remembers sessions continued by a pop-up reply (`StopReply`). Nil: a continued turn is never held again.
    public var replyMarkers: StopReplyMarkers?
    public init(configDirectory: String? = nil, tty: String? = nil, pid: Int32? = nil, entrypoint: String? = nil, flags: AgentInboxFlags? = nil, now: Date = Date(),
                replyMarkers: StopReplyMarkers? = nil) {
        self.configDirectory = configDirectory; self.tty = tty; self.pid = pid; self.entrypoint = entrypoint; self.flags = flags; self.now = now
        self.replyMarkers = replyMarkers
    }
}

/// Turns Claude Code hook payloads into inbox messages, and the app's decision back into Claude Code's hook JSON.
/// Payload text is untrusted: it is cleaned, bounded and only ever displayed.
public enum ClaudeAttentionHook {
    public enum Outgoing: Equatable {
        /// Fire and forget.
        case post(AgentInboxMessage)
        /// Hold the agent until the app decides or the item's deadline passes.
        case hold(AgentAttention)
    }

    /// `mode` is the helper's first argument: "hook" for the regular groups, "ask" for the AskUserQuestion group.
    public static func outgoing(payload: [String: Any], mode: String, context: ClaudeHookContext,
                                transcript: (String) -> String? = { ClaudeTranscript.lastAssistantText(path: $0) }) -> Outgoing? {
        // Subagents never reach the notch; their parent's own requests do.
        guard payload["agent_id"] == nil, let sessionID = payload["session_id"] as? String, ClaudeSession.validID(sessionID),
              let event = payload["hook_event_name"] as? String else { return nil }
        let toolName = (payload["tool_name"] as? String).flatMap { $0.count <= 128 ? $0 : nil }
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        // Only a terminal session can be held: the Desktop Code tab and IDEs have their own prompt UI.
        let canHold = context.flags?.holds == true && context.entrypoint == "cli"
        let deadline = canHold ? context.now.addingTimeInterval(TimeInterval(context.flags?.holdSeconds ?? AgentInbox.defaultHold)) : nil
        func item(_ kind: AttentionKind, _ title: String, _ message: String, preview: String? = nil, questions: [AttentionQuestion] = [], deadline: Date? = nil) -> AgentAttention {
            AgentAttention(source: "claude", sessionID: sessionID, kind: kind, title: title, message: message, toolName: toolName, preview: preview, questions: questions,
                           cwd: (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? $0 : nil },
                           configDirectory: context.configDirectory, tty: context.tty, pid: context.pid,
                           entrypoint: context.entrypoint.map { AgentAttention.clean($0, limit: 40) }, receivedAt: context.now, deadline: deadline)
        }
        func send(_ value: AgentAttention, notification: String? = nil) -> Outgoing { value.awaitsDecision ? .hold(value) : .post(.attention(value, notification: notification)) }
        func clear(_ includeFinished: Bool) -> Outgoing { .post(.clear(source: "claude", sessionID: sessionID, includeFinished: includeFinished)) }

        if mode == "ask" {
            guard event == "PreToolUse", toolName == "AskUserQuestion" else { return nil }
            let questions = Self.questions(toolInput)
            guard let first = questions.first else { return nil }
            return send(item(.question, "Claude has a question", first.question, questions: questions, deadline: deadline))
        }
        guard mode == "hook" else { return nil }
        switch event {
        case "PermissionRequest":
            // A question arrives through the AskUserQuestion group instead; a plan approval is shown but never answered here.
            guard let toolName, toolName != "AskUserQuestion" else { return nil }
            let summary = (toolInput["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Claude wants to use \(toolName)."
            return send(item(.permission, title(tool: toolName), summary, preview: preview(tool: toolName, input: toolInput), deadline: toolName == "ExitPlanMode" ? nil : deadline))
        case "Stop":
            let text = (payload["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (payload["transcript_path"] as? String).flatMap(transcript) ?? ""
            // A terminal or Claude Desktop session may wait briefly for a reply typed in the pop-up.
            let continued = context.replyMarkers?.consume(source: "claude", sessionID: sessionID, now: context.now) ?? false
            let wait = StopReply.deadline(flags: context.flags, entrypoint: context.entrypoint, stopHookActive: payload["stop_hook_active"] as? Bool == true,
                                          continuedByReply: continued, now: context.now)
            return send(item(.finished, "Done", text, deadline: wait))
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            let message = (payload["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch type {
            case "idle_prompt": return send(item(.waiting, "Waiting for you", message ?? "Claude is waiting for your input."))
            case "permission_prompt": return send(item(.permission, "Needs your approval", message ?? "Claude needs your permission."), notification: type)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return send(item(.waiting, "Needs your input", message ?? "Claude needs your input."), notification: type)
            default: return nil
            }
        case "UserPromptSubmit", "SessionEnd": return clear(true)
        case "PostToolUse", "PostToolUseFailure": return clear(false)
        default: return nil
        }
    }

    /// Sends the payload's message, waiting for a decision where the item allows it. Returns the JSON to print, or nil
    /// to print nothing so Claude Code shows its own dialog.
    public static func deliver(payload: [String: Any], mode: String, context: ClaudeHookContext, socket: URL) -> String? {
        switch outgoing(payload: payload, mode: mode, context: context) {
        case .post(let message)?: AgentInboxClient.post(message, socket: socket); return nil
        case .hold(let item)?:
            // A reply may be extended while the user types (up to `AgentInbox.maxReplyHold`); permission waits are fixed.
            let limit = item.kind == .finished ? StopReply.limit(receivedAt: item.receivedAt) : nil
            guard let deadline = item.deadline, let decision = AgentInboxClient.request(item, socket: socket, deadline: deadline, limit: limit) else { return nil }
            let text = output(for: decision, kind: item.kind, toolInput: payload["tool_input"] as? [String: Any])
            if item.kind == .finished, text != nil { context.replyMarkers?.mark(source: "claude", sessionID: item.sessionID) }
            return text
        case nil: return nil
        }
    }

    /// Claude Code's documented hook output for a decision (code.claude.com/docs/en/hooks: "PermissionRequest decision
    /// control", "Tools that require user interaction" and "Stop decision control"). Nil for pass-through or a decision
    /// that does not fit the request.
    public static func output(for decision: AttentionDecision, kind: AttentionKind, toolInput: [String: Any]?) -> String? {
        if kind == .finished { return StopReply.output(for: decision) }
        let body: [String: Any]
        switch (kind, decision) {
        case (.permission, .allow):
            body = ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]
        case (.permission, .deny(let message)):
            body = ["hookEventName": "PermissionRequest", "decision": ["behavior": "deny", "message": reason(message, fallback: "The user denied this from ProfileDock.")]]
        case (.question, .deny(let message)):
            body = ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason(message, fallback: "The user declined to answer from ProfileDock.")]
        case (.question, .answer(let answers)):
            // Echo the original input and add `answers`, keyed by each question's exact text.
            guard var input = toolInput, let questions = input["questions"] as? [[String: Any]], questions.count == answers.count else { return nil }
            var mapped: [String: String] = [:]
            for (question, answer) in zip(questions, answers) {
                let value = AgentAttention.clean(answer, limit: 1_000)
                guard let text = question["question"] as? String, !value.isEmpty, mapped[text] == nil else { return nil }
                mapped[text] = value
            }
            input["answers"] = mapped
            body = ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]
        default: return nil
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": body], options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func reason(_ message: String?, fallback: String) -> String {
        let text = AgentAttention.clean(message ?? "", limit: 500)
        return text.isEmpty ? fallback : text
    }

    public static func title(tool: String) -> String {
        switch tool {
        case "Bash", "PowerShell", "Monitor": return "Run a command?"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit a file?"
        case "Write": return "Write a file?"
        case "Read": return "Read a file?"
        case "WebFetch": return "Open a web page?"
        case "WebSearch": return "Search the web?"
        case "ExitPlanMode": return "Review the plan"
        default:
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "Use \(parts[2...].joined(separator: "__")) from \(parts[1])?" }
            return "Use \(tool)?"
        }
    }

    /// The part of the input a person needs to decide: the command, path, address or query, else compact JSON.
    public static func preview(tool: String, input: [String: Any]) -> String? {
        let key: String?
        switch tool {
        case "Bash", "PowerShell", "Monitor": key = "command"
        case "Edit", "MultiEdit", "Write", "Read": key = "file_path"
        case "NotebookEdit": key = "notebook_path"
        case "WebFetch": key = "url"
        case "WebSearch": key = "query"
        case "Glob", "Grep": key = "pattern"
        case "ExitPlanMode": key = "plan"
        default: key = nil
        }
        if let key, let value = input[key] as? String, !value.isEmpty { return value }
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= AgentInbox.frameLimit else { return nil }
        return String(decoding: data.prefix(2_048), as: UTF8.self)
    }

    /// AskUserQuestion's `questions`: at most 4, each with at most 8 options.
    public static func questions(_ input: [String: Any]) -> [AttentionQuestion] {
        ((input["questions"] as? [[String: Any]]) ?? []).prefix(4).compactMap { value in
            guard let text = value["question"] as? String else { return nil }
            let options = ((value["options"] as? [[String: Any]]) ?? []).compactMap { option in
                (option["label"] as? String).map { AttentionOption(label: $0, detail: option["description"] as? String) }
            }
            return AttentionQuestion(header: value["header"] as? String, question: text, options: options, multiSelect: value["multiSelect"] as? Bool ?? false).sanitized()
        }
    }
}

/// Reads the last assistant text from a Claude Code transcript (one JSON object per line). Only the file's tail is read,
/// and the text stays in memory.
public enum ClaudeTranscript {
    public static func lastAssistantText(path: String, limit: Int = 65_536) -> String? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"), path.utf8.count < 4_096 else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = UInt64(max(0, values.fileSize ?? 0)), start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: limit) else { return nil }
        return lastAssistantText(tail: data, partial: start > 0)
    }

    /// `partial`: the tail starts mid-file, so its first line may be cut and is skipped.
    public static func lastAssistantText(tail: Data, partial: Bool) -> String? {
        var lines = tail.split(separator: UInt8(ascii: "\n"))
        if partial, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true, let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            if let text = content.last(where: { $0["type"] as? String == "text" && !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?["text"] as? String {
                return text
            }
        }
        return nil
    }
}
