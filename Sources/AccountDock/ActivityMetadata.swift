import Foundation
import CryptoKit
import SQLite3
import DockCore

enum ActivityReadError: Error { case unavailable, identity, database(Int32) }

struct ActivityIdentity: Equatable {
    let credentialKey: String
    let unreadKey: String
    static let localHostKey = "local:" + digest(["local", "local", NSNull()])

    static func read(profile: Profile, home: URL) throws -> ActivityIdentity {
        let credential = try UsageCredentials.read(profile: profile, home: home)
        return try parse(credential: credential)
    }
    static func parse(credential: UsageCredentials) throws -> ActivityIdentity {
        let parts = credential.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ActivityReadError.identity }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body), let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = (auth["chatgpt_account_id"] ?? auth["account_id"]) as? String,
              account == credential.accountID,
              let user = (auth["user_id"] ?? auth["chatgpt_user_id"]) as? String, !user.isEmpty else { throw ActivityReadError.identity }
        return ActivityIdentity(credentialKey: credential.identity, unreadKey: digest(["chatgpt", account, user]))
    }
    private static func digest(_ values: [Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ActivityMetadata {
    let identity: ActivityIdentity
    let roots: Set<String>
    let candidates: Set<String>
    let unread: Set<String>?

    static func read(profile: Profile, home: URL) throws -> ActivityMetadata {
        let identity = try ActivityIdentity.read(profile: profile, home: home)
        let directory = profile.home(in: home)
        let stateDatabase = directory.appendingPathComponent("state_5.sqlite")
        // The desktop also creates top-level Work tasks with source "unknown".
        // This only makes them eligible for discovery; the live owner still confirms activity.
        // Explicit child paths and structured subagent sources remain excluded.
        let roots = try strings(database: stateDatabase, sql: "SELECT id FROM threads WHERE archived = 0 AND source IN ('vscode','cli','unknown') AND (agent_path IS NULL OR agent_path = '/root')")
        let automationThreads = try strings(database: stateDatabase, sql: "SELECT id FROM threads WHERE thread_source = 'automation'").intersection(roots)
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        let candidates: Set<String>
        if FileManager.default.fileExists(atPath: history.path) {
            do {
                candidates = try strings(database: history, sql: "SELECT t.thread_id FROM thread_turns t JOIN (SELECT thread_id, MAX(rollout_ordinal) AS ordinal FROM thread_turns GROUP BY thread_id) latest ON t.thread_id = latest.thread_id AND t.rollout_ordinal = latest.ordinal WHERE t.status = 'inProgress'")
            } catch ActivityReadError.database(let code) where code & 0xff == SQLITE_CANTOPEN {
                // macOS SQLite cannot read some checkpointed WAL databases without sidecars.
                // History is only a discovery optimization. Ask the existing desktop owner
                // about eligible roots instead; only a live stream can count a task as working.
                // Do not reopen writable, synthesize sidecars, or ignore a live WAL.
                candidates = roots
            }
        } else { candidates = [] }
        let file = directory.appendingPathComponent(".codex-global-state.json")
        var unread: Set<String>?
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1_024 * 1_024,
           let data = try? Data(contentsOf: file) {
            unread = unreadIDs(data: data, identity: identity.unreadKey, roots: roots)
        } else if roots.isEmpty { unread = [] }
        if let raw = unread, !raw.isDisjoint(with: automationThreads) {
            // Scheduled-task inbox read_at is authoritative. Its chat flag can remain true after Read all.
            let databases = ["codex-dev.db", "codex.db"].map { directory.appendingPathComponent("sqlite/" + $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if databases.count == 1,
               let pending = try? strings(database: databases[0], sql: "SELECT thread_id FROM automation_runs WHERE read_at IS NULL AND status IN ('PENDING_REVIEW','ACCEPTED')") {
                // Only filter IDs already tied to this signed-in identity; legacy automation rows have no owner.
                unread = raw.subtracting(automationThreads).union(raw.intersection(automationThreads).intersection(pending))
            } else { unread = nil }
        }
        guard try ActivityIdentity.read(profile: profile, home: home) == identity else { throw ActivityReadError.identity }
        return ActivityMetadata(identity: identity, roots: roots, candidates: candidates.intersection(roots), unread: unread)
    }

    static func unreadIDs(data: Data, identity: String, roots: Set<String>) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // A fresh desktop profile has no read-state key until its first unread result.
        guard let state = object["electron-thread-read-state-v1"] as? [String: Any] else { return roots.isEmpty ? [] : nil }
        guard state["version"] as? Int == 1, let identities = state["unreadByIdentity"] as? [String: Any] else { return nil }
        guard let host = identities[identity] as? [String: Any] else { return [] }
        guard let value = host[ActivityIdentity.localHostKey] else { return [] }
        guard let ids = value as? [String] else { return nil }
        return Set(ids).intersection(roots)
    }

    private static func strings(database: URL, sql: String) throws -> Set<String> {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw ActivityReadError.database(opened)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw ActivityReadError.database(prepared) }
        defer { sqlite3_finalize(statement) }
        var result: Set<String> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ActivityReadError.database(status) }
            result.insert(String(cString: text))
        }
    }
}
