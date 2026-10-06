import Foundation
import CryptoKit

public enum TerminalAgent: String, Codable, Sendable {
    case claude, codex
    public var label: String { self == .claude ? "Claude Code" : "Codex" }
    public var bundleIdentifier: String { self == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex" }
    /// Only foreground CLI executables count, never window titles, arguments or idle shells.
    public static func processes(_ table: String) -> [String: TerminalAgent] {
        var result: [String: TerminalAgent] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, fields[1].contains("+"), !fields[1].contains("T"), !fields[1].contains("Z") else { continue }
            let tty = "/dev/" + fields[0]
            guard ClaudeSession.validTTY(tty) else { continue }
            let executable = URL(fileURLWithPath: String(fields[2]).trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            guard let agent = TerminalAgent(rawValue: executable) else { continue }
            result[tty] = agent
        }
        return result
    }
}

public enum ProfileProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude, terminal, claudeCode
    public var label: String {
        switch self {
        case .codex: return "ChatGPT / Codex"
        case .claude: return "Claude Desktop"
        case .terminal: return "Terminal"
        case .claudeCode: return "Claude Code in Terminal"
        }
    }
    public var bundleIdentifier: String {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .terminal, .claudeCode: return "com.apple.Terminal"
        }
    }
    public var usesTerminal: Bool { self == .terminal || self == .claudeCode }
}

public enum ProfileOrder {
    /// Move by identity, preserving every other entry and ignoring stale drop targets.
    public static func move(_ profiles: [Profile], id: String, to target: String) -> [Profile] {
        guard id != target, let from = profiles.firstIndex(where: { $0.id == id }),
              let to = profiles.firstIndex(where: { $0.id == target }) else { return profiles }
        var result = profiles
        result.insert(result.remove(at: from), at: to)
        return result
    }
}

public enum CompanionError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Only session metadata is persisted. Prompts, tool inputs, messages and credentials are discarded.
public struct ClaudeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var tty: String?
    public var processID: Int32?
    public var processStarted: Double?
    public var state: State = .idle
    public var updatedAt: Date
    public var completedAt: Date?
    public var limits: [Limit] = []
    public var usageAt: Date?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    /// CLAUDE_CONFIG_DIR of the reporting session. Nil is the shared ~/.claude configuration.
    public var configDirectory: String?
    /// Subagents between SubagentStart and SubagentStop, keyed by agent ID. Only IDs and start times are kept.
    public var subagents: [String: Date]?
    public enum State: String, Codable, Sendable { case idle, working, waiting, closed, failed }
    public struct Limit: Codable, Equatable, Sendable {
        public let id: String
        public let used: Double
        public let resetsAt: Date
        public let duration: Double
        public init(id: String, used: Double, resetsAt: Date, duration: Double) {
            self.id = id; self.used = used; self.resetsAt = resetsAt; self.duration = duration
        }
    }
    public init(id: String, project: String, tty: String? = nil, processID: Int32? = nil, processStarted: Double? = nil, now: Date = Date()) {
        self.id = id; self.project = project; self.tty = tty; self.processID = processID
        self.processStarted = processStarted; updatedAt = now
    }
    public static func validID(_ value: String) -> Bool {
        value.count <= 128 && Profile.validID(value)
    }
    public static func validTTY(_ value: String) -> Bool {
        value.range(of: "^/dev/ttys[0-9]{3,}$", options: .regularExpression) != nil
    }
    /// A subagent that never reports a stop (crash, interrupt) stops counting after this long.
    public static let subagentStaleAfter: TimeInterval = 6 * 3600
    private static let subagentLimit = 64

    /// Session-level hooks carry no `agent_id`. Only the two subagent lifecycle events are kept from subagents,
    /// so their tool calls and prompts never reach ProfileDock.
    public static func isSessionPayload(_ payload: [String: Any]) -> Bool {
        payload["agent_id"] == nil || subagentEvent(payload) != nil
    }
    private static func subagentEvent(_ payload: [String: Any]) -> (id: String, starting: Bool)? {
        guard let name = payload["hook_event_name"] as? String, name == "SubagentStart" || name == "SubagentStop",
              let id = payload["agent_id"] as? String, validID(id) else { return nil }
        return (id, name == "SubagentStart")
    }
    public func runningSubagents(now: Date = Date()) -> Int {
        (subagents ?? [:]).values.filter { now.timeIntervalSince($0) < Self.subagentStaleAfter }.count
    }

    public mutating func apply(_ payload: [String: Any], statusline: Bool, now: Date) {
        if !statusline, let event = Self.subagentEvent(payload) {
            // Subagent events only maintain the running count. They never change the session's own state.
            var running = (subagents ?? [:]).filter { now.timeIntervalSince($0.value) < Self.subagentStaleAfter }
            if event.starting, running.count < Self.subagentLimit || running[event.id] != nil { running[event.id] = now }
            else if !event.starting { running.removeValue(forKey: event.id) }
            subagents = running.isEmpty ? nil : running
            updatedAt = now
            return
        }
        guard payload["agent_id"] == nil else { return }
        updatedAt = now
        if statusline {
            // Absence means unavailable, never a zero or an unlimited subscription.
            let raw = payload["rate_limits"] as? [String: Any] ?? [:]
            limits = [("seven_day", 604800.0), ("five_hour", 18000.0)].compactMap { key, duration in
                guard let value = raw[key] as? [String: Any], let used = value["used_percentage"] as? Double,
                      used.isFinite, used >= 0, let reset = value["resets_at"] as? Double,
                      reset.isFinite, reset > now.timeIntervalSince1970 else { return nil }
                return Limit(id: key, used: used, resetsAt: Date(timeIntervalSince1970: reset), duration: duration)
            }
            usageAt = now
            let context = payload["context_window"] as? [String: Any]
            inputTokens = (context?["total_input_tokens"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            outputTokens = (context?["total_output_tokens"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            costUSD = ((payload["cost"] as? [String: Any])?["total_cost_usd"] as? Double).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return
        }
        switch payload["hook_event_name"] as? String {
        case "SessionStart": state = .idle; completedAt = nil; subagents = nil
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": state = .working
        case "PermissionRequest": state = .waiting
        case "Notification":
            if ["permission_prompt", "elicitation_dialog", "idle_prompt"].contains(payload["notification_type"] as? String ?? "") { state = .waiting }
        case "Stop": state = .idle; completedAt = now
        case "StopFailure": state = .failed
        case "SessionEnd": state = .closed; subagents = nil
        default: break
        }
    }
    public func snapshot(identity: String, now: Date) -> UsageSnapshot? {
        guard let usageAt else { return nil }
        let windows = limits.filter { $0.resetsAt > now }.map {
            UsageWindow(id: $0.id, duration: $0.duration, usedPercent: $0.used, resetsAt: $0.resetsAt)
        }
        return UsageSnapshot(identity: identity, plan: nil, windows: windows, bankedResets: nil, applicableResets: nil, resetExpiries: nil, fetchedAt: usageAt)
    }
}

public enum ClaudeBridgeSettings {
    public static let coreEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]
    /// Added after the first release. A connection without them still works, it just cannot see subagents.
    public static let subagentEvents = ["SubagentStart", "SubagentStop"]
    public static let events = coreEvents + subagentEvents
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func command(helper: URL, mode: String) -> String { shellQuote(helper.path) + " " + mode }
    /// Each configuration keeps its own wrapped status line, so one account never runs another's command.
    public static func originalStatuslineName(configDirectory: String?) -> String {
        guard let configDirectory else { return "original-statusline.json" }
        let digest = SHA256.hash(data: Data(configDirectory.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "original-statusline-\(digest).json"
    }
    /// Only an absolute, non-default CLAUDE_CONFIG_DIR identifies a separate account.
    public static func configDirectory(environment: [String: String], home: URL) -> String? {
        guard let raw = environment["CLAUDE_CONFIG_DIR"], raw.hasPrefix("/"), raw.utf8.count < 4096 else { return nil }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        return path == home.appendingPathComponent(".claude").standardizedFileURL.path ? nil : path
    }
    public static func isOurs(_ hook: [String: Any], helper: URL) -> Bool {
        hook["type"] as? String == "command" && hook["command"] as? String == command(helper: helper, mode: "hook")
    }
    public static func updating(_ data: Data?, helper: URL, enabled: Bool) throws -> Data {
        var settings = try data.map { data -> [String: Any] in
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionError.message("Claude settings must be a JSON object.") }
            return value
        } ?? [:]
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { throw CompanionError.message("Claude hooks have an unexpected format. Existing settings were kept.") }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw CompanionError.message("The \(event) hooks have an unexpected format. Existing settings were kept.") }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = try groups.compactMap { group in
                guard let commands = group["hooks"] as? [[String: Any]] else { throw CompanionError.message("A Claude hook has an unexpected format. Existing settings were kept.") }
                let remaining = commands.filter { !isOurs($0, helper: helper) }
                if remaining.count == commands.count { return group }
                if remaining.isEmpty { return nil }
                var value = group; value["hooks"] = remaining; return value
            }
            if enabled { groups.append(["hooks": [["type": "command", "command": command(helper: helper, mode: "hook"), "timeout": 5]]]) }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        settings["hooks"] = hooks
        // An existing status line is never replaced. Usage remains optional.
        let usage = command(helper: helper, mode: "statusline")
        if enabled && settings["statusLine"] == nil { settings["statusLine"] = ["type": "command", "command": usage] }
        if !enabled, (settings["statusLine"] as? [String: Any])?["command"] as? String == usage { settings.removeValue(forKey: "statusLine") }
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}
