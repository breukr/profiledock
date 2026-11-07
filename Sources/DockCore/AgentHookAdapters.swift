import Foundation
import Darwin

// MARK: - Process facts

/// One ancestor of the hook helper: the agent, a shell between them, or the app that started the agent.
public struct AgentProcessInfo: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let path: String?
    /// The controlling terminal, such as "/dev/ttys003", or nil for a process started by an app.
    public let tty: String?
    public init(pid: Int32, name: String, path: String?, tty: String?) { self.pid = pid; self.name = name; self.path = path; self.tty = tty }
}

/// Facts about the agent behind a hook, read from the process table (no files, no prompts).
public enum AgentProcess {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login"]

    /// The helper's ancestors, parent first, at most 16.
    public static func ancestors(from start: Int32 = getppid()) -> [AgentProcessInfo] {
        var chain: [AgentProcessInfo] = [], pid = start
        for _ in 0..<16 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { break }
            var name = [CChar](repeating: 0, count: 1024), path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            _ = proc_name(pid, &name, UInt32(name.count))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            chain.append(AgentProcessInfo(pid: pid, name: String(cString: name), path: length > 0 ? String(cString: path) : nil, tty: tty(device: info.e_tdev)))
            pid = Int32(info.pbi_ppid)
        }
        return chain
    }

    /// "/dev/ttysNNN" for a terminal device number, nil for none (NODEV) or anything that is not a terminal tab.
    static func tty(device: UInt32) -> String? {
        guard device != UInt32.max, let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        let path = "/dev/" + String(cString: name)
        return ClaudeSession.validTTY(path) ? path : nil
    }

    /// The agent process: the first ancestor with one of `names`, else the first that is not a shell.
    public static func agent(in chain: [AgentProcessInfo], names: [String] = []) -> AgentProcessInfo? {
        let wanted = Set(names.map { $0.lowercased() })
        return chain.first { wanted.contains($0.name.lowercased()) } ?? chain.first { !shells.contains($0.name.lowercased()) }
    }

    /// The bundle path of the first app among the ancestors, for example "/Applications/Codex.app", or nil.
    public static func hostApplication(in chain: [AgentProcessInfo]) -> String? {
        for process in chain {
            guard let path = process.path, let range = path.range(of: ".app/Contents/") else { continue }
            return String(path[..<range.lowerBound]) + ".app"
        }
        return nil
    }

    /// Codex's entry point: "cli" in a terminal, "codex-desktop" inside the Codex or ChatGPT app, "ide" in another app.
    public static func codexEntrypoint(agent: AgentProcessInfo?, host: String?) -> String? {
        if agent?.tty != nil { return "cli" }
        guard let host else { return nil }
        let name = URL(fileURLWithPath: host).lastPathComponent.lowercased()
        return name.hasPrefix("codex") || name.hasPrefix("chatgpt") ? "codex-desktop" : "ide"
    }
}

// MARK: - Reply through a held Stop hook

/// A finished turn can wait briefly so a reply typed in the pop-up continues the session: the held Stop hook answers
/// with the documented "keep going" output, and the reply becomes the agent's next instruction.
public enum StopReply {
    /// Entry points whose Stop hook may wait: terminal sessions and the vendors' desktop chats. IDE panels are left alone.
    public static let replyEntrypoints: Set<String> = ["cli", "claude-desktop", "codex-desktop"]

    /// The hold deadline for a finished turn, or nil to report it without waiting. While the agent is already continuing
    /// because a Stop hook blocked (`stop_hook_active`), it waits again only when that continuation was a pop-up reply,
    /// so another tool's automatic loop is never slowed down.
    public static func deadline(flags: AgentInboxFlags?, entrypoint: String?, stopHookActive: Bool, continuedByReply: Bool, now: Date) -> Date? {
        guard let flags, flags.holdsReplies, replyEntrypoints.contains(entrypoint ?? ""), !stopHookActive || continuedByReply else { return nil }
        return now.addingTimeInterval(TimeInterval(flags.replyHoldSeconds))
    }

    /// The latest a reply hold may be extended to while the user types.
    public static func limit(receivedAt: Date) -> Date { receivedAt.addingTimeInterval(TimeInterval(AgentInbox.maxReplyHold)) }

    /// The Stop output Claude Code and Codex document for continuing a turn (code.claude.com/docs/en/hooks "Stop decision
    /// control"; learn.chatgpt.com/docs/hooks "Stop"): `decision: "block"` with the reply as `reason`. Nil for anything else.
    public static func output(for decision: AttentionDecision) -> String? {
        guard case .reply(let raw) = decision else { return nil }
        let text = AgentAttention.clean(raw, limit: 8_000)
        guard !text.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": text], options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Empty marker files that remember "this session's last turn was continued by a pop-up reply", so the next Stop with
/// `stop_hook_active` may wait again. A marker is removed by the next Stop of that session and ignored after an hour.
public struct StopReplyMarkers: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public init(home: URL) { directory = AgentInbox.replyMarkers(home: home) }
    static let maxAge: TimeInterval = 3_600

    func file(_ source: String, _ sessionID: String) -> URL? {
        guard ClaudeSession.validID(sessionID), source.range(of: "^[a-z][a-z0-9-]{0,15}$", options: .regularExpression) != nil else { return nil }
        return directory.appendingPathComponent(source + "." + sessionID)
    }
    public func mark(source: String, sessionID: String) {
        guard let url = file(source, sessionID) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { return }
        try? Data().write(to: url, options: .atomic)
    }
    /// True when a fresh marker existed; the marker is removed either way.
    public func consume(source: String, sessionID: String, now: Date = Date()) -> Bool {
        guard let url = file(source, sessionID), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return false }
        try? FileManager.default.removeItem(at: url)
        return now.timeIntervalSince(values.contentModificationDate ?? .distantPast) < Self.maxAge
    }
}

// MARK: - Payloads from other agents

/// Facts about the hook process that are not in the payload.
public struct AgentHookContext: Sendable {
    public var tty: String?
    public var pid: Int32?
    public var now: Date
    public init(tty: String? = nil, pid: Int32? = nil, now: Date = Date()) { self.tty = tty; self.pid = pid; self.now = now }
}

/// Turns hook payloads from Gemini CLI, Cursor, Copilot CLI, Factory Droid, Qwen Code and OpenCode into display-only
/// attention items (`source` is the registry id). None of them is held: these agents keep their own prompts, and a reply
/// goes to the session's terminal. Payload text is untrusted and only displayed.
public enum AgentHookAdapters {
    /// The helper's second argument in `agent` mode.
    public static let agents = ["gemini", "cursor", "copilot", "droid", "qwen", "opencode"]

    public static func message(agent: String, payload: [String: Any], context: AgentHookContext) -> AgentInboxMessage? {
        guard payload["agent_id"] == nil, payload["parent_session_id"] == nil,
              let event = (payload["hook_event_name"] ?? payload["hookEventName"]) as? String else { return nil }
        let source = agent == "cursor" && context.tty != nil ? "cursor-cli" : agent
        guard agents.contains(agent), let sessionID = string(payload, "session_id", "sessionId", "conversation_id"), ClaudeSession.validID(sessionID) else { return nil }
        let roots = payload["workspace_roots"] as? [String]
        let cwd = (string(payload, "cwd") ?? roots?.first).flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? $0 : nil }
        let label = AgentRegistry.tool(id: source)?.name ?? source
        func item(_ kind: AttentionKind, _ title: String, _ message: String, tool: String? = nil, preview: String? = nil, questions: [AttentionQuestion] = [],
                  notification: String? = nil) -> AgentInboxMessage {
            .attention(AgentAttention(source: source, sessionID: sessionID, kind: kind, title: title, message: message, toolName: tool, preview: preview,
                                      questions: questions, cwd: cwd, tty: context.tty, pid: context.pid, entrypoint: context.tty != nil ? "cli" : nil,
                                      receivedAt: context.now), notification: notification)
        }
        func clear(_ includeFinished: Bool) -> AgentInboxMessage { .clear(source: source, sessionID: sessionID, includeFinished: includeFinished) }
        func notification(_ type: String, _ text: String?) -> AgentInboxMessage? {
            switch type {
            case "permission_prompt", "ToolPermission": return nil
            case "idle_prompt": return item(.waiting, "Waiting for you", text ?? "\(label) is waiting for your input.")
            case "elicitation_dialog": return item(.waiting, "Needs your input", text ?? "\(label) needs your input.")
            default: return nil
            }
        }

        switch agent {
        case "gemini":
            switch event {
            case "AfterAgent": return item(.finished, "Done", string(payload, "prompt_response") ?? "")
            case "Notification":
                guard string(payload, "notification_type") == "ToolPermission" else { return nil }
                let details = payload["details"] as? [String: Any] ?? [:]
                let tool = string(details, "tool_name", "toolName", "name")
                return item(.permission, tool.map(title(tool:)) ?? "Needs your approval", string(payload, "message") ?? "\(label) needs your permission.",
                            tool: tool, preview: preview(details), notification: "permission_prompt")
            case "BeforeAgent", "SessionEnd": return clear(true)
            case "AfterTool": return clear(false)
            default: return nil
            }
        case "cursor":
            switch event {
            case "stop":
                switch string(payload, "status") {
                case "aborted": return clear(true)
                case "error": return item(.finished, "Stopped", "\(label) stopped with an error.")
                default: return item(.finished, "Done", "")
                }
            default: return nil
            }
        case "opencode":
            switch event {
            case "session.idle": return item(.finished, "Done", "")
            case "permission.asked":
                let kind = string(payload, "permission") ?? "tool"
                let patterns = (payload["patterns"] as? [String]) ?? (payload["patterns"] as? String).map { [$0] } ?? []
                let preview = patterns.isEmpty ? nil : patterns.prefix(8).joined(separator: kind == "bash" ? " && " : "\n")
                return item(.permission, title(tool: kind), string(payload, "title") ?? "\(label) wants to use \(kind).", tool: kind, preview: preview)
            case "question.asked":
                let questions = ((payload["questions"] as? [[String: Any]]) ?? []).prefix(4).compactMap { value -> AttentionQuestion? in
                    guard let text = value["question"] as? String else { return nil }
                    let options = ((value["options"] as? [[String: Any]]) ?? []).compactMap { option in
                        (option["label"] as? String).map { AttentionOption(label: $0, detail: option["description"] as? String) }
                    }
                    return AttentionQuestion(header: value["header"] as? String, question: text, options: options, multiSelect: value["multiple"] as? Bool ?? false).sanitized()
                }
                guard let first = questions.first else { return nil }
                return item(.question, "\(label) has a question", first.question, questions: questions)
            case "permission.replied", "question.replied", "question.rejected": return clear(false)
            default: return nil
            }
        default:
            // Copilot CLI (registered with Claude-style PascalCase names), Factory Droid and Qwen Code send Claude-compatible payloads.
            switch event {
            case "Stop":
                return item(.finished, "Done", string(payload, "last_assistant_message") ?? "")
            case "Notification":
                let type = string(payload, "notification_type") ?? ""
                if type == "permission_prompt" {
                    return item(.permission, "Needs your approval", string(payload, "message") ?? "\(label) needs your permission.", notification: type)
                }
                return notification(type, string(payload, "message"))
            case "PermissionRequest":
                guard let tool = string(payload, "tool_name") else { return nil }
                let input = payload["tool_input"] as? [String: Any] ?? [:]
                return item(.permission, title(tool: tool), string(input, "description") ?? "\(label) wants to use \(tool).", tool: tool,
                            preview: preview(input) ?? ClaudeAttentionHook.preview(tool: tool, input: input))
            case "UserPromptSubmit", "SessionEnd": return clear(true)
            case "PostToolUse", "PostToolUseFailure": return clear(false)
            default: return nil
            }
        }
    }

    /// A headline for tool names across agents (Gemini and Qwen use snake_case names, OpenCode lowercase permissions).
    public static func title(tool: String) -> String {
        switch tool.lowercased() {
        case "run_shell_command", "shell", "bash", "execute", "run_terminal_cmd": return "Run a command?"
        case "write_file", "write", "create": return "Write a file?"
        case "replace", "edit", "edit_file", "apply_patch", "multiedit": return "Edit a file?"
        case "read_file", "read_many_files", "read": return "Read a file?"
        case "web_fetch", "webfetch", "fetch": return "Open a web page?"
        case "google_web_search", "web_search", "websearch": return "Search the web?"
        case "external_directory": return "Leave the project folder?"
        default: return ClaudeAttentionHook.title(tool: tool)
        }
    }

    /// The command, path, address or query in a tool's input, whatever the agent calls it.
    static func preview(_ input: [String: Any]) -> String? {
        string(input, "command", "file_path", "absolute_path", "path", "fileName", "url", "query", "pattern")
    }

    static func string(_ payload: [String: Any], _ keys: String...) -> String? {
        for key in keys { if let value = payload[key] as? String, !value.isEmpty { return value } }
        return nil
    }
}

// MARK: - Hook registrations in other agents' configuration

/// Where and how ProfileDock registers its hook for one agent. Every format keeps other tools' entries untouched.
public struct AgentHookTarget: Sendable, Equatable, Identifiable {
    public enum Format: Sendable, Equatable {
        /// `{"hooks": {Event: [{matcher?, hooks: [{type, command, timeout}]}]}}` (Claude Code's shape). `milliseconds`: Gemini.
        case groups(milliseconds: Bool)
        /// Cursor: `{"version": 1, "hooks": {event: [{command, timeout}]}}`.
        case flat
        /// A whole file that only ProfileDock writes: Copilot's hook file or OpenCode's plugin.
        case ownedFile
    }
    public struct Event: Sendable, Equatable {
        public let name: String
        public let matcher: String?
        public init(_ name: String, matcher: String? = nil) { self.name = name; self.matcher = matcher }
    }

    /// The helper's agent argument ("cursor" also serves the Cursor CLI).
    public let id: String
    /// Registry ids whose install makes this target relevant.
    public let tools: [String]
    /// Configuration files relative to the home, preferred first (Droid reads `hooks.json` when it exists, else `settings.json`).
    public let files: [String]
    public let format: Format
    public let events: [Event]
    /// Seconds (or milliseconds for Gemini) each display-only hook may take.
    public var timeout: Int { format == .groups(milliseconds: true) ? 5_000 : 5 }

    public static let gemini = AgentHookTarget(id: "gemini", tools: ["gemini"], files: [".gemini/settings.json"], format: .groups(milliseconds: true),
                                               events: ["AfterAgent", "Notification", "BeforeAgent", "AfterTool", "SessionEnd"].map { Event($0) })
    public static let cursor = AgentHookTarget(id: "cursor", tools: ["cursor", "cursor-cli"], files: [".cursor/hooks.json"], format: .flat, events: [Event("stop")])
    public static let copilot = AgentHookTarget(id: "copilot", tools: ["copilot"], files: [".copilot/hooks/profiledock.json"], format: .ownedFile,
                                                events: ["Stop", "Notification", "UserPromptSubmit", "PostToolUse"].map { Event($0) })
    public static let droid = AgentHookTarget(id: "droid", tools: ["droid"], files: [".factory/hooks.json", ".factory/settings.json"], format: .groups(milliseconds: false),
                                              events: [Event("Stop"), Event("Notification", matcher: "*"), Event("UserPromptSubmit"), Event("PostToolUse", matcher: "*"), Event("SessionEnd")])
    public static let qwen = AgentHookTarget(id: "qwen", tools: ["qwen"], files: [".qwen/settings.json"], format: .groups(milliseconds: false),
                                             events: [Event("Stop"), Event("Notification", matcher: "*"), Event("PermissionRequest", matcher: "*"), Event("UserPromptSubmit"),
                                                      Event("PostToolUse", matcher: "*"), Event("SessionEnd")])
    public static let opencode = AgentHookTarget(id: "opencode", tools: ["opencode"], files: [".config/opencode/plugins/profiledock.js"], format: .ownedFile, events: [])
    public static let all = [gemini, cursor, copilot, droid, qwen, opencode]
    public static func target(id: String) -> AgentHookTarget? { all.first { $0.id == id } }

    /// The file to edit: the first existing one, else the last (Droid falls back to `settings.json` when `hooks.json` is absent).
    public func file(home: URL) -> URL {
        let urls = files.map { home.appendingPathComponent($0) }
        return urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? urls[urls.count - 1]
    }
}

public enum AgentHookConfig {
    /// A fail-open command: if the helper is gone (ProfileDock removed), the hook does nothing and the agent carries on.
    /// Wrapped in `/bin/sh -c` so it behaves the same whether or not the agent runs hooks through a shell.
    public static func command(helper: URL, agent: String) -> String {
        "/bin/sh -c " + ClaudeBridgeSettings.shellQuote(guarded(helper: helper, arguments: "agent " + agent))
    }
    /// `[ -x helper ] && helper arguments; exit 0`, for agents that run hook commands through a shell (Codex).
    public static func guarded(helper: URL, arguments: String) -> String {
        let path = ClaudeBridgeSettings.shellQuote(helper.path)
        return "[ -x \(path) ] && \(path) \(arguments); exit 0"
    }

    /// The new file contents with ProfileDock connected or disconnected. Nil from disconnecting an owned file means
    /// "remove the file". Throws, keeping the file as it is, when the existing contents have an unexpected shape.
    /// `fileName`: Droid's `hooks.json` may hold the events at the top level instead of under "hooks".
    public static func updating(_ data: Data?, target: AgentHookTarget, helper: URL, enabled: Bool, fileName: String? = nil) throws -> Data? {
        let ours = command(helper: helper, agent: target.id)
        switch target.format {
        case .ownedFile:
            guard enabled else { return nil }
            return target.id == "opencode" ? Data(openCodePlugin(helper: helper).utf8) : try copilotFile(command: ours)
        case .groups(let milliseconds):
            var file = try object(data, name: target.id)
            let topLevel = fileName == "hooks.json" && file["hooks"] == nil && !file.isEmpty && file.keys.allSatisfy { $0.first?.isUppercase == true }
            guard topLevel || file["hooks"] == nil || file["hooks"] is [String: Any] else { throw unexpected(target) }
            var hooks = topLevel ? file : file["hooks"] as? [String: Any] ?? [:], removed = false
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { if enabled && target.events.contains(where: { $0.name == event }) { throw unexpected(target) }; continue }
                let kept = try groups.compactMap { group -> [String: Any]? in
                    guard let commands = group["hooks"] as? [[String: Any]] else { throw unexpected(target) }
                    let remaining = commands.filter { $0["command"] as? String != ours }
                    if remaining.count == commands.count { return group }
                    removed = true
                    if remaining.isEmpty { return nil }
                    var value = group; value["hooks"] = remaining; return value
                }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if enabled {
                for event in target.events {
                    var hook: [String: Any] = ["type": "command", "command": ours, "timeout": milliseconds ? 5_000 : 5]
                    if target.id == "gemini" { hook["name"] = "profiledock" }
                    var group: [String: Any] = ["hooks": [hook]]
                    if let matcher = event.matcher { group["matcher"] = matcher }
                    hooks[event.name] = (hooks[event.name] as? [[String: Any]] ?? []) + [group]
                }
            }
            // A "hooks" key that only held ProfileDock's entries goes away again on disconnect.
            if topLevel { file = hooks } else if hooks.isEmpty && removed && !enabled { file.removeValue(forKey: "hooks") } else if enabled || removed { file["hooks"] = hooks }
            return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .flat:
            var file = try object(data, name: target.id)
            guard file["hooks"] == nil || file["hooks"] is [String: Any] else { throw unexpected(target) }
            var hooks = file["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else { if enabled && target.events.contains(where: { $0.name == event }) { throw unexpected(target) }; continue }
                let kept = entries.filter { $0["command"] as? String != ours }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if enabled {
                for event in target.events { hooks[event.name] = (hooks[event.name] as? [[String: Any]] ?? []) + [["command": ours, "timeout": 5]] }
            }
            if file["version"] == nil { file["version"] = 1 }
            file["hooks"] = hooks
            return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
    }

    /// Whether `data` holds every ProfileDock entry for `target` exactly as `updating` writes them.
    public static func isConnected(_ data: Data?, target: AgentHookTarget, helper: URL, fileName: String? = nil) -> Bool {
        guard let data else { return false }
        guard let expected = try? updating(data, target: target, helper: helper, enabled: true, fileName: fileName) else { return false }
        return target.format == .ownedFile ? expected == data : sameJSON(expected, data)
    }
    /// Whether `data` contains any ProfileDock entry for `target`, for example one written by an older version.
    public static func hasEntries(_ data: Data?, target: AgentHookTarget, helper: URL, fileName: String? = nil) -> Bool {
        guard let data else { return false }
        if target.format == .ownedFile { return true }
        guard let without = try? updating(data, target: target, helper: helper, enabled: false, fileName: fileName) else { return false }
        return !sameJSON(without, data)
    }
    public static func sameJSON(_ a: Data?, _ b: Data) -> Bool {
        guard let a, let left = try? JSONSerialization.jsonObject(with: a) as? NSDictionary, let right = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
        return left == right
    }

    static func copilotFile(command: String) throws -> Data {
        // Claude-style PascalCase names make Copilot CLI send snake_case, Claude-compatible payloads.
        let hooks = Dictionary(uniqueKeysWithValues: AgentHookTarget.copilot.events.map { event in
            (event.name, [["type": "command", "bash": command, "command": command, "timeoutSec": 5] as [String: Any]])
        })
        return try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// OpenCode plugin (a JavaScript module in `~/.config/opencode/plugins/`) that forwards session.idle, permission and
    /// question events to the helper. It runs the helper only when it exists, and never waits for it.
    public static func openCodePlugin(helper: URL) -> String {
        let path = String(decoding: (try? JSONSerialization.data(withJSONObject: [helper.path], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        return """
        // ProfileDock: shows OpenCode sessions in the Mac's notch when they finish or ask for permission.
        // Written by ProfileDock (profiledock-opencode-plugin 1). Disconnect in ProfileDock Settings, or delete this file.
        import { spawn } from "node:child_process";
        import { existsSync } from "node:fs";

        const [HELPER] = \(path);

        export const ProfileDock = async ({ client, directory }) => {
          const send = (payload) => {
            if (!existsSync(HELPER)) return;
            try {
              const child = spawn(HELPER, ["agent", "opencode"], { stdio: ["pipe", "ignore", "ignore"] });
              child.on("error", () => {});
              child.stdin.on("error", () => {});
              child.stdin.end(JSON.stringify({ cwd: directory, ...payload }));
            } catch {}
          };
          const isSubagent = async (id) => {
            try { return Boolean((await client.session.get({ path: { id } }))?.data?.parentID); } catch { return false; }
          };
          return {
            event: async ({ event }) => {
              const type = event?.type, p = event?.properties ?? {};
              if (!p.sessionID) return;
              if (type === "session.idle") {
                if (!(await isSubagent(p.sessionID))) send({ hook_event_name: type, session_id: p.sessionID });
              } else if (type === "permission.asked" || type === "permission.updated") {
                send({ hook_event_name: "permission.asked", session_id: p.sessionID, permission: p.permission ?? p.type,
                       patterns: [].concat(p.patterns ?? p.pattern ?? []), title: p.title });
              } else if (type === "question.asked") {
                send({ hook_event_name: type, session_id: p.sessionID, questions: p.questions ?? [] });
              } else if (type === "permission.replied" || type === "question.replied" || type === "question.rejected") {
                send({ hook_event_name: type, session_id: p.sessionID });
              }
            },
          };
        };

        """
    }

    static func object(_ data: Data?, name: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompanionError.message("The \(name) settings are not a JSON object ProfileDock can edit. They were kept as they are.")
        }
        return value
    }
    static func unexpected(_ target: AgentHookTarget) -> Error {
        CompanionError.message("The \(AgentRegistry.tool(id: target.id)?.name ?? target.id) hooks have an unexpected format. Existing hooks were kept.")
    }
}
