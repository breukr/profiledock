import Foundation

/// ProfileDock's entries in Codex's `<CODEX_HOME>/hooks.json` (learn.chatgpt.com/docs/hooks). Nothing calls this yet:
/// connecting stays an explicit user action, and Codex additionally asks the user to review and trust new hooks in `/hooks`.
public enum CodexBridgeSettings {
    public static let events = ["PermissionRequest", "Stop"]
    public static func command(helper: URL) -> String { ClaudeBridgeSettings.command(helper: helper, mode: "codex") }
    public static func isOurs(_ hook: [String: Any], helper: URL) -> Bool {
        hook["type"] as? String == "command" && hook["command"] as? String == command(helper: helper)
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
            // Codex items are display-only for now, so both hooks return at once.
            if enabled { groups.append(["hooks": [["type": "command", "command": command(helper: helper), "timeout": 5]]]) }
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

/// Codex hook payloads as display-only attention items. Codex sends no entry point, so a terminal session cannot be told
/// apart from the desktop app and nothing is held.
public enum CodexAttentionHook {
    public static func message(payload: [String: Any], codexHome: String?, now: Date = Date()) -> AgentInboxMessage? {
        guard payload["agent_id"] == nil, let sessionID = payload["session_id"] as? String, ClaudeSession.validID(sessionID),
              let event = payload["hook_event_name"] as? String else { return nil }
        let cwd = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? $0 : nil }
        let home = codexHome.flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
        func item(_ kind: AttentionKind, _ title: String, _ message: String, tool: String? = nil, preview: String? = nil) -> AgentInboxMessage {
            .attention(AgentAttention(source: "codex", sessionID: sessionID, kind: kind, title: title, message: message, toolName: tool, preview: preview,
                                      cwd: cwd, configDirectory: home, receivedAt: now), notification: nil)
        }
        switch event {
        case "PermissionRequest":
            guard let tool = (payload["tool_name"] as? String).flatMap({ $0.count <= 128 ? $0 : nil }) else { return nil }
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let title = tool == "apply_patch" ? "Edit files?" : ClaudeAttentionHook.title(tool: tool)
            let preview = (input["command"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeAttentionHook.preview(tool: tool, input: input)
            let summary = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Codex wants to use \(tool)."
            return item(.permission, title, summary, tool: tool, preview: preview)
        case "Stop":
            return item(.finished, "Done", (payload["last_assistant_message"] as? String) ?? "")
        default: return nil
        }
    }
}
