import Foundation

/// Shared contract for "an agent needs you" items. The hook helper (`ProfileDockClaude`) builds one from a
/// hook payload and sends it to the app over the local inbox socket; the app shows it in the notch panel
/// and, for requests that can be answered, sends an `AttentionDecision` back on the same connection.
/// Text fields are untrusted agent output: display only, never interpreted.
public enum AttentionKind: String, Codable, Sendable {
    /// A tool call waits for approval (Claude Code `PermissionRequest`). Answerable with allow or deny.
    case permission
    /// The agent asked a multiple-choice question (Claude Code `AskUserQuestion` via `PreToolUse`).
    case question
    /// The agent is waiting for the next prompt (Claude Code `Notification` idle prompt).
    case waiting
    /// A turn finished (`Stop`). Never answerable through the hook; a reply is typed into the session's terminal.
    case finished
}

public struct AttentionOption: Codable, Sendable, Hashable {
    public let label: String
    public let detail: String?
    public init(label: String, detail: String? = nil) { self.label = label; self.detail = detail }
}

/// One question with its choices, as Claude Code's `AskUserQuestion` sends them.
public struct AttentionQuestion: Codable, Sendable, Hashable {
    public let header: String?
    public let question: String
    public let options: [AttentionOption]
    public let multiSelect: Bool
    public init(header: String?, question: String, options: [AttentionOption], multiSelect: Bool) {
        self.header = header; self.question = question; self.options = options; self.multiSelect = multiSelect
    }
}

public struct AgentAttention: Codable, Sendable, Identifiable, Hashable {
    /// One-time request id. A decision is accepted only for this id, once.
    public let id: String
    /// "claude" or "codex" (more sources later).
    public let source: String
    public let sessionID: String
    public let kind: AttentionKind
    /// Short headline, e.g. "Run a command?", "Claude has a question", "Done".
    public let title: String
    /// Question text, permission summary or an excerpt of the last assistant message (at most 500 characters).
    public let message: String
    public let toolName: String?
    /// Command or path preview for a permission request (at most 300 characters).
    public let preview: String?
    public let questions: [AttentionQuestion]
    public let cwd: String?
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME` of the session, used to match a profile. Nil means the default account.
    public let configDirectory: String?
    public let tty: String?
    public let pid: Int32?
    /// Claude Code's `CLAUDE_CODE_ENTRYPOINT` (for example "cli" or "claude-desktop").
    public let entrypoint: String?
    public let receivedAt: Date
    /// When the waiting hook gives up and lets the agent's own dialog take over. Nil: nothing to decide.
    public let deadline: Date?

    public init(id: String = UUID().uuidString, source: String, sessionID: String, kind: AttentionKind, title: String, message: String,
                toolName: String? = nil, preview: String? = nil, questions: [AttentionQuestion] = [], cwd: String? = nil,
                configDirectory: String? = nil, tty: String? = nil, pid: Int32? = nil, entrypoint: String? = nil,
                receivedAt: Date = Date(), deadline: Date? = nil) {
        self.id = id; self.source = source; self.sessionID = sessionID; self.kind = kind
        self.title = AgentAttention.clean(title, limit: 80); self.message = AgentAttention.clean(message, limit: 500)
        self.toolName = toolName.map { AgentAttention.clean($0, limit: 60) }; self.preview = preview.map { AgentAttention.clean($0, limit: 300) }
        self.questions = questions; self.cwd = cwd; self.configDirectory = configDirectory; self.tty = tty; self.pid = pid
        self.entrypoint = entrypoint; self.receivedAt = receivedAt; self.deadline = deadline
    }

    /// The hook is still holding the agent and waits for a decision.
    public var awaitsDecision: Bool { deadline != nil }
    /// Folder name of the working directory, for a compact label.
    public var projectName: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }

    /// Strips control characters (except newlines and tabs), collapses runs of blank lines and truncates with an ellipsis.
    public static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        var value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("\n\n\n") { value = value.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 1))) + "…"
    }
}

/// The user's answer. `passThrough` releases the hook without a decision, so the agent shows its own dialog.
public enum AttentionDecision: Codable, Sendable, Equatable {
    case allow
    case deny(message: String?)
    /// Labels of the chosen options, one entry per question in order (multi-select answers joined with ", ").
    case answer([String])
    case passThrough
}
