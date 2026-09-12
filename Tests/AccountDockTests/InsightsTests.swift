import XCTest
import SwiftUI
import DockCore
@testable import AccountDock

final class InsightsTests: XCTestCase {
    private let origin = "2026-09-12T10:00:00Z"
    private func line(_ type: String, _ payload: [String: Any], timestamp: String = "2026-09-12T10:01:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": timestamp, "payload": payload])
    }
    private func count(_ input: Int, _ output: Int = 10) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output, "reasoning_output_tokens": output / 2]
    }
    private func event(total: Int, last: Int, output: Int = 10, lastOutput: Int = 10, timestamp: String = "2026-09-12T10:01:00Z") throws -> Data {
        try line("event_msg", ["type": "token_count", "info": ["total_token_usage": count(total, output), "last_token_usage": count(last, lastOutput)]], timestamp: timestamp)
    }
    private func parser() throws -> InsightRolloutParser {
        let parser = InsightRolloutParser(profileID: "personal", cutoff: .distantPast)
        parser.consume(try line("session_meta", ["id": "session", "timestamp": origin]))
        parser.consume(try line("turn_context", ["model": "gpt-6-astra", "turn_id": "turn"]))
        return parser
    }
    func testRepeatedEventsAndCounterResetCountOnlyNewRequests() throws {
        let p = try parser()
        p.consume(try event(total: 100, last: 100))
        p.consume(try event(total: 100, last: 100, timestamp: "2026-09-12T10:01:01Z"))
        p.consume(try event(total: 200, last: 100, output: 20))
        p.consume(try event(total: 100, last: 100, timestamp: "2026-09-12T10:01:02Z"))
        p.consume(try event(total: 50, last: 50))
        XCTAssertEqual(p.samples.count, 3)
        XCTAssertEqual(p.samples.reduce(0) { $0 + $1.tokens.total }, 280)
        XCTAssertTrue(p.samples.allSatisfy { $0.estimatedCost != nil })
    }
    func testForkedHistoryAndFirstCumulativeSnapshotAreNotRebilled() throws {
        let p = try parser()
        p.consume(try event(total: 10_000, last: 100, output: 1_000, timestamp: "2026-09-11T10:00:00Z"))
        p.consume(try event(total: 10_100, last: 100, output: 1_010))
        XCTAssertEqual(p.samples.count, 1)
        XCTAssertEqual(p.samples.first?.tokens.total, 110)
        let first = try parser()
        first.consume(try event(total: 99_000, last: 100, output: 500))
        XCTAssertEqual(first.samples.first?.tokens.total, 110)
        XCTAssertTrue(first.incomplete)
    }
    func testMissingRequestsKeepTokenTotalsButDoNotInventACost() throws {
        let p = try parser()
        p.consume(try event(total: 100, last: 100))
        p.consume(try event(total: 500, last: 100, output: 50))
        XCTAssertEqual(p.samples.last?.tokens.total, 440)
        XCTAssertNil(p.samples.last?.estimatedCost)
        XCTAssertTrue(p.incomplete)
        p.consume(try line("turn_context", ["model": "unpriced-model"]))
        p.consume(try event(total: 600, last: 100, output: 60))
        XCTAssertNil(p.samples.last?.estimatedCost)
    }
    func testTranscriptTextCannotImpersonateCounterMetadata() throws {
        let p = try parser()
        p.consume(try line("response_item", ["type": "message", "content": "token_count session_meta turn_context"] ))
        p.consume(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": count(-1), "last_token_usage": count(-1)]]))
        XCTAssertTrue(p.samples.isEmpty)
    }
    func testScannerResumesPartialAppendAndDoesNotDuplicateSharedFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        var data = try line("session_meta", ["id": "session", "timestamp": origin]); data.append(10)
        data.append(try line("turn_context", ["model": "gpt-6-astra"])); data.append(10)
        let first = try event(total: 100, last: 100)
        data.append(first.prefix(20)); try data.write(to: file)
        let scanner = InsightsScanner(), profiles = [Profile(id: "default", name: "Personal", color: "377CF6")]
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z"))
        let initial = try await scanner.scan(profiles: profiles, home: home, now: now)
        XCTAssertTrue(initial.samples.isEmpty)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: first.dropFirst(20) + Data([10])); try handle.close()
        let loaded = try await scanner.scan(profiles: profiles, home: home, now: now)
        XCTAssertEqual(loaded.samples.count, 1)
        let again = try await scanner.scan(profiles: profiles, home: home, now: now)
        XCTAssertEqual(again.samples.count, 1)
    }

    @MainActor func testRenderNativeInsights() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_INSIGHTS"] else { throw XCTSkip("Opt-in native insights previews") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home)
        model.preferences.profiles = [Profile(id: "default", name: "Personal", color: "377CF6"), Profile(id: "work", name: "Work", color: "955CE5"), Profile(id: "research", name: "Research & learning", color: "377CF6"), Profile(id: "studio", name: "Studio", color: "377CF6"), Profile(id: "side", name: "Side projects", color: "377CF6")]
        let now = Date(), calendar = Calendar.current
        let samples = (0..<7).flatMap { day in ["default", "work", "research", "studio", "side"].enumerated().map { index, profileID -> InsightSample in
            let factor = index == 0 ? day + 1 : 7 - day
            let tokens = InsightTokens(input: Int64(factor * 700_000), cached: Int64(factor * 400_000), output: Int64(factor * 8_000))
            return InsightSample(id: "fixture-\(profileID)-\(day)", profileID: profileID, sessionID: "session-\(profileID)-\(day)",
                date: calendar.date(byAdding: .day, value: -day, to: now)!, model: "gpt-6-astra", tokens: tokens,
                estimatedCost: InsightPricing.estimate(model: "gpt-6-astra", tokens: tokens))
        } }
        let store = InsightsStore(snapshot: InsightsScan(samples: samples), lastUpdated: now)
        for width in [488.0, 680.0, 1000.0] {
            for scheme in [ColorScheme.dark, .light] {
                let view = InsightsPanel(model: model, store: store, compact: width < 500, active: false)
                    .frame(width: width).padding(20).background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
                _ = NSApplication.shared
                let hosting = NSHostingView(rootView: view)
                let size = hosting.fittingSize
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                hosting.frame = CGRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let destination = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("insights-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }

    @MainActor func testRenderAdaptiveProfileWidgets() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_INSIGHTS"] else { throw XCTSkip("Opt-in adaptive widget previews") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), usage = UsageStore(), activity = ActivityMonitor(home: home)
        defer { usage.shutdown(); activity.shutdown() }
        model.preferences.profiles = (0..<12).map { Profile(id: "preview-\($0)", name: "Account \($0 + 1)", color: "377CF6") }
        let presentation = IslandPresentation(expanded: true)
        for width in [420.0, 740.0, 1200.0] {
            presentation.profileColumns = WidgetSizing.columns(count: 12, available: width - 32, scale: 1)
            presentation.profileRows = 1
            let view = IslandView(model: model, usage: usage, activity: activity, insights: InsightsStore(), presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in })
                .frame(width: width, height: 390).background(.black)
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let size = CGSize(width: width, height: 390)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("widgets-\(Int(width)).png"))
            window.close()
        }
    }

    func testLiveLocalScanWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PROFILEDOCK_SCAN_LOCAL_INSIGHTS"] == "1" else { throw XCTSkip("Opt-in local scan; never run on CI") }
        let start = Date(), scanner = InsightsScanner()
        let profiles = try ProfileCatalog.discover(home: FileManager.default.homeDirectoryForCurrentUser)
        let result = try await scanner.scan(profiles: profiles, home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
        print("Local insight scan: \(result.files) files, \(result.samples.count) counter records, \(result.warnings.count) profiles with coverage notes, \(Date().timeIntervalSince(start)) seconds")
        XCTAssertTrue(result.samples.allSatisfy { $0.tokens.valid && ($0.estimatedCost == nil || $0.estimatedCost!.isFinite) })
        let next = Date()
        let incremental = try await scanner.scan(profiles: profiles, home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
        print("Incremental insight scan: \(Date().timeIntervalSince(next)) seconds, \(incremental.bytesRead) new bytes")
        let restoredScanner = InsightsScanner(), restoreStart = Date()
        let restored = await restoredScanner.cachedSnapshot(profiles: profiles, home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
        XCTAssertNotNil(restored)
        print("Restored statistics: \(Date().timeIntervalSince(restoreStart)) seconds")
        let resumed = try await restoredScanner.scan(profiles: profiles, home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
        print("Restarted incremental scan: \(resumed.bytesRead) new bytes")
    }
}
