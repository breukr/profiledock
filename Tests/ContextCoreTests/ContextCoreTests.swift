import XCTest
import SQLite3
import DockCore
@testable import ContextCore

final class ContextCoreTests: XCTestCase {
    func testKeywordModesUseTitleAndBodyAndQuotedPhrasesStayTogether() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("full", title: "Workshop planning")
        try f.item("full", ordinal: 1, type: "userMessage", text: "The budget was approved at Café Noord.")
        try f.thread("partial", title: "Different topic")
        try f.item("partial", ordinal: 1, type: "userMessage", text: "Workshop ideas for next year.")
        XCTAssertEqual(try f.service.search(query: "please find our earlier conversation about workshop budget", sources: ["two"]).hits.map(\.thread.id), ["full"])
        XCTAssertEqual(try f.service.search(query: "workshop budget", sources: ["two"], mode: .anyWord).hits.count, 2)
        XCTAssertEqual(try f.service.search(query: "\"CAFE NOORD\"", sources: ["two"]).hits.map(\.thread.id), ["full"])
        XCTAssertTrue(try f.service.search(query: "\"budget approved\"", sources: ["two"]).hits.isEmpty)
        XCTAssertEqual(try f.service.search(query: "budget was approved", sources: ["two"], mode: .exactPhrase).hits.count, 1)
    }

    func testOwnHistorySearchDoesNotGrantAccessToAnotherProfile() throws {
        let f = try ContextFixture(); defer { f.remove() }
        try f.thread("own"); try f.item("own", ordinal: 1, type: "userMessage", text: "My workshop budget")
        let own = ContextService(registry: f.registry, caller: "two")
        XCTAssertEqual(try own.search(query: "budget", sources: ["two"]).hits.first?.profile.id, "two")
        XCTAssertEqual(try own.read(source: "two", threadID: "own").messages.count, 1)
        XCTAssertTrue(try own.availableProfiles().isEmpty)
        XCTAssertTrue(try f.registry.access().grants.isEmpty)
        XCTAssertThrowsError(try f.service.search(query: "budget", sources: ["two"]))
    }

    @MainActor func testCancelledSearchStopsBeforeReadingProfiles() async throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        let service = f.service
        let work = Task { try service.search(query: "budget", sources: ["two"]) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled search should not return results") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
    func testAliasesAndDirectionalAccess() throws {
        let fixture = try ContextFixture(); defer { fixture.remove() }
        XCTAssertEqual(try fixture.registry.resolve("@worktwo", in: fixture.registry.profiles()).id, "two")
        XCTAssertThrowsError(try ContextService(registry: fixture.registry, caller: "default").search(query: "contract", sources: ["two"]))
        try fixture.allow("default", "two")
        XCTAssertEqual(try ContextService(registry: fixture.registry, caller: "default").availableProfiles().map(\.id), ["two"])
        XCTAssertThrowsError(try ContextService(registry: fixture.registry, caller: "two").search(query: "contract", sources: ["default"]))
    }

    func testSearchFiltersInjectedReasoningToolsAndChildrenAndCitesOriginalMessages() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root", title: "Project agreement")
        try f.item("root", ordinal: 1, type: "userMessage", text: "The contract starts in October.")
        try f.item("root", ordinal: 2, type: "agentMessage", text: "The contract is a draft.", phase: "final_answer")
        try f.item("root", ordinal: 3, type: "agentMessage", text: "contract hidden reasoning", phase: "analysis")
        try f.item("root", ordinal: 4, type: "userMessage", text: "# AGENTS.md instructions\ncontract injected")
        try f.item("root", ordinal: 5, type: "commandExecution", text: "contract tool output")
        try f.thread("child", title: "contract child", source: "vscode", agentPath: "/root/worker")
        try f.item("child", ordinal: 1, type: "userMessage", text: "contract child")
        try f.thread("guardian", title: "contract reviewer", source: "{\"subagent\":{\"other\":\"guardian\"}}")
        try f.item("guardian", ordinal: 1, type: "userMessage", text: "contract approval")
        let result = try f.service.search(query: "contract", sources: ["@worktwo"])
        XCTAssertEqual(result.coverage[0].status, "available")
        XCTAssertEqual(result.coverage[0].conversationsRead, 1)
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertTrue(result.hits.allSatisfy { $0.thread.id == "root" && $0.profile.id == "two" })
        XCTAssertTrue(result.hits.allSatisfy { $0.citation.contains("Work Two") })
        XCTAssertFalse(result.hits.contains { $0.excerpt.contains("hidden") || $0.excerpt.contains("injected") })
    }

    func testExistingServerHonorsRevocationAndRejectsCallerSpoofing() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root"); try f.item("root", ordinal: 1, type: "userMessage", text: "contract")
        let mcp = ContextMCP(service: f.service)
        let initialize = mcp.response(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertNotNil(initialize?["result"])
        XCTAssertNoThrow(try mcp.call("search_sessions", arguments: ["query": "contract", "profiles": ["two"]]))
        XCTAssertThrowsError(try mcp.call("search_sessions", arguments: ["query": "contract", "profiles": ["private"], "caller": "private"]))
        var access = try f.registry.access(); access.set(caller: "default", source: "two", allowed: false); try f.registry.save(access)
        XCTAssertThrowsError(try mcp.call("read_session", arguments: ["profile": "two", "session_id": "root"]))
        XCTAssertThrowsError(try mcp.call("search_sessions", arguments: ["query": "contract", "profiles": ["two"]]))
    }

    func testFocusAndPaginationHaveNoSkippedOrDuplicatedMessages() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root")
        for index in 1...12 { try f.item("root", ordinal: index, type: "userMessage", text: "Visible message \(index)") }
        let first = try f.service.read(source: "two", threadID: "root", limit: 5)
        XCTAssertEqual(first.messages.map(\.ordinal), [1,2,3,4,5]); XCTAssertEqual(first.nextCursor, "5")
        let second = try f.service.read(source: "two", threadID: "root", cursor: first.nextCursor, limit: 5)
        XCTAssertEqual(second.messages.map(\.ordinal), [6,7,8,9,10])
        let last = try f.service.read(source: "two", threadID: "root", cursor: second.nextCursor, limit: 5)
        XCTAssertEqual(last.messages.map(\.ordinal), [11,12]); XCTAssertNil(last.nextCursor)
        let focused = try f.service.read(source: "two", threadID: "root", messageID: "item-8", limit: 5)
        XCTAssertEqual(focused.messages.map(\.ordinal), [5,6,7,8,9]); XCTAssertEqual(focused.nextCursor, "9")
        XCTAssertEqual(try f.service.read(source: "two", threadID: "root", messageID: "item-8", limit: 1).messages.map(\.ordinal), [8])
    }

    func testLegacyHistoryConfinementAndCursor() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        let url = f.root.appendingPathComponent("sessions/example.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for index in 1...7 {
            let row: [String: Any] = ["type": "response_item", "timestamp": "2026-09-01T10:00:0\(index)Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "contract message \(index)"]]]]
            data += try JSONSerialization.data(withJSONObject: row); data.append(10)
        }
        try data.write(to: url)
        try f.thread("legacy", mode: "legacy", rollout: url.path)
        let first = try f.service.read(source: "two", threadID: "legacy", limit: 3)
        let second = try f.service.read(source: "two", threadID: "legacy", cursor: first.nextCursor, limit: 3)
        XCTAssertEqual(first.messages.map(\.text), ["contract message 1", "contract message 2", "contract message 3"])
        XCTAssertEqual(second.messages.map(\.text), ["contract message 4", "contract message 5", "contract message 6"])
        try f.thread("escape", mode: "legacy", rollout: f.home.appendingPathComponent(".codex-private/session.jsonl").path)
        XCTAssertThrowsError(try f.service.read(source: "two", threadID: "escape"))
    }

    func testClosedWALReadCreatesNoSourceSidecarsAndHandlesEmptyHistory() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root"); try f.item("root", ordinal: 1, type: "userMessage", text: "contract")
        for name in ["state_5.sqlite", "thread_history_1.sqlite"] {
            try f.sql(f.root.appendingPathComponent(name), "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        let main = try Data(contentsOf: f.root.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(try f.service.search(query: "contract", sources: ["two"]).hits.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state_5.sqlite")), main)
        try f.thread("empty")
        XCTAssertTrue(try f.service.read(source: "two", threadID: "empty").messages.isEmpty)
    }

    func testLiveWALIsReadWithoutDroppingRecentRecords() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root")
        let url = f.root.appendingPathComponent("thread_history_1.sqlite")
        try f.item("root", ordinal: 1, type: "userMessage", text: "older message")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        try f.item("root", ordinal: 2, type: "userMessage", text: "contract only in WAL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertEqual(try f.service.search(query: "contract", sources: ["two"]).hits.first?.message.id, "item-2")
    }

    func testCoverageReportsMissingAndFutureStoresInsteadOfClaimingEmpty() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two"); try f.allow("default", "private")
        try f.thread("future", mode: "future-storage")
        let result = try f.service.search(query: "contract", sources: ["two", "private"])
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.coverage.map(\.status), ["unavailable", "unavailable"])
        XCTAssertTrue(result.coverage[0].detail.contains("newer history"))
    }

    func testDateArchiveScopeAndRedaction() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root", archived: true)
        try f.item("root", ordinal: 1, type: "userMessage", text: "contract sk-abcdefghijklmnopqrstuvwxyz012345", timestamp: 100)
        try f.item("root", ordinal: 2, type: "userMessage", text: "new contract", timestamp: 200)
        XCTAssertTrue(try f.service.search(query: "contract", sources: ["two"], includeArchived: false).hits.isEmpty)
        let result = try f.service.search(query: "contract", sources: ["two"], since: 150)
        XCTAssertEqual(result.hits.count, 1); XCTAssertEqual(result.hits[0].message.id, "item-2")
        let messages = try f.service.read(source: "two", threadID: "root").messages
        XCTAssertTrue(messages[0].text.contains("[REDACTED CREDENTIAL]")); XCTAssertFalse(messages[0].text.contains("sk-"))
    }

    func testAmbiguousAliasesAndMalformedPolicyFailClosed() throws {
        let f = try ContextFixture(); defer { f.remove() }
        let profiles = [ContextProfile(Profile(id: "a", name: "Work Two", color: "")), ContextProfile(Profile(id: "b", name: "Work-Two", color: ""))]
        XCTAssertThrowsError(try f.registry.resolve("@worktwo", in: profiles))
        XCTAssertEqual(try f.registry.resolve("a", in: profiles).id, "a")
        try f.registry.createPrivateDirectory()
        try Data("{\"version\":2,\"grants\":{}}".utf8).write(to: f.registry.accessURL)
        XCTAssertThrowsError(try f.service.availableProfiles())
    }

    func testMCPValidatesJSONNumbersAndNotifications() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two"); try f.thread("root")
        try f.item("root", ordinal: 1, type: "userMessage", text: "contract", timestamp: Date().timeIntervalSince1970)
        let mcp = ContextMCP(service: f.service)
        XCTAssertNotNil(mcp.response(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?["error"])
        _ = mcp.response(to: ["jsonrpc": "2.0", "id": 2, "method": "initialize"])
        XCTAssertNil(mcp.response(to: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let args = try JSONSerialization.jsonObject(with: Data(#"{"query":"contract","profiles":["two"],"limit":1,"include_archived":true}"#.utf8)) as! [String: Any]
        XCTAssertNoThrow(try mcp.call("search_sessions", arguments: args))
        XCTAssertThrowsError(try mcp.call("search_sessions", arguments: ["query": "contract", "profiles": ["two"], "limit": true]))
        XCTAssertThrowsError(try mcp.call("search_sessions", arguments: ["query": "contract", "profiles": ["two"], "include_archived": 1]))
    }

    func testLongMessageAndMissingLiveSidecarAreExplicitlyPartialOrUnavailable() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        try f.thread("root"); try f.item("root", ordinal: 1, type: "userMessage", text: "contract " + String(repeating: "long ", count: 4000))
        XCTAssertEqual(try f.service.search(query: "contract", sources: ["two"]).coverage[0].status, "partial")
        let wal = URL(fileURLWithPath: f.root.appendingPathComponent("state_5.sqlite").path + "-wal")
        try Data([1,2,3]).write(to: wal)
        XCTAssertEqual(try f.service.search(query: "contract", sources: ["two"]).coverage[0].status, "unavailable")
    }

    func testFocusedMatchSurvivesResponseBudget() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two"); try f.thread("root")
        for index in 1...5 { try f.item("root", ordinal: index, type: "userMessage", text: "message \(index) " + String(repeating: "context ", count: 1400)) }
        let focused = try f.service.read(source: "two", threadID: "root", messageID: "item-4")
        XCTAssertTrue(focused.messages.contains { $0.id == "item-4" })
        XCTAssertLessThanOrEqual(focused.messages.reduce(0) { $0 + $1.text.count }, 28000)
    }
}

final class ContextFixture {
    let home: URL
    let registry: ContextRegistry
    var root: URL { home.appendingPathComponent(".codex-two") }
    var service: ContextService { ContextService(registry: registry, caller: "default") }
    init() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("context-test-" + UUID().uuidString)
        registry = ContextRegistry(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Account Dock"), withIntermediateDirectories: true)
        let profiles = [Profile(id: "default", name: "Work One", color: "000000"), Profile(id: "two", name: "Work Two", color: "000000"), Profile(id: "private", name: "Private", color: "000000")]
        for profile in profiles { try FileManager.default.createDirectory(at: profile.home(in: home), withIntermediateDirectories: true) }
        struct Preferences: Encodable { let profiles: [Profile] }
        try JSONEncoder().encode(Preferences(profiles: profiles)).write(to: home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json"))
    }
    func allow(_ caller: String, _ source: String) throws { var access = try registry.access(); access.set(caller: caller, source: source, allowed: true); try registry.save(access) }
    func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ContextError.message("Fixture database open failed") }; defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ContextError.message(String(cString: sqlite3_errmsg(db))) }
    }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    func thread(_ id: String, title: String = "Example", source: String = "vscode", agentPath: String = "/root", archived: Bool = false, mode: String = "paginated", rollout: String = "") throws {
        try sql(root.appendingPathComponent("state_5.sqlite"), "CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY,name TEXT,title TEXT,updated_at INTEGER,archived INTEGER,source TEXT,agent_path TEXT,thread_source TEXT,rollout_path TEXT,history_mode TEXT); INSERT INTO threads VALUES (\(quote(id)),NULL,\(quote(title)),2000000000,\(archived ? 1 : 0),\(quote(source)),\(quote(agentPath)),'user',\(quote(rollout)),\(quote(mode)));")
    }
    func item(_ thread: String, ordinal: Int, type: String, text: String, phase: String? = nil, timestamp: Double = 1800000000) throws {
        var item: [String: Any] = ["type": type, "id": "item-\(ordinal)"]
        if type == "userMessage" { item["content"] = [["type": "text", "text": text]] } else { item["text"] = text }
        if let phase { item["phase"] = phase }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
        try sql(root.appendingPathComponent("thread_history_1.sqlite"), "CREATE TABLE IF NOT EXISTS thread_items (thread_id TEXT,item_id TEXT,item_json TEXT,created_at_ms INTEGER,rollout_ordinal INTEGER,item_type TEXT); CREATE INDEX IF NOT EXISTS by_thread ON thread_items(thread_id,rollout_ordinal); INSERT INTO thread_items VALUES (\(quote(thread)),'item-\(ordinal)',\(quote(json)),\(Int64(timestamp * 1000)),\(ordinal),\(quote(type)));")
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
}
