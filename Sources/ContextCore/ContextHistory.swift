import Foundation
import DockCore

public struct ContextMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Double
    public let ordinal: Int64
    public let truncated: Bool
}

public struct ContextThread: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: Double
    public let archived: Bool
    let rollout: String
    let historyMode: String
    private enum CodingKeys: String, CodingKey { case id, title, updatedAt, archived }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt); archived = try c.decode(Bool.self, forKey: .archived)
        rollout = ""; historyMode = ""
    }
    init(id: String, title: String, updatedAt: Double, archived: Bool, rollout: String, historyMode: String) {
        self.id = id; self.title = title; self.updatedAt = updatedAt; self.archived = archived; self.rollout = rollout; self.historyMode = historyMode
    }
}

struct HistoryRead {
    var messages: [ContextMessage] = []
    var limited = false
    var nextCursor: Int64?
}

final class ContextHistory {
    let root: URL
    let deadline: Date
    private var historyDatabase: ContextDatabase?
    let claude: Bool
    let claudeProject: String?
    init(root: URL, deadline: Date, claude: Bool = false, project: String? = nil) { self.root = root; self.deadline = deadline; self.claude = claude; self.claudeProject = project }
    static let maximumThreads = 500
    static let maximumItems = 4000
    static let maximumBytes = 24 * 1024 * 1024

    func threads(since: Double?, includeArchived: Bool, threadID: String? = nil) throws -> ([ContextThread], Bool) {
        if claude { return try claudeThreads(since: since, threadID: threadID) }
        let db = try ContextDatabase(root.appendingPathComponent("state_5.sqlite"), deadline: deadline)
        let columns = try db.columns("threads")
        guard Set(["id", "title", "updated_at", "archived", "source", "rollout_path"]).isSubset(of: columns) else { throw ContextError.message("Unsupported conversation catalog. Update ProfileDock.") }
        var predicates = ["source IN ('vscode','cli','unknown')"]
        var bindings: [String] = []
        if columns.contains("agent_path") { predicates.append("(agent_path IS NULL OR agent_path = '/root')") }
        if columns.contains("thread_source") { predicates.append("(thread_source IS NULL OR thread_source NOT IN ('automation','memory','review','subagent'))") }
        if !includeArchived { predicates.append("archived = 0") }
        if let since { predicates.append("updated_at >= ?"); bindings.append(String(Int64(since))) }
        if let threadID { predicates.append("id = ?"); bindings.append(threadID) }
        let name = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title"
        let mode = columns.contains("history_mode") ? "history_mode" : "'legacy'"
        var result: [ContextThread] = []
        try db.rows("SELECT id,\(name),updated_at,archived,rollout_path,\(mode) FROM threads WHERE \(predicates.joined(separator: " AND ")) ORDER BY updated_at DESC,id LIMIT \(Self.maximumThreads + 1)", bindings: bindings) { row in
            result.append(ContextThread(id: row.string(0), title: String(ContextText.redact(row.string(1)).prefix(200)), updatedAt: Double(row.integer(2)), archived: row.integer(3) != 0, rollout: row.string(4), historyMode: row.string(5)))
        }
        return (Array(result.prefix(Self.maximumThreads)), result.count > Self.maximumThreads)
    }

    func messages(thread: ContextThread, after: Int64 = -1, limit: Int = maximumItems) throws -> HistoryRead {
        if claude { return try claudeMessages(thread: thread, after: after, limit: limit) }
        switch thread.historyMode {
        case "paginated": return try paginated(thread: thread, after: after, limit: limit)
        case "legacy": return try legacy(thread: thread, after: after, limit: limit)
        default: throw ContextError.message("This conversation uses a newer history format. Update ProfileDock.")
        }
    }

    private func paginated(thread: ContextThread, after: Int64, limit: Int) throws -> HistoryRead {
        if historyDatabase == nil { historyDatabase = try ContextDatabase(root.appendingPathComponent("thread_history_1.sqlite"), deadline: deadline) }
        guard let db = historyDatabase else { throw ContextError.message("Local history is unavailable.") }
        var result = HistoryRead(), bytes = 0, seen = Set<String>()
        // SQL only selects visible conversation records. Reasoning and tool payloads never leave storage.
        let sql = "SELECT item_id,item_json,created_at_ms,rollout_ordinal FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage') AND rollout_ordinal > ? ORDER BY rollout_ordinal LIMIT \(Self.maximumItems + 1)"
        var visited = 0
        try db.rows(sql, bindings: [thread.id, String(after)]) { row in
            guard !result.limited else { return }
            visited += 1
            let raw = row.string(1); bytes += raw.utf8.count
            guard visited <= Self.maximumItems, bytes <= Self.maximumBytes, result.messages.count < limit else { result.limited = true; return }
            let ordinal = row.integer(3)
            guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContextError.message("A conversation record could not be decoded.") }
            result.nextCursor = ordinal
            guard let message = ContextText.message(object, id: row.string(0), timestamp: Double(row.integer(2)) / 1000, ordinal: ordinal), seen.insert(message.id).inserted else { return }
            result.messages.append(message)
        }
        if !result.limited { result.nextCursor = nil }
        return result
    }

    private func legacy(thread: ContextThread, after: Int64, limit: Int) throws -> HistoryRead {
        let url = URL(fileURLWithPath: thread.rollout).resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.path.hasPrefix(base), url.pathExtension == "jsonl" else { throw ContextError.message("The conversation file is outside its source profile.") }
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        var result = HistoryRead(), pending = Data(), position: Int64 = max(0, after), total = 0, seen = Set<String>()
        if after > 0 { try stream.seek(toOffset: UInt64(after)) }
        outer: while true {
            guard Date() < deadline else { throw ContextError.message("Search time limit reached. Narrow the date range.") }
            guard let chunk = try stream.read(upToCount: 65536), !chunk.isEmpty else { break }
            total += chunk.count
            guard total <= Self.maximumBytes else { result.limited = true; break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let raw = Data(pending[..<newline]); let count = pending.distance(from: pending.startIndex, to: newline) + 1
                pending.removeFirst(count); position += Int64(count)
                guard result.messages.count < limit else { result.limited = true; break outer }
                result.nextCursor = position
                guard let record = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let payload = record["payload"] as? [String: Any] else { throw ContextError.message("A conversation record could not be decoded.") }
                guard record["type"] as? String == "response_item", payload["type"] as? String == "message" else { continue }
                let timestamp = ContextText.timestamp(record["timestamp"] as? String ?? "")
                guard let message = ContextText.message(payload, id: "byte-\(position)", timestamp: timestamp, ordinal: position) else { continue }
                // Suppress duplicated event/response representations without collapsing later messages.
                let key = "\(message.timestamp)|\(message.role)|\(message.text)"
                if seen.insert(key).inserted { result.messages.append(message) }
            }
        }
        // A partial trailing JSON line is an in-progress write, not a valid record.
        if !pending.isEmpty { result.limited = true }
        if !result.limited { result.nextCursor = nil }
        return result
    }
}

enum ContextText {
    static func timestamp(_ value: String) -> Double {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)?.timeIntervalSince1970 ?? 0
    }
    static func message(_ object: [String: Any], id: String, timestamp: Double, ordinal: Int64) -> ContextMessage? {
        let type = object["type"] as? String
        let role = type == "userMessage" ? "user" : type == "agentMessage" ? "assistant" : object["role"] as? String
        guard role == "user" || role == "assistant" else { return nil }
        let phase = object["phase"] as? String ?? object["channel"] as? String
        if role == "assistant", let phase, !["final", "final_answer", "commentary"].contains(phase) { return nil }
        let raw: String
        if let text = object["text"] as? String { raw = text }
        else if let text = object["content"] as? String { raw = text }
        else { raw = (object["content"] as? [[String: Any]] ?? []).filter { ["text", "input_text", "output_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }
        return ContextMessage(id: id, role: role!, text: String(cleaned.prefix(12000)), timestamp: timestamp, ordinal: ordinal, truncated: cleaned.count > 12000)
    }
    static func clean(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["in-app-browser-context", "oai-mem-citation"] {
            text = text.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let injected = ["# AGENTS.md", "<environment_context>", "<permissions", "<recommended_plugins>", "<system", "<developer", "You are Codex", "You are an AI", "<INSTRUCTIONS>", "[Automated", "<collaboration_mode>", "<local-command", "<command-name>", "<system-reminder>", "<task-notification>"]
        if injected.contains(where: { text.hasPrefix($0) }) { return "" }
        return redact(text)
    }
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in [#"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#, #"(?i)Bearer\s+[A-Za-z0-9._~+/-]{16,}"#] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED CREDENTIAL]", options: .regularExpression)
        }
        return result
    }
}
