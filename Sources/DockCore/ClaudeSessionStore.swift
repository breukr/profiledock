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
    public func read() -> [ClaudeSession] {
        let fm = FileManager.default
        guard root.resolvingSymlinksInPath() == root.standardizedFileURL else { return [] }
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? [])
            .filter { $0.pathExtension == "json" }.prefix(5000).compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) < 65536, let data = try? Data(contentsOf: url),
                      let value = try? JSONDecoder().decode(ClaudeSession.self, from: data), ClaudeSession.validID(value.id),
                      url.deletingPathExtension().lastPathComponent == value.id else { return nil }
                return value
            }
    }
    public func record(payload: [String: Any], statusline: Bool, process: (Int32, Double)?, tty: String?, now: Date = Date()) throws -> ClaudeSession {
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
        value.apply(payload, statusline: statusline, now: now)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}
