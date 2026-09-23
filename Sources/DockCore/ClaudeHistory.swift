import Foundation

/// Bounded reader for local Claude Code transcripts. Subagent directories and linked files are excluded.
public enum ClaudeHistory {
    public static func files(home: URL, since: Date? = nil, limit: Int = 5000) throws -> [URL] {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard root.resolvingSymlinksInPath() == root.standardizedFileURL else { throw CompanionError.message("Linked Claude history folders are excluded.") }
        var result: [(URL, Date)] = []
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).prefix(5000) {
            try Task.checkCancellation()
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
                guard file.pathExtension == "jsonl", ClaudeSession.validID(file.deletingPathExtension().lastPathComponent) else { continue }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                if let since, modified < since { continue }
                result.append((file, modified))
                if result.count >= limit { return result.sorted { $0.1 > $1.1 }.map(\.0) }
            }
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }
    @discardableResult public static func records(file: URL, after: Int64 = -1, maximumBytes: Int = 24 * 1024 * 1024, deadline: Date,
            visit: ([String: Any], Int64) throws -> Bool) throws -> Bool {
        guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { throw CompanionError.message("Linked transcript files are excluded.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var position = max(0, after), pending = Data(), total = 0
        if position > 0 { try handle.seek(toOffset: UInt64(position)) }
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { return true }
            guard let data = try handle.read(upToCount: 65536), !data.isEmpty else { return !pending.isEmpty }
            total += data.count
            if total > maximumBytes { return true }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let raw = Data(pending[..<end]), length = pending.distance(from: pending.startIndex, to: end) + 1
                pending.removeFirst(length); position += Int64(length)
                guard !raw.isEmpty else { continue }
                guard let row = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw CompanionError.message("A Claude history record could not be read.") }
                if try !visit(row, position) { return true }
            }
        }
    }
    public static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: value) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    public static func belongs(_ record: [String: Any], project: String?) -> Bool {
        guard record["isSidechain"] as? Bool != true else { return false }
        guard let project else { return true }
        guard let cwd = record["cwd"] as? String else { return false }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path == URL(fileURLWithPath: project).standardizedFileURL.path
    }
}
