import Foundation

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
    public mutating func apply(_ payload: [String: Any], statusline: Bool, now: Date) {
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
        case "SessionStart": state = .idle; completedAt = nil
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": state = .working
        case "PermissionRequest": state = .waiting
        case "Notification":
            if ["permission_prompt", "elicitation_dialog", "idle_prompt"].contains(payload["notification_type"] as? String ?? "") { state = .waiting }
        case "Stop": state = .idle; completedAt = now
        case "StopFailure": state = .failed
        case "SessionEnd": state = .closed
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
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func command(helper: URL, mode: String) -> String { shellQuote(helper.path) + " " + mode }
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
