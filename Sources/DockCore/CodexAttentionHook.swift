import Foundation

/// ProfileDock's entries in Codex's `<CODEX_HOME>/hooks.json` (learn.chatgpt.com/docs/hooks). Connecting stays an
/// explicit user action, and Codex asks the user to review and trust new or changed hooks in `/hooks` before they run.
public enum CodexBridgeSettings {
    public static let events = ["PermissionRequest", "Stop"]
    /// Fail-open: a missing helper (ProfileDock removed) does nothing instead of failing every turn.
    public static func command(helper: URL) -> String { AgentHookConfig.guarded(helper: helper, arguments: "codex") }
    /// The plain command an earlier version wrote, still recognized so it can be replaced or removed.
    static func legacyCommand(helper: URL) -> String { ClaudeBridgeSettings.command(helper: helper, mode: "codex") }
    public static func isOurs(_ hook: [String: Any], helper: URL) -> Bool {
        guard hook["type"] as? String == "command", let value = hook["command"] as? String else { return false }
        return value == command(helper: helper) || value == legacyCommand(helper: helper)
    }
    /// Only the Stop group may wait (for a reply typed in the pop-up, extendable to `AgentInbox.maxReplyHold`);
    /// permission requests are reported and return at once.
    public static func timeout(for event: String) -> Int { event == "Stop" ? AgentInbox.replyTimeout : 5 }
    /// Whether the file holds ProfileDock's current groups (false for none, or for an older version's entries).
    public static func isConnected(_ data: Data?, helper: URL) -> Bool {
        guard let data, let expected = try? updating(data, helper: helper, enabled: true) else { return false }
        return AgentHookConfig.sameJSON(expected, data)
    }
    public static func hasEntries(_ data: Data?, helper: URL) -> Bool {
        guard let data, let without = try? updating(data, helper: helper, enabled: false) else { return false }
        return !AgentHookConfig.sameJSON(without, data)
    }
    /// Adds or removes ProfileDock's groups and keeps everything else, including other tools' hooks and `description`.
    public static func updating(_ data: Data?, helper: URL, enabled: Bool) throws -> Data {
        var file = try data.map { data -> [String: Any] in
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionError.message("Codex hooks must be a JSON object.") }
            return value
        } ?? [:]
        guard file["hooks"] == nil || file["hooks"] is [String: Any] else { throw CompanionError.message("Codex hooks have an unexpected format. Existing hooks were kept.") }
        var hooks = file["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw CompanionError.message("The Codex \(event) hooks have an unexpected format. Existing hooks were kept.") }
            var groups = try (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                guard let commands = group["hooks"] as? [[String: Any]] else { throw CompanionError.message("A Codex hook has an unexpected format. Existing hooks were kept.") }
                let remaining = commands.filter { !isOurs($0, helper: helper) }
                if remaining.count == commands.count { return group }
                if remaining.isEmpty { return nil }
                var value = group; value["hooks"] = remaining; return value
            }
            if enabled { groups.append(["hooks": [["type": "command", "command": command(helper: helper), "timeout": timeout(for: event)]]]) }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        file["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }
    /// Writes `<codexHome>/hooks.json`. A linked file is refused, and a missing file is not created just to disconnect.
    public static func apply(codexHome: URL, helper: URL, enabled: Bool) throws {
        let fm = FileManager.default, url = codexHome.appendingPathComponent("hooks.json")
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw CompanionError.message("Codex hooks cannot be changed through a linked file.") }
        let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard enabled || original != nil else { return }
        let changed = try updating(original, helper: helper, enabled: enabled)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Compare immediately before writing, so a concurrent edit is not silently overwritten.
        guard (fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil) == original else { throw CompanionError.message("Codex hooks changed during setup. Try again to keep those changes.") }
        try changed.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Facts about a Codex hook process.
public struct CodexHookContext: Sendable {
    public var codexHome: String?
    public var tty: String?
    public var pid: Int32?
    /// "cli", "codex-desktop" or "ide" (`AgentProcess.codexEntrypoint`); Codex itself sends no entry point.
    public var entrypoint: String?
    public var flags: AgentInboxFlags?
    public var replyMarkers: StopReplyMarkers?
    public var now: Date
    public init(codexHome: String? = nil, tty: String? = nil, pid: Int32? = nil, entrypoint: String? = nil, flags: AgentInboxFlags? = nil,
                replyMarkers: StopReplyMarkers? = nil, now: Date = Date()) {
        self.codexHome = codexHome; self.tty = tty; self.pid = pid; self.entrypoint = entrypoint; self.flags = flags; self.replyMarkers = replyMarkers; self.now = now
    }
}

/// Codex hook payloads as attention items. Permission requests are display-only; a finished turn in a terminal or the
/// Codex app may wait briefly for a reply typed in the pop-up (`StopReply`).
public enum CodexAttentionHook {
    public static func message(payload: [String: Any], codexHome: String?, now: Date = Date()) -> AgentInboxMessage? {
        switch outgoing(payload: payload, context: CodexHookContext(codexHome: codexHome, now: now)) {
        case .post(let message)?: return message
        case .hold(let item)?: return .attention(item, notification: nil)
        case nil: return nil
        }
    }

    public static func outgoing(payload: [String: Any], context: CodexHookContext) -> ClaudeAttentionHook.Outgoing? {
        guard payload["agent_id"] == nil, let sessionID = payload["session_id"] as? String, ClaudeSession.validID(sessionID),
              let event = payload["hook_event_name"] as? String else { return nil }
        let cwd = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? $0 : nil }
        let home = context.codexHome.flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
        func item(_ kind: AttentionKind, _ title: String, _ message: String, tool: String? = nil, preview: String? = nil, deadline: Date? = nil) -> AgentAttention {
            AgentAttention(source: "codex", sessionID: sessionID, kind: kind, title: title, message: message, toolName: tool, preview: preview,
                           cwd: cwd, configDirectory: home, tty: context.tty, pid: context.pid, entrypoint: context.entrypoint, receivedAt: context.now, deadline: deadline)
        }
        switch event {
        case "PermissionRequest":
            guard let tool = (payload["tool_name"] as? String).flatMap({ $0.count <= 128 ? $0 : nil }) else { return nil }
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let title = tool == "apply_patch" ? "Edit files?" : ClaudeAttentionHook.title(tool: tool)
            let preview = (input["command"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeAttentionHook.preview(tool: tool, input: input)
            let summary = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Codex wants to use \(tool)."
            return .post(.attention(item(.permission, title, summary, tool: tool, preview: preview), notification: nil))
        case "Stop":
            let continued = context.replyMarkers?.consume(source: "codex", sessionID: sessionID, now: context.now) ?? false
            let wait = StopReply.deadline(flags: context.flags, entrypoint: context.entrypoint, stopHookActive: payload["stop_hook_active"] as? Bool == true,
                                          continuedByReply: continued, now: context.now)
            let done = item(.finished, "Done", (payload["last_assistant_message"] as? String) ?? "", deadline: wait)
            return done.awaitsDecision ? .hold(done) : .post(.attention(done, notification: nil))
        default: return nil
        }
    }

    /// Reports the payload, waiting for a reply where allowed. Returns Codex's Stop output to print, or nil to print nothing.
    public static func deliver(payload: [String: Any], context: CodexHookContext, socket: URL) -> String? {
        switch outgoing(payload: payload, context: context) {
        case .post(let message)?: AgentInboxClient.post(message, socket: socket); return nil
        case .hold(let item)?:
            guard let deadline = item.deadline,
                  let decision = AgentInboxClient.request(item, socket: socket, deadline: deadline, limit: StopReply.limit(receivedAt: item.receivedAt)),
                  let text = StopReply.output(for: decision) else { return nil }
            context.replyMarkers?.mark(source: "codex", sessionID: item.sessionID)
            return text
        case nil: return nil
        }
    }
}
