import Foundation
import CryptoKit
import Darwin
import DockCore

enum ClaudePricing {
    static let source = "https://platform.claude.com/docs/en/about-claude/pricing"
    static let checkedOn = "23 September 2026"
    static func estimate(model: String?, usage: [String: Any], tokens: InsightTokens) -> Double? {
        guard let model, tokens.valid else { return nil }
        let key = model.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
        let rates: [String: (Double, Double, Double)] = [
            "claude-opus-4-5": (5, 25, 0.5), "claude-opus-4-6": (5, 25, 0.5),
            "claude-opus-4-7": (5, 25, 0.5), "claude-opus-4-8": (5, 25, 0.5),
            "claude-opus-5": (5, 25, 0.5), "claude-opus-5-5": (4, 20, 0.2),
            "claude-sonnet-4-5": (3, 15, 0.3), "claude-sonnet-4-6": (3, 15, 0.3),
            "claude-sonnet-5": (2, 10, 0.2), "claude-haiku-4-5": (1, 5, 0.1),
            "claude-fable-5": (10, 50, 1), "claude-fable-5-1": (10, 50, 0.25)
        ]
        guard let rate = rates[key], usage["speed"] as? String != "fast" else { return nil }
        // Legacy extended-context pricing varies; do not silently price it at the base rate.
        if key == "claude-sonnet-4-5", tokens.input > 200_000 { return nil }
        let cache = usage["cache_creation"] as? [String: Any]
        let hour = (cache?["ephemeral_1h_input_tokens"] as? Int64) ?? 0
        guard hour >= 0, hour <= tokens.written else { return nil }
        let ordinary = Double(tokens.input - tokens.cached - tokens.written) * rate.0
        let written = Double(tokens.written - hour) * rate.0 * 1.25 + Double(hour) * rate.0 * 2
        return (ordinary + written + Double(tokens.cached) * rate.2 + Double(tokens.output) * rate.1) / 1_000_000
    }
}

enum ClaudeInsights {
    static func scan(profiles: [Profile], home: URL, cutoff: Date) throws -> InsightsScan {
        try ClaudeInsightsScanner().scan(profiles: profiles, home: home, cutoff: cutoff)
    }
}

/// Saves only usage metadata and complete-line offsets, so large histories resume instead of restarting.
final class ClaudeInsightsScanner {
    struct Record: Codable {
        var inode: UInt64
        var modified: Date
        var size: UInt64
        var offset: UInt64 = 0
        var fingerprint: String?
        var signature: String
        var owner: String?
        var samples: [String: InsightSample] = [:]
        var incomplete = false
        var discarding = false
        var valid: Bool {
            offset <= size && fingerprint?.count == 64 && signature.count == 64
                && samples.count <= 100_000
                && samples.values.allSatisfy { $0.tokens.valid && Profile.validID($0.profileID)
                    && $0.id.count <= 512 && $0.sessionID.count <= 160
                    && ($0.estimatedCost.map { $0.isFinite && $0 >= 0 } ?? true) }
        }
    }
    var records: [String: Record] = [:]
    private let maximumBytesPerFile: Int
    private let maximumDuration: TimeInterval
    init(maximumBytesPerFile: Int = 24 * 1024 * 1024, maximumDuration: TimeInterval = 20) {
        self.maximumBytesPerFile = max(65_536, maximumBytesPerFile)
        self.maximumDuration = maximumDuration
    }

    func scan(profiles: [Profile], home: URL, cutoff: Date) throws -> InsightsScan {
        let entries = profiles.filter { $0.kind != .codex }.sorted { $0.id < $1.id }
        guard !entries.isEmpty else { records.removeAll(); return InsightsScan() }
        let configuration = entries.map { [$0.id, $0.kind.rawValue, $0.projectPath ?? "", $0.claudeSessionID ?? ""].joined(separator: "\n") }.joined(separator: "\0")
        let signature = digest(Data(configuration.utf8))
        let files = try ClaudeHistory.files(home: home, since: cutoff)
        let deadline = Date().addingTimeInterval(maximumDuration)
        var result = InsightsScan(), retained: Set<String> = []
        for file in files {
            try Task.checkCancellation()
            let key = InsightsDiskCache.key(profile: "claude", file: file, home: home)
            retained.insert(key)
            let id = file.deletingPathExtension().lastPathComponent
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                var entry = records[key]
                if let old = entry {
                    let changed = old.signature != signature || old.inode != inode || size < old.size
                        || (size == old.size && modified != old.modified)
                    if changed { entry = nil }
                    else if old.fingerprint != (try fingerprint(file, offset: old.offset)) { entry = nil }
                }
                var record = entry ?? Record(inode: inode, modified: modified, size: size, signature: signature)
                record.samples = record.samples.filter { $0.value.date >= cutoff }
                if record.offset < size {
                    if Date() < deadline {
                        let read = try read(file, record: &record, size: size, id: id, entries: entries, cutoff: cutoff, deadline: deadline)
                        result.bytesRead += read.bytes
                        result.historyPending = result.historyPending || read.pending
                    } else { result.historyPending = true }
                }
                record.fingerprint = try fingerprint(file, offset: record.offset)
                record.modified = modified; record.size = size
                records[key] = record
                result.samples += record.samples.values
                if record.incomplete {
                    for entry in entries { result.warnings[entry.id] = "Some local Claude records could not be read. Token totals cover readable Code records only." }
                }
                result.files += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A temporary read error keeps earlier counters until this file can be read again.
                if let record = records[key], record.signature == signature {
                    result.samples += record.samples.values.filter { $0.date >= cutoff }
                }
                for entry in entries { result.warnings[entry.id] = "Some local Claude transcripts could not be read. Token totals cover readable Code records only." }
            }
        }
        records = records.filter { retained.contains($0.key) }
        if result.historyPending || files.count >= 5000 {
            for entry in entries {
                result.warnings[entry.id] = result.historyPending
                    ? "Claude history is still loading. Token totals are incomplete and will update as reading continues."
                    : "Claude history exceeds the local file limit. Token totals cover readable Code sessions only."
            }
        }
        for entry in entries where result.warnings[entry.id] == nil {
            result.warnings[entry.id] = "Local Claude Code history only; Chat, Cowork, cloud-only and subagent transcripts are excluded. Project entries take precedence over Claude Desktop to avoid counting a session twice."
        }
        return result
    }

    private func read(_ file: URL, record: inout Record, size: UInt64, id: String, entries: [Profile], cutoff: Date, deadline: Date) throws -> (bytes: UInt64, pending: Bool) {
        guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { throw CompanionError.message("Linked transcript files are excluded.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let start = record.offset
        try handle.seek(toOffset: start)
        var consumed = start, buffer = Data()
        while consumed < size {
            try Task.checkCancellation()
            if Date() >= deadline || consumed - start >= maximumBytesPerFile { return (consumed - start, true) }
            let advanced = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: Int(min(65_536, size - consumed))), !chunk.isEmpty else { return false }
                consumed += UInt64(chunk.count); buffer.append(chunk)
                while let offset = buffer.withUnsafeBytes({ bytes -> Int? in
                    guard let base = bytes.baseAddress, let match = memchr(base, 10, bytes.count) else { return nil }
                    return base.distance(to: UnsafeRawPointer(match))
                }) {
                    let newline = buffer.startIndex + offset, line = buffer.prefix(upTo: newline)
                    if line.count > 2_097_152 { record.incomplete = true }
                    else if !record.discarding {
                        autoreleasepool { consume(Data(line), record: &record, id: id, entries: entries, cutoff: cutoff) }
                    }
                    buffer.removeSubrange(...newline); record.discarding = false
                    record.offset = consumed - UInt64(buffer.count)
                }
                if buffer.count > 2_097_152 || record.discarding {
                    if buffer.count > 2_097_152 { record.incomplete = true; record.discarding = true }
                    buffer.removeAll(keepingCapacity: true); record.offset = consumed
                }
                return true
            }
            if !advanced { break }
        }
        // Incomplete final lines belong to an active writer. Retry them when the file changes.
        return (consumed - start, false)
    }

    private func consume(_ data: Data, record: inout Record, id: String, entries: [Profile], cutoff: Date) {
        // Huge prompt/tool rows do not need JSON decoding to count assistant usage.
        guard data.range(of: Data("\"assistant\"".utf8)) != nil else {
            if let first = data.first(where: { ![9, 13, 32].contains($0) }), first != 123 { record.incomplete = true }
            return
        }
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { record.incomplete = true; return }
        guard row["isSidechain"] as? Bool != true, let cwd = row["cwd"] as? String, row["type"] as? String == "assistant" else { return }
        if record.owner == nil {
            record.owner = (entries.first { $0.claudeSessionID == id }
                ?? entries.first { $0.kind.usesTerminal && $0.projectPath == cwd }
                ?? entries.first { $0.kind == .claude })?.id
        }
        guard let owner = record.owner, let message = row["message"] as? [String: Any],
              let messageID = message["id"] as? String, !messageID.isEmpty, messageID.utf8.count <= 128,
              let usage = message["usage"] as? [String: Any],
              let date = ClaudeHistory.timestamp(row["timestamp"] as? String ?? ""), date >= cutoff else { return }
        func count(_ key: String) -> Int64 { usage[key] as? Int64 ?? 0 }
        let cached = count("cache_read_input_tokens"), written = count("cache_creation_input_tokens"), input = count("input_tokens"), output = count("output_tokens")
        guard [input, cached, written, output].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }) else { record.incomplete = true; return }
        let tokens = InsightTokens(input: input + cached + written, cached: cached, written: written, output: output)
        guard tokens.valid else { record.incomplete = true; return }
        if let old = record.samples[messageID], old.tokens.total >= tokens.total { return }
        let key = "claude:" + id + ":" + messageID, model = message["model"] as? String
        record.samples[messageID] = InsightSample(id: key, profileID: owner, sessionID: "claude:" + id, date: date, model: model, tokens: tokens,
            estimatedCost: ClaudePricing.estimate(model: model, usage: usage, tokens: tokens))
    }

    private func fingerprint(_ file: URL, offset: UInt64) throws -> String {
        guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { throw CompanionError.message("Linked transcript files are excluded.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let length = min(offset, 4096)
        var data = try handle.read(upToCount: Int(length)) ?? Data()
        try handle.seek(toOffset: offset - length)
        data.append(try handle.read(upToCount: Int(length)) ?? Data())
        return digest(data)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
