import Foundation
import CryptoKit
import Darwin
import DockCore

/// Only counters and small metadata survive parsing. No prompts, responses, or auth files are retained.
final class InsightRolloutParser {
    private(set) var sessionID: String?
    private(set) var parentID: String?
    private var createdAt: Date?
    private var model: String?
    private var turnID = ""
    private var previous: InsightTokens?
    private var seenTotals: Set<InsightTokens> = []
    private var replay = false
    private let profileID: String
    private let cutoff: Date
    private(set) var samples: [InsightSample] = []
    private(set) var incomplete = false
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init(profileID: String, cutoff: Date) {
        self.profileID = profileID; self.cutoff = cutoff
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    private func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
    func discardOversizedLine() { incomplete = true; model = nil }

    func consume(_ data: Data) {
        guard data.range(of: Data("session_meta".utf8)) != nil
                || data.range(of: Data("turn_context".utf8)) != nil
                || data.range(of: Data("token_count".utf8)) != nil else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String, let payload = root["payload"] as? [String: Any] else {
            incomplete = true; return
        }
        if type == "session_meta" {
            let id = (payload["id"] ?? payload["session_id"]) as? String
            guard let id, !id.isEmpty, id.utf8.count <= 128 else { incomplete = true; return }
            if sessionID == nil {
                sessionID = id; createdAt = date(payload["timestamp"] ?? root["timestamp"])
                if createdAt == nil { incomplete = true }
                let source = payload["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawn = subagent?["thread_spawn"] as? [String: Any]
                parentID = spawn?["parent_thread_id"] as? String
            } else if id != sessionID { replay = true; model = nil }
            return
        }
        let timestamp = date(root["timestamp"])
        let owned = timestamp.map { value in createdAt.map { value >= $0 } ?? false } ?? false
        if type == "turn_context" {
            if owned { replay = false }
            let candidate = (payload["model"] ?? payload["model_name"]) as? String
            model = candidate.flatMap { $0.utf8.count <= 128 ? $0 : nil }
            turnID = (payload["turn_id"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil } ?? ""
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count" else { return }
        guard let info = payload["info"] as? [String: Any] else { return } // Rate-limit-only events have null info.
        let total = tokens(info["total_token_usage"])
        let last = tokens(info["last_token_usage"])
        if let total, !seenTotals.insert(total).inserted {
            if total != previous { incomplete = true }
            return
        }
        defer { if let total { previous = total } }
        guard !replay, owned, let timestamp, let sessionID else { return }
        // A rate-limit refresh can repeat the previous counter without a new model request.
        let amount: InsightTokens
        let singleRequest: Bool
        if let total, let previous, let delta = total.delta(from: previous) {
            amount = delta; singleRequest = last == delta
        } else if let last {
            // First snapshots and compacted/forked counters may include inherited work.
            // Only the last request is attributable here; never bill inherited cumulative totals.
            amount = last; singleRequest = true
            if previous == nil, let total, total != last { incomplete = true }
        } else {
            incomplete = true; return
        }
        guard amount.total > 0 else { return }
        guard timestamp >= cutoff else { return }
        if !singleRequest { incomplete = true }
        let tokenModel = ((info["model"] ?? payload["model"]) as? String) ?? model
        let signature = "\(sessionID)|\(turnID)|\(timestamp.timeIntervalSince1970)|\(total ?? amount)"
        let id = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        samples.append(InsightSample(id: id, profileID: profileID, sessionID: sessionID,
            date: timestamp, model: tokenModel, tokens: amount,
            estimatedCost: singleRequest ? InsightPricing.estimate(model: tokenModel, tokens: amount) : nil))
    }

    private func tokens(_ value: Any?) -> InsightTokens? {
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String, required: Bool = false) -> Int64? {
            guard let value = object[key] else { return required ? nil : 0 }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1_000_000_000_000,
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.int64Value
        }
        guard let input = number("input_tokens", required: true), let output = number("output_tokens", required: true),
              let cached = number(object["cached_input_tokens"] != nil ? "cached_input_tokens" : "cache_read_input_tokens"),
              let written = number("cache_write_input_tokens") else { incomplete = true; return nil }
        let result = InsightTokens(input: input, cached: cached, written: written, output: output)
        guard result.valid else { incomplete = true; return nil }
        // Reasoning tokens are already part of output_tokens.
        return result
    }
}

struct InsightsScan: Sendable {
    var samples: [InsightSample] = []
    var warnings: [String: String] = [:]
    var files = 0
}

actor InsightsScanner {
    private final class CachedFile {
        let parser: InsightRolloutParser
        let inode: UInt64
        var modified: Date
        var offset: UInt64 = 0
        var size: UInt64 = 0
        init(parser: InsightRolloutParser, inode: UInt64, modified: Date) {
            self.parser = parser; self.inode = inode; self.modified = modified
        }
    }
    private var cache: [String: CachedFile] = [:]
    private var cacheDay: Date?

    func scan(profiles: [Profile], home: URL, now: Date, progress: @Sendable (Int) -> Void = { _ in }) throws -> InsightsScan {
        let fm = FileManager.default
        let day = Calendar.current.startOfDay(for: now)
        let cutoff = InsightsPeriod.month.start(now: now, calendar: .current)
        if cacheDay != day { cache.removeAll(); cacheDay = day }
        var result = InsightsScan(), paths: Set<String> = [], lineage: [String: String] = [:]
        for profile in profiles {
            try Task.checkCancellation()
            guard Profile.validID(profile.id) else { continue }
            let profileHome = profile.home(in: home).resolvingSymlinksInPath()
            var foundDirectory = false, candidates: [URL] = []
            for folder in ["sessions", "archived_sessions"] {
                let directory = profileHome.appendingPathComponent(folder)
                guard fm.fileExists(atPath: directory.path) else { continue }
                foundDirectory = true
                guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                    result.warnings[profile.id] = "Some local session files could not be read."; return true
                }) else { result.warnings[profile.id] = "Local session history could not be opened."; continue }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    guard url.pathExtension == "jsonl" else { continue }
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
                    if let modified = values.contentModificationDate, modified < cutoff { continue }
                    let resolved = url.resolvingSymlinksInPath()
                    guard resolved.path.hasPrefix(profileHome.path + "/") else {
                        result.warnings[profile.id] = "History outside this profile was excluded."; continue
                    }
                    candidates.append(resolved)
                    if candidates.count >= 20_000 { result.warnings[profile.id] = "This profile exceeds the local history scan limit."; break }
                }
            }
            if !foundDirectory { result.warnings[profile.id] = "No local session history yet. Open a Work or Codex session to begin." }
            for file in candidates.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let key = profile.id + ":" + file.path
                guard paths.insert(key).inserted else { continue }
                do {
                    let attributes = try fm.attributesOfItem(atPath: file.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    var entry = cache[key]
                    if entry == nil || entry!.inode != inode || size < entry!.size || (size == entry!.size && modified != entry!.modified) {
                        entry = CachedFile(parser: InsightRolloutParser(profileID: profile.id, cutoff: cutoff), inode: inode, modified: modified)
                    }
                    let cached = entry!
                    if size > cached.offset { try read(file, into: cached, size: size) }
                    cached.modified = modified; cached.size = size; cache[key] = cached
                    result.samples += cached.parser.samples
                    if let id = cached.parser.sessionID, let parent = cached.parser.parentID { lineage[id] = parent }
                    if cached.parser.incomplete { result.warnings[profile.id] = "Some records are incomplete; totals cover readable, attributable usage." }
                    result.files += 1
                    if result.files.isMultiple(of: 10) { progress(result.files) }
                } catch is CancellationError { throw CancellationError() }
                catch { result.warnings[profile.id] = "Some local session files could not be read." }
            }
        }
        cache = cache.filter { paths.contains($0.key) }
        // Agent work belongs to its root session for the average, while its token usage remains included.
        result.samples = result.samples.map { sample in
            var root = sample.sessionID, seen: Set<String> = []
            while let parent = lineage[root], seen.insert(root).inserted, seen.count < 64 { root = parent }
            return InsightSample(id: sample.id, profileID: sample.profileID, sessionID: root,
                date: sample.date, model: sample.model, tokens: sample.tokens, estimatedCost: sample.estimatedCost)
        }
        return result
    }

    private func read(_ file: URL, into entry: CachedFile, size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        var buffer = Data(), consumed = entry.offset, discarding = false
        // Bound individual metadata lines; huge prompt or tool payloads do not need to enter JSON decoding.
        while consumed < size {
            try Task.checkCancellation()
            let advanced = try autoreleasepool { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: Int(min(65_536, size - consumed))), !chunk.isEmpty else { return false }
            consumed += UInt64(chunk.count); buffer.append(chunk)
            // memchr avoids Swift's generic per-byte collection walk across multi-GB histories.
            while let offset = buffer.withUnsafeBytes({ bytes -> Int? in
                guard let base = bytes.baseAddress, let match = memchr(base, 10, bytes.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(match))
            }) {
                let newline = buffer.startIndex + offset
                let line = buffer.prefix(upTo: newline)
                if line.count > 2_097_152 { entry.parser.discardOversizedLine() }
                else if !discarding { autoreleasepool { entry.parser.consume(Data(line)) } }
                buffer.removeSubrange(...newline)
                discarding = false
                entry.offset = consumed - UInt64(buffer.count)
            }
            if buffer.count > 2_097_152 {
                entry.parser.discardOversizedLine(); buffer.removeAll(keepingCapacity: true); discarding = true
            }
            return true
            }
            if !advanced { break }
        }
        // A writer's unfinished final line is retried next refresh, never decoded as a complete event.
    }
}

@MainActor final class InsightsStore: ObservableObject {
    @Published private(set) var snapshot = InsightsScan()
    @Published private(set) var refreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var scannedFiles = 0
    private let scanner = InsightsScanner()
    private var task: Task<Void, Never>?
    private var configured: [String] = []
    private var generation = 0

    init(snapshot: InsightsScan = InsightsScan(), lastUpdated: Date? = nil) {
        self.snapshot = snapshot; self.lastUpdated = lastUpdated
    }

    func configure(_ profiles: [Profile]) {
        let ids = profiles.map(\.id)
        guard ids != configured else { return }
        generation += 1; task?.cancel(); task = nil; refreshing = false
        configured = ids; snapshot = InsightsScan(); lastUpdated = nil
    }
    func refresh(profiles: [Profile], home: URL, force: Bool = false) {
        configure(profiles)
        guard !refreshing, force || lastUpdated.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        refreshing = true
        scannedFiles = 0
        let ticket = generation
        task = Task { [weak self, scanner] in
            do {
                let result = try await scanner.scan(profiles: profiles, home: home, now: Date()) { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.generation == ticket, self.refreshing else { return }
                        self.scannedFiles = count
                    }
                }
                guard let self, !Task.isCancelled, ticket == self.generation else { return }
                self.snapshot = result; self.lastUpdated = Date(); self.refreshing = false; self.task = nil
            } catch {
                guard let self, ticket == self.generation else { return }
                self.refreshing = false; self.task = nil
            }
        }
    }
    func shutdown() { generation += 1; task?.cancel(); task = nil; refreshing = false }
}
