import XCTest
import DockCore
@testable import AccountDock

final class ClaudeInsightsTests: XCTestCase {
    func testStreamingDuplicatesAreCountedOnceAndProjectOwnsSharedHistory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var desktop = Profile(id: "desktop", name: "Assistant", color: "123456"); desktop.provider = .claude
        var project = Profile(id: "project", name: "Project", color: "123456"); project.provider = .claudeCode; project.projectPath = "/fixture"
        var data = Data()
        for output in [1, 10, 10] {
            let record: [String: Any] = ["type": "assistant", "cwd": "/fixture", "timestamp": "2026-09-23T08:00:00Z", "message": ["id": "same-response", "model": "claude-sonnet-5", "usage": ["input_tokens": 100, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 40, "output_tokens": output]]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        try data.write(to: folder.appendingPathComponent("session-one.jsonl"))
        try Data("invalid-json\n".utf8).write(to: folder.appendingPathComponent("damaged-session.jsonl"))
        let result = try ClaudeInsights.scan(profiles: [desktop, project], home: home, cutoff: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertTrue(result.warnings[project.id]?.contains("could not be read") == true)
        let sample = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(sample.profileID, project.id)
        XCTAssertEqual(sample.tokens.input, 340)
        XCTAssertEqual(sample.tokens.output, 10)
        XCTAssertEqual(try XCTUnwrap(sample.estimatedCost), 0.00044, accuracy: 0.0000001)
        XCTAssertNil(ClaudePricing.estimate(model: "unknown", usage: [:], tokens: sample.tokens))
        XCTAssertNil(ClaudePricing.estimate(model: "claude-sonnet-5", usage: ["speed": "fast"], tokens: sample.tokens))
    }
    private func fixture() throws -> (URL, URL, Profile) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var profile = Profile(id: "desktop", name: "Assistant", color: "123456"); profile.provider = .claude
        return (home, folder.appendingPathComponent("large-session.jsonl"), profile)
    }
    private func usage(_ id: String, output: Int = 10, date: Date = Date().addingTimeInterval(-10)) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "cwd": "/fixture", "timestamp": ISO8601DateFormatter().string(from: date),
            "message": ["id": id, "model": "claude-sonnet-5", "usage": ["input_tokens": 100, "output_tokens": output]]])
        data.append(10); return data
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func testHistoryBeyond24MiBResumesAfterRestartAndReadsOnlyNewBytes() async throws {
        let (home, file, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        var data = try usage("first")
        let filler = Data(("{\"type\":\"user\",\"content\":\"PRIVATE TRANSCRIPT SENTINEL" + String(repeating: "x", count: 65_400) + "\"}\n").utf8)
        for _ in 0..<400 { data.append(filler) }
        data.append(try usage("later")); try data.write(to: file)
        let now = Date()
        let first = try await InsightsScanner().scan(profiles: [profile], home: home, now: now)
        XCTAssertTrue(first.historyPending)
        XCTAssertEqual(first.samples.map(\.id), ["claude:large-session:first"])
        let restored = InsightsScanner()
        let saved = await restored.cachedSnapshot(profiles: [profile], home: home, now: now)
        XCTAssertEqual(saved?.0.samples.count, 1)
        let second = try await restored.scan(profiles: [profile], home: home, now: now)
        XCTAssertFalse(second.historyPending)
        XCTAssertEqual(second.samples.count, 2)
        XCTAssertEqual(second.samples.reduce(0) { $0 + $1.tokens.total }, 220)
        XCTAssertLessThan(second.bytesRead, UInt64(data.count))
        XCTAssertFalse(second.warnings[profile.id]?.contains("still loading") == true)
        let encoded = try String(contentsOf: InsightsDiskCache.location(home: home), encoding: .utf8)
        XCTAssertFalse(encoded.contains("PRIVATE TRANSCRIPT SENTINEL"))
        XCTAssertFalse(encoded.contains(file.path))
        let unchanged = try await InsightsScanner().scan(profiles: [profile], home: home, now: now)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(unchanged.samples.count, 2)
        let extra = try usage("newest")
        try append(extra, to: file)
        let appended = try await InsightsScanner().scan(profiles: [profile], home: home, now: now)
        XCTAssertEqual(appended.bytesRead, UInt64(extra.count))
        XCTAssertEqual(appended.samples.count, 3)
    }

    func testStreamingUpdateAndUnfinishedLineResumeWithoutDoubleCounting() throws {
        let (home, file, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let later = try usage("same", output: 20)
        var data = try usage("same", output: 1); data.append(later.prefix(40)); try data.write(to: file)
        let scanner = ClaudeInsightsScanner(), cutoff = Date(timeIntervalSince1970: 0)
        let first = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertFalse(first.historyPending, "An active writer's unfinished line should wait for more data")
        XCTAssertEqual(first.samples.first?.tokens.total, 101)
        try append(Data(later.dropFirst(40)), to: file)
        let second = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertEqual(second.samples.count, 1)
        XCTAssertEqual(second.samples.first?.tokens.total, 120)
        XCTAssertEqual(second.bytesRead, UInt64(later.count))
    }

    func testExpiredBudgetKeepsSavedCountersAndReportsPendingHistory() throws {
        let (home, file, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        try usage("old").write(to: file)
        let scanner = ClaudeInsightsScanner(), cutoff = Date(timeIntervalSince1970: 0)
        _ = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        try append(usage("new"), to: file)
        let delayed = ClaudeInsightsScanner(maximumDuration: 0); delayed.records = scanner.records
        let result = try delayed.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertTrue(result.historyPending)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertTrue(result.warnings[profile.id]?.contains("Token totals are incomplete") == true)
        scanner.records = delayed.records
        let finished = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertFalse(finished.historyPending)
        XCTAssertEqual(finished.samples.count, 2)
    }

    func testRewriteDeletionAndNewProjectOwnershipDiscardObsoleteCounters() throws {
        let (home, file, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ClaudeInsightsScanner(), cutoff = Date(timeIntervalSince1970: 0)
        try usage("old").write(to: file)
        _ = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        var project = Profile(id: "project", name: "Project", color: "123456"); project.provider = .claudeCode; project.projectPath = "/fixture"
        let remapped = try scanner.scan(profiles: [profile, project], home: home, cutoff: cutoff)
        XCTAssertEqual(remapped.samples.first?.profileID, project.id)
        try usage("replacement").write(to: file)
        let rewritten = try scanner.scan(profiles: [profile, project], home: home, cutoff: cutoff)
        XCTAssertEqual(rewritten.samples.map(\.id), ["claude:large-session:replacement"])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try scanner.scan(profiles: [profile], home: home, cutoff: cutoff).samples.isEmpty)
    }

    func testOversizedLineCanResumeAcrossBudgetsWithoutLosingLaterUsage() throws {
        let (home, file, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        var data = Data(("{\"type\":\"user\",\"content\":\"" + String(repeating: "x", count: 2_200_000) + "\"}\n").utf8)
        data.append(try usage("after-huge-row")); try data.write(to: file)
        let scanner = ClaudeInsightsScanner(maximumBytesPerFile: 2_162_688), cutoff = Date(timeIntervalSince1970: 0)
        let first = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertTrue(first.historyPending)
        let second = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
        XCTAssertFalse(second.historyPending)
        XCTAssertEqual(second.samples.first?.tokens.total, 110)
        XCTAssertTrue(second.warnings[profile.id]?.contains("could not be read") == true)
    }

    func testLiveClaudeHistoryWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["PROFILEDOCK_VERIFY_CLAUDE_HISTORY"] == "1" else { throw XCTSkip("Opt-in, read-only local history verification") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var profile = Profile(id: "desktop", name: "Assistant", color: "123456"); profile.provider = .claude
        let scanner = ClaudeInsightsScanner(), now = Date(), cutoff = InsightsPeriod.month.start(now: now, calendar: .current)
        var result = InsightsScan(), passes = 0
        repeat {
            result = try scanner.scan(profiles: [profile], home: home, cutoff: cutoff)
            passes += 1
            XCTAssertLessThan(passes, 100, "Large histories must eventually finish")
        } while result.historyPending && passes < 100
        let calendar = Calendar(identifier: .iso8601)
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now)?.start)
        let weekly = result.samples.filter { $0.date >= week }.reduce(Int64(0)) { $0 + $1.tokens.total }
        print("Verified local Claude history: \(passes) passes, \(result.files) files, \(result.samples.count) responses, \(weekly) tokens since Monday")
        XCTAssertFalse(result.historyPending)
        XCTAssertFalse(result.samples.isEmpty)
    }

}
