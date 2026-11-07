import Foundation
import Darwin

public enum ClaudeProcess {
    public static func startTime(_ pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
    public static func isAlive(_ session: ClaudeSession) -> Bool {
        guard let pid = session.processID, let started = session.processStarted else { return false }
        return startTime(pid) == started
    }
    public static func ancestor() -> (Int32, Double)? {
        var pid = getppid()
        for _ in 0..<16 {
            guard pid > 1 else { return nil }
            var name = [CChar](repeating: 0, count: 1024)
            _ = proc_name(pid, &name, UInt32(name.count))
            if String(cString: name).lowercased().hasPrefix("claude"), let start = startTime(pid) { return (pid, start) }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
}

public struct ClaudeSessionStore: Sendable {
    public let root: URL
    public init(home: URL) { root = home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeSessions") }
    /// The newest `limit` session files, newest first. With a cache, a file whose modification date and size are
    /// unchanged is not decoded again, so a two-second refresh costs one directory listing.
    public func read(cache: ClaudeSessionCache? = nil, limit: Int = 5000) -> [ClaudeSession] {
        guard let files = listing(extension: "json") else { return [] }
        var parsed: [String: ClaudeSessionCache.Entry] = [:]
        let result = files.prefix(limit).compactMap { file -> ClaudeSession? in
            if let cached = cache?.entry(file.url.lastPathComponent), cached.modified == file.modified, cached.size == file.size {
                parsed[file.url.lastPathComponent] = cached; return cached.session
            }
            let session = decode(file)
            parsed[file.url.lastPathComponent] = ClaudeSessionCache.Entry(modified: file.modified, size: file.size, session: session)
            return session
        }
        cache?.replace(with: parsed)
        return result
    }

    /// Deletes the metadata of sessions that ended or whose process is gone, once untouched for `maxAge`.
    /// The newest `keep` files always stay. Returns the session ids that remain, or nil when the folder could not be listed.
    @discardableResult
    public func prune(now: Date = Date(), maxAge: TimeInterval = 7 * 86_400, keep: Int = 200, isAlive: (ClaudeSession) -> Bool = ClaudeProcess.isAlive) -> Set<String>? {
        guard let files = listing(extension: "json") else { return nil }
        let fm = FileManager.default
        var remaining = Set<String>()
        for (index, file) in files.enumerated() {
            let id = file.url.deletingPathExtension().lastPathComponent
            // A file that does not decode may come from a newer version; it is left alone.
            guard index >= keep, file.modified < now.addingTimeInterval(-maxAge), let session = decode(file),
                  session.state == .closed || !isAlive(session) else { remaining.insert(id); continue }
            // The same lock the helper takes while it writes, so a session that comes back mid-prune is not lost.
            let lockURL = root.appendingPathComponent(id + ".lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { remaining.insert(id); continue }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { remaining.insert(id); continue }
            try? fm.removeItem(at: file.url); try? fm.removeItem(at: lockURL)
            flock(descriptor, LOCK_UN)
        }
        // Lock files of sessions whose metadata is gone.
        for lock in listing(extension: "lock") ?? [] where lock.modified < now.addingTimeInterval(-maxAge) {
            if !remaining.contains(lock.url.deletingPathExtension().lastPathComponent) { try? fm.removeItem(at: lock.url) }
        }
        return remaining
    }

    struct File { let url: URL; let modified: Date; let size: Int }

    /// Regular files with this extension, newest first. Nil when the folder is missing, linked or unreadable.
    func listing(extension pathExtension: String) -> [File]? {
        guard root.resolvingSymlinksInPath() == root.standardizedFileURL else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return nil }
        return urls.filter { $0.pathExtension == pathExtension }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            return File(url: url, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? Int.max)
        }.sorted { $0.modified > $1.modified }
    }

    func decode(_ file: File) -> ClaudeSession? {
        guard file.size < 65536, let data = try? Data(contentsOf: file.url),
              let value = try? JSONDecoder().decode(ClaudeSession.self, from: data), ClaudeSession.validID(value.id),
              file.url.deletingPathExtension().lastPathComponent == value.id else { return nil }
        return value
    }
    public func record(payload: [String: Any], statusline: Bool, process: (Int32, Double)?, tty: String?, configDirectory: String? = nil, now: Date = Date()) throws -> ClaudeSession {
        guard let id = payload["session_id"] as? String, ClaudeSession.validID(id),
              let project = payload["cwd"] as? String ?? (payload["workspace"] as? [String: Any])?["current_dir"] as? String,
              project.hasPrefix("/"), project.utf8.count < 8192 else { throw CompanionError.message("Invalid Claude session metadata.") }
        let fm = FileManager.default
        guard root.resolvingSymlinksInPath() == root.standardizedFileURL else { throw CompanionError.message("Linked session folders are not supported.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = root.appendingPathComponent(id + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CompanionError.message("Cannot lock session metadata.") }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CompanionError.message("Cannot lock session metadata.") }
        let url = root.appendingPathComponent(id + ".json")
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw CompanionError.message("Linked session files are not supported.") }
        var value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ClaudeSession.self, from: $0) }
            ?? ClaudeSession(id: id, project: project, now: now)
        value.project = project
        if let process { value.processID = process.0; value.processStarted = process.1 }
        if let tty, ClaudeSession.validTTY(tty) { value.tty = tty }
        if let configDirectory, configDirectory.hasPrefix("/") { value.configDirectory = configDirectory }
        value.apply(payload, statusline: statusline, now: now)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}

/// Parsed session files by file name, with the modification date and size they were parsed at.
/// Shared between refreshes on background threads, so access goes through a lock (one thread at a time).
public final class ClaudeSessionCache: @unchecked Sendable {
    struct Entry { let modified: Date; let size: Int; let session: ClaudeSession? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public init() {}
    func entry(_ name: String) -> Entry? { lock.withLock { entries[name] } }
    /// Keeps only the files of the last listing, so deleted sessions do not stay in memory.
    func replace(with entries: [String: Entry]) { lock.withLock { self.entries = entries } }
    public var count: Int { lock.withLock { entries.count } }
}
