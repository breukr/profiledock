import Foundation
import SQLite3

/// Source databases are never opened writable. A closed, checkpointed WAL database may
/// need an immutable PRIVATE copy on macOS; never use immutable on a live source.
final class ContextDatabase {
    private var handle: OpaquePointer?
    private var snapshot: URL?
    private let deadline: Date
    init(_ url: URL, deadline: Date) throws {
        self.deadline = deadline
        let fm = FileManager.default
        guard url.resolvingSymlinksInPath().path == url.path else { throw ContextError.message("Linked conversation databases are not supported for context sharing.") }
        guard fm.fileExists(atPath: url.path) else { throw ContextError.message("Local conversation history is not available.") }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let shm = URL(fileURLWithPath: url.path + "-shm")
        if fm.fileExists(atPath: wal.path) {
            guard fm.fileExists(atPath: shm.path) else { throw ContextError.message("Conversation history is changing. Try again after the source profile is idle.") }
            try open(url.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        } else {
            // Avoid SQLite creating sidecars for WAL-mode databases without an existing WAL.
            let before = try fm.attributesOfItem(atPath: url.path)
            let dir = fm.temporaryDirectory.appendingPathComponent("profiledock-context-" + UUID().uuidString)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            snapshot = dir
            let copy = dir.appendingPathComponent("history.sqlite")
            do {
                try fm.copyItem(at: url, to: copy)
                let after = try fm.attributesOfItem(atPath: url.path)
                guard !fm.fileExists(atPath: wal.path), before[.size] as? UInt64 == after[.size] as? UInt64,
                      before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                      before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64 else {
                    throw ContextError.message("Conversation history changed while reading. Try again.")
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                try open(copy.absoluteString + "?mode=ro&immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX)
            } catch { try? fm.removeItem(at: dir); throw error }
        }
        sqlite3_busy_timeout(handle, 200)
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<ContextDatabase>.fromOpaque(pointer).takeUnretainedValue().deadline < Date() ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        try execute("PRAGMA query_only=ON")
        try execute("BEGIN")
    }
    private func open(_ path: String, flags: Int32) throws {
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            if let handle { sqlite3_close(handle); self.handle = nil }
            throw ContextError.message("Local history could not be opened (SQLite \(code)).")
        }
    }
    deinit { if let handle { sqlite3_close(handle) }; if let snapshot { try? FileManager.default.removeItem(at: snapshot) } }
    func execute(_ sql: String) throws { try rows(sql) { _ in } }
    func columns(_ table: String) throws -> Set<String> {
        var names = Set<String>()
        try rows("PRAGMA table_info(\(table))") { row in names.insert(row.string(1)) }
        return names
    }
    func rows(_ sql: String, bindings: [String] = [], visit: (ContextRow) throws -> Void) throws {
        guard Date() < deadline else { throw ContextError.message("Search time limit reached. Narrow the date range or choose fewer profiles.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContextError.message("This conversation storage format is not supported yet. Update ProfileDock.")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw ContextError.message(code == SQLITE_INTERRUPT ? "Search time limit reached. Narrow the date range or choose fewer profiles." : "Conversation history is busy or unavailable. Try again.") }
            try visit(ContextRow(statement: statement))
        }
    }
}

struct ContextRow {
    let statement: OpaquePointer
    func string(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
}
