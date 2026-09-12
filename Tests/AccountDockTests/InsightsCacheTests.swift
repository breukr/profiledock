import XCTest
import DockCore
@testable import AccountDock

final class InsightsCacheTests: XCTestCase {
    private let profiles = [Profile(id: "default", name: "Personal", color: "377CF6")]
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        return root
    }
    private func line(_ type: String, _ payload: [String: Any], date: Date) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": ISO8601DateFormatter().string(from: date), "payload": payload])
        data.append(10); return data
    }
    private func event(_ total: Int, date: Date) throws -> Data {
        try line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": total / 10], "last_token_usage": ["input_tokens": 100, "output_tokens": 10]]], date: date)
    }
    private func history(date: Date, id: String = "cached-session") throws -> Data {
        var data = try line("session_meta", ["id": id, "timestamp": ISO8601DateFormatter().string(from: date.addingTimeInterval(-60))], date: date)
        data.append(try line("turn_context", ["model": "gpt-6-astra", "turn_id": "turn"], date: date))
        data.append(try event(100, date: date))
        data.append(try line("response_item", ["type": "message", "content": "PRIVATE TRANSCRIPT SENTINEL"], date: date))
        return data
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func testRestartResumesCompleteRecordsAndCacheNeverStoresTranscriptText() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/sessions/history.jsonl"), now = Date()
        let second = try event(200, date: now.addingTimeInterval(-5))
        var data = try history(date: now.addingTimeInterval(-60)); data.append(second.prefix(20))
        try data.write(to: file)
        let initial = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        XCTAssertEqual(initial.samples.count, 1)
        let disk = InsightsDiskCache.location(home: root)
        let encoded = try String(contentsOf: disk, encoding: .utf8)
        XCTAssertFalse(encoded.contains("PRIVATE TRANSCRIPT SENTINEL"))
        XCTAssertFalse(encoded.contains(file.path))
        let mode = try FileManager.default.attributesOfItem(atPath: disk.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let restarted = InsightsScanner()
        let saved = await restarted.cachedSnapshot(profiles: profiles, home: root, now: now)
        XCTAssertEqual(saved?.0.samples.count, 1)
        try append(Data(second.dropFirst(20)), to: file)
        let next = try await restarted.scan(profiles: profiles, home: root, now: now)
        XCTAssertEqual(next.samples.reduce(0) { $0 + $1.tokens.total }, 220)
        XCTAssertEqual(next.bytesRead, UInt64(second.count), "Only the previously incomplete line should be read again")
        let unchanged = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        XCTAssertEqual(unchanged.samples.count, 2)
        XCTAssertEqual(unchanged.bytesRead, 0)
    }

    func testRewrittenAndDeletedFilesDoNotKeepOldTotals() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/sessions/history.jsonl"), now = Date()
        try history(date: now.addingTimeInterval(-60)).write(to: file)
        _ = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        var replacement = try history(date: now.addingTimeInterval(-30), id: "replacement-session")
        replacement.append(try line("response_item", ["content": String(repeating: "x", count: 4096)], date: now))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: replacement); try handle.close()
        let replaced = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        XCTAssertEqual(replaced.samples.map(\.sessionID), ["replacement-session"])
        XCTAssertEqual(replaced.bytesRead, UInt64(replacement.count))
        try FileManager.default.removeItem(at: file)
        let deleted = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        XCTAssertTrue(deleted.samples.isEmpty)
        let restored = await InsightsScanner().cachedSnapshot(profiles: profiles, home: root, now: now)
        XCTAssertTrue(restored?.0.samples.isEmpty == true)
    }

    func testCorruptAndIncompatibleCachesFallBackToSourceHistory() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/sessions/history.jsonl"), now = Date()
        let original = try history(date: now.addingTimeInterval(-60)); try original.write(to: file)
        _ = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        try Data("broken cache".utf8).write(to: InsightsDiskCache.location(home: root))
        XCTAssertNil(InsightsDiskCache.load(home: root, now: now))
        let recovered = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        XCTAssertEqual(recovered.bytesRead, UInt64(original.count))
        var saved = try XCTUnwrap(InsightsDiskCache.load(home: root, now: now))
        saved.version += 1; try InsightsDiskCache.save(saved, home: root)
        XCTAssertNil(InsightsDiskCache.load(home: root, now: now))
        saved.version = InsightsDiskCache.format; saved.pricing = "Older pricing"
        try InsightsDiskCache.save(saved, home: root)
        XCTAssertNil(InsightsDiskCache.load(home: root, now: now))
    }

    func testMidnightPrunesExpiredSamplesWithoutRescanningHistory() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let old = InsightsPeriod.month.start(now: now, calendar: .current).addingTimeInterval(60)
        let file = root.appendingPathComponent(".codex/sessions/history.jsonl")
        try history(date: old).write(to: file)
        _ = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let extra = try event(200, date: tomorrow.addingTimeInterval(-60))
        try append(extra, to: file)
        let next = try await InsightsScanner().scan(profiles: profiles, home: root, now: tomorrow)
        XCTAssertEqual(next.samples.count, 1)
        XCTAssertEqual(next.samples.first?.tokens.total, 110)
        XCTAssertEqual(next.bytesRead, UInt64(extra.count))
    }

    @MainActor func testLaunchPreloadsSavedStatisticsBeforeReadingNewHistory() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/sessions/history.jsonl"), now = Date()
        try history(date: now.addingTimeInterval(-60)).write(to: file)
        _ = try await InsightsScanner().scan(profiles: profiles, home: root, now: now)
        try append(event(200, date: now.addingTimeInterval(-5)), to: file)
        let store = InsightsStore(); defer { store.shutdown() }
        store.prepare(profiles: profiles, home: root)
        for _ in 0..<200 where store.lastUpdated == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.snapshot.samples.count, 1, "Preloading only reads the saved cache")
        XCTAssertTrue(store.showingSavedStatistics)
        XCTAssertFalse(store.refreshing)
        store.refresh(profiles: profiles, home: root)
        XCTAssertEqual(store.snapshot.samples.count, 1, "The saved graph stays visible during refresh")
        for _ in 0..<200 where store.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.snapshot.samples.count, 2)
        XCTAssertFalse(store.showingSavedStatistics)
    }

    @MainActor func testRefreshAndProfileChangesKeepExistingStatisticsVisible() {
        let now = Date(), sample = InsightSample(id: "one", profileID: "default", sessionID: "session", date: now, model: nil, tokens: .init(input: 100), estimatedCost: nil)
        let store = InsightsStore(snapshot: InsightsScan(samples: [sample]), lastUpdated: now)
        defer { store.shutdown() }
        store.configure(profiles)
        store.configure(profiles + [Profile(id: "work", name: "Work", color: "377CF6")])
        XCTAssertEqual(store.snapshot.samples.count, 1)
        XCTAssertEqual(store.lastUpdated, now)
        store.refresh(profiles: profiles, home: FileManager.default.temporaryDirectory, force: true)
        XCTAssertTrue(store.refreshing)
        XCTAssertEqual(store.snapshot.samples.count, 1)
        XCTAssertEqual(store.lastUpdated, now)
    }
}
