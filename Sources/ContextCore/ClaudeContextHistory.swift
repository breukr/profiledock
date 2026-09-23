import Foundation
import DockCore

extension ContextHistory {
    func claudeThreads(since: Double?, threadID: String?) throws -> ([ContextThread], Bool) {
        let files = try ClaudeHistory.files(home: root.deletingLastPathComponent(), since: since.map(Date.init(timeIntervalSince1970:)))
        var threads: [ContextThread] = [], limited = files.count >= 5000
        for file in files {
            guard Date() < deadline else { limited = true; break }
            let id = file.deletingPathExtension().lastPathComponent
            if let threadID, threadID != id { continue }
            var found = false, title: String?
            let metadataLimited = try ClaudeHistory.records(file: file, maximumBytes: 1024 * 1024, deadline: deadline) { record, _ in
                guard ClaudeHistory.belongs(record, project: claudeProject), ["user", "assistant"].contains(record["type"] as? String ?? "") else { return true }
                found = true
                if record["isMeta"] as? Bool != true, let message = record["message"] as? [String: Any],
                   message["role"] as? String == "user", let text = ContextText.message(message, id: "", timestamp: 0, ordinal: 0)?.text { title = String(text.prefix(120)) }
                return title == nil
            }
            if metadataLimited && !found { limited = true }
            if found {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                threads.append(ContextThread(id: id, title: title ?? "Claude Code session", updatedAt: date.timeIntervalSince1970, archived: false, rollout: file.path, historyMode: "claude"))
            }
            if threads.count >= Self.maximumThreads { limited = true; break }
        }
        return (threads, limited)
    }
    func claudeMessages(thread: ContextThread, after: Int64, limit: Int) throws -> HistoryRead {
        let file = URL(fileURLWithPath: thread.rollout).standardizedFileURL
        guard file.path.hasPrefix(root.appendingPathComponent("projects").path + "/"), file.pathExtension == "jsonl" else { throw ContextError.message("Claude conversation is outside its history folder.") }
        var result = HistoryRead(), seen = Set<String>(), count = 0
        result.limited = try ClaudeHistory.records(file: file, after: after, deadline: deadline) { record, position in
            count += 1
            if result.messages.count >= limit || count > Self.maximumItems { return false }
            result.nextCursor = position
            guard ClaudeHistory.belongs(record, project: claudeProject), record["isMeta"] as? Bool != true,
                  ["user", "assistant"].contains(record["type"] as? String ?? ""),
                  let raw = record["message"] as? [String: Any] else { return true }
            let id = record["uuid"] as? String ?? "byte-\(position)"
            let date = ClaudeHistory.timestamp(record["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
            if let message = ContextText.message(raw, id: id, timestamp: date, ordinal: position), seen.insert(id).inserted { result.messages.append(message) }
            return true
        }
        if !result.limited { result.nextCursor = nil }
        return result
    }
}
