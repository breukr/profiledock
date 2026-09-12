import XCTest
import SQLite3
import DockCore
import Network
import Darwin
@testable import AccountDock

final class ActivityMetadataTests: XCTestCase {
    func testUnreadStaysWithinCurrentLoginLocalHostAndUnarchivedRootThreads() throws {
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": ["current": [ActivityIdentity.localHostKey: ["one", "one", "archived", "subagent"], "remote:elsewhere": ["two"]], "other-account": [ActivityIdentity.localHostKey: ["two"]]]]])
        XCTAssertEqual(ActivityMetadata.unreadIDs(data: data, identity: "current", roots: ["one", "two"]), ["one"])
        XCTAssertEqual(ActivityMetadata.unreadIDs(data: data, identity: "missing", roots: ["one", "two"]), [])
    }
    func testMalformedOrFutureReadStateIsUnknown() throws {
        XCTAssertNil(ActivityMetadata.unreadIDs(data: Data("invalid".utf8), identity: "current", roots: []))
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 2, "unreadByIdentity": [:]]])
        XCTAssertNil(ActivityMetadata.unreadIDs(data: data, identity: "current", roots: ["one"]))
        XCTAssertEqual(ActivityMetadata.unreadIDs(data: Data("{}".utf8), identity: "current", roots: []), [])
    }
    func testNativeIdentityHashAndAccountMismatch() throws {
        let data = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "account", "user_id": "user"]])
        let token = "header." + data.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        let identity = try ActivityIdentity.parse(credential: UsageCredentials(accessToken: token, accountID: "account", identity: "scoped-key"))
        XCTAssertEqual(identity.credentialKey, "scoped-key")
        XCTAssertEqual(ActivityIdentity.localHostKey, "local:092af2cb59bdd804c6f7f1cd1d85464b682974e43cd517397d25510024034d1c")
        XCTAssertThrowsError(try ActivityIdentity.parse(credential: UsageCredentials(accessToken: token, accountID: "another-account", identity: "other")))
        XCTAssertEqual(identity.unreadKey.count, 64)
    }

    @MainActor func testClosedAppNeverCountsStaleInProgressAndLoginChangeClearsUnread() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = Profile(id: "default", name: "Fixture", color: "000000")
        let directory = profile.home(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try database(directory.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT); INSERT INTO threads VALUES ('one',0,'vscode','/root',NULL),('archived',1,'vscode','/root',NULL),('subagent',0,'exec','/root/child',NULL);")
        try database(directory.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT); INSERT INTO thread_turns VALUES ('one',1,'inProgress'),('archived',1,'inProgress'),('subagent',1,'inProgress');")
        try writeAuth(directory, account: "first")
        let identity = try ActivityIdentity.read(profile: profile, home: home)
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: ["one", "archived", "subagent"]]]]])
        try data.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        let metadata = try ActivityMetadata.read(profile: profile, home: home)
        XCTAssertEqual(metadata.roots, ["one"])
        XCTAssertEqual(metadata.candidates, ["one"])
        XCTAssertEqual(metadata.unread, ["one"])
        let monitor = ActivityMonitor(home: home)
        defer { monitor.shutdown() }
        monitor.configure([profile], running: [])
        for _ in 0..<100 where monitor.entries[profile.id]?.unread != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 1)
        XCTAssertEqual(monitor.entries[profile.id]?.working, 0)
        XCTAssertEqual(monitor.entries[profile.id]?.appOpen, false)
        let read = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: []]]]])
        try read.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        for _ in 0..<100 where monitor.entries[profile.id]?.unread != 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 0, "Reading the task in the native app clears the badge")
        try data.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        for _ in 0..<100 where monitor.entries[profile.id]?.unread != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 1)
        try writeAuth(directory, account: "second")
        for _ in 0..<150 where monitor.entries[profile.id]?.unread != 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 0)
        monitor.configure([], running: [])
        XCTAssertTrue(monitor.entries.isEmpty)
    }

    @MainActor func testLiveObserverTracksWorkCompletionUnreadAndUnsubscribes() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/ad-ipc-" + String(UUID().uuidString.prefix(8)))
        let profile = Profile(id: "default", name: "Fixture", color: "000000")
        let directory = profile.home(in: home)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try database(directory.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT); INSERT INTO threads VALUES ('one',0,'vscode','/root',NULL);")
        try database(directory.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT); INSERT INTO thread_turns VALUES ('one',1,'inProgress');")
        // A checkpointed WAL history with no sidecars must still discover the real live owner.
        try removeFixtureWALSidecars(directory.appendingPathComponent("thread_history_1.sqlite"))
        try writeAuth(directory, account: "first")
        let identity = try ActivityIdentity.read(profile: profile, home: home)
        let initial = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: []]]]])
        try initial.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        let server = try ActivityFixtureServer(path: directory.appendingPathComponent("ipc/ipc.sock").path)
        defer { server.stop() }
        await fulfillment(of: [server.listening], timeout: 3)
        let monitor = ActivityMonitor(home: home)
        defer { monitor.shutdown() }
        monitor.configure([profile], running: [profile.id])
        for _ in 0..<150 where monitor.entries[profile.id]?.working != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.working, 1)
        XCTAssertEqual(monitor.entries[profile.id]?.liveAvailable, true)
        server.complete()
        let completion = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: ["one"]]]]])
        try completion.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        for _ in 0..<150 where monitor.entries[profile.id]?.unread != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.working, 0)
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 1)
        // The live stream still has unread=true; native Read all must nevertheless clear the badge.
        try initial.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        for _ in 0..<150 where monitor.entries[profile.id]?.unread != 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 0)
        monitor.shutdown()
        await fulfillment(of: [server.unsubscribed], timeout: 3)
    }

    @MainActor func testSilentHandshakeTimesOutAndReconnectsWithoutAppRestart() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/ad-reconnect-" + String(UUID().uuidString.prefix(8)))
        let profile = Profile(id: "default", name: "Fixture", color: "000000")
        let directory = profile.home(in: home)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("ipc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try database(directory.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT);")
        try writeAuth(directory, account: "fixture")
        let server = try ActivityFixtureServer(path: directory.appendingPathComponent("ipc/ipc.sock").path, ignoreInitializations: 1)
        defer { server.stop() }
        await fulfillment(of: [server.listening], timeout: 3)
        let monitor = ActivityMonitor(home: home)
        defer { monitor.shutdown() }
        monitor.configure([profile], running: [profile.id])
        var sawReconnect = false
        for _ in 0..<650 {
            if monitor.entries[profile.id]?.connectionIssue == .reconnecting { sawReconnect = true }
            if monitor.entries[profile.id]?.liveAvailable == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawReconnect)
        XCTAssertEqual(monitor.entries[profile.id]?.liveAvailable, true)
        XCTAssertNil(monitor.entries[profile.id]?.connectionIssue)
        XCTAssertNil(monitor.event, "Reconnecting must not generate a completion cue")
    }

    @MainActor func testAutomationInboxReadAllOverridesStaleChatFlagsAndWakesMonitor() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = Profile(id: "default", name: "Fixture", color: "000000")
        let directory = profile.home(in: home)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sqlite"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try database(directory.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT); INSERT INTO threads VALUES ('normal',0,'vscode',NULL,NULL),('run',0,'vscode',NULL,'automation'),('old',0,'vscode',NULL,'automation'),('archived-run',0,'vscode',NULL,'automation');")
        let inbox = directory.appendingPathComponent("sqlite/codex-dev.db")
        try database(inbox, sql: "CREATE TABLE automation_runs (thread_id TEXT, read_at INTEGER, status TEXT); INSERT INTO automation_runs VALUES ('run',NULL,'PENDING_REVIEW'),('old',100,'ACCEPTED'),('archived-run',NULL,'ARCHIVED'),('other-account',NULL,'PENDING_REVIEW');")
        try writeAuth(directory, account: "first")
        let identity = try ActivityIdentity.read(profile: profile, home: home)
        let raw = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: ["normal", "run", "old", "archived-run"]]]]])
        try raw.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        XCTAssertEqual(try ActivityMetadata.read(profile: profile, home: home).unread, ["normal", "run"])
        let monitor = ActivityMonitor(home: home)
        defer { monitor.shutdown() }
        monitor.configure([profile], running: [])
        for _ in 0..<100 where monitor.entries[profile.id]?.unread != 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 2)
        // Read all changes only the inbox database; the old per-thread unread bits remain true.
        try database(inbox, sql: "UPDATE automation_runs SET read_at = 200 WHERE read_at IS NULL;")
        for _ in 0..<150 where monitor.entries[profile.id]?.unread != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".codex-global-state.json")), raw)
        try database(inbox, sql: "UPDATE automation_runs SET read_at = NULL WHERE thread_id = 'run';")
        for _ in 0..<150 where monitor.entries[profile.id]?.unread != 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 2)
        try FileManager.default.removeItem(at: inbox)
        XCTAssertNil(try ActivityMetadata.read(profile: profile, home: home).unread)
    }

    func testMissingHistoryWALSidecarsPreservesUnreadAndUsesLiveDiscoveryCandidates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = Profile(id: "default", name: "Fixture", color: "000000")
        let directory = profile.home(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try database(directory.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE threads (id TEXT, archived INTEGER, source TEXT, agent_path TEXT, thread_source TEXT); INSERT INTO threads VALUES ('one',0,'vscode',NULL,NULL),('idle',0,'cli',NULL,NULL),('child',0,'exec','/root/child',NULL),('archived',1,'vscode',NULL,NULL);")
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        try database(history, sql: "CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT); INSERT INTO thread_turns VALUES ('one',1,'inProgress'),('idle',1,'completed');")
        try removeFixtureWALSidecars(history)
        try writeAuth(directory, account: "first")
        let identity = try ActivityIdentity.read(profile: profile, home: home)
        let raw = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": [identity.unreadKey: [ActivityIdentity.localHostKey: ["idle"]]]]])
        try raw.write(to: directory.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        let before = try Data(contentsOf: history)
        let metadata = try ActivityMetadata.read(profile: profile, home: home)
        XCTAssertEqual(metadata.unread, ["idle"])
        XCTAssertTrue(metadata.candidates.contains("one"))
        XCTAssertTrue(metadata.candidates.isSubset(of: ["one", "idle"]))
        XCTAssertEqual(try Data(contentsOf: history), before, "Metadata discovery must not change the database")
    }

    private func removeFixtureWALSidecars(_ path: URL) throws {
        try database(path, sql: "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: path.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
    }

    private func writeAuth(_ directory: URL, account: String) throws {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "fixture-user", "https://api.openai.com/auth": ["chatgpt_account_id": account, "user_id": "fixture-user"]])
        let body = claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let data = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["account_id": account, "access_token": "header.\(body).signature"]])
        try data.write(to: directory.appendingPathComponent("auth.json"), options: .atomic)
    }
    private func database(_ path: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw ActivityReadError.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ActivityReadError.unavailable }
    }
}

/// Synthetic local IPC service; it never touches a real account or starts a task.
private final class ActivityFixtureServer {
    let listening = XCTestExpectation(description: "Local fixture socket ready")
    let unsubscribed = XCTestExpectation(description: "Observer unsubscribed")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "account-dock-test-ipc")
    private var connection: NWConnection?
    private var frames = ActivityFrames()
    private var ignoredInitializations: Int
    init(path: String, ignoreInitializations: Int = 0) throws {
        ignoredInitializations = ignoreInitializations
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { chmod(path, 0o600); self?.listening.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.frames = ActivityFrames()
            self.connection = connection; connection.start(queue: self.queue); self.receive(connection)
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel(); queue.async { self.connection?.cancel() } }
    func complete() {
        queue.async {
            self.send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "fixture-owner", "params": ["conversationId": "one", "hostId": "local", "change": ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]], ["op": "replace", "path": ["hasUnreadTurn"], "value": true]]]]])
        }
    }
    private func send(_ value: [String: Any]) {
        connection?.send(content: try? ActivityFrames.encode(value), completion: .contentProcessed { _ in })
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, let messages = try? self.frames.append(data) {
                for message in messages {
                    let method = message["method"] as? String
                    if method == "initialize" {
                        if self.ignoredInitializations > 0 { self.ignoredInitializations -= 1; continue }
                        self.send(["type": "response", "method": "initialize", "requestId": message["requestId"]!, "resultType": "success", "result": ["clientId": "fixture-observer"]])
                    } else if method == "thread-owner-discovery" {
                        self.send(["type": "response", "method": "thread-owner-discovery", "requestId": message["requestId"]!, "resultType": "success", "handledByClientId": "fixture-owner"])
                    } else if method == "thread-stream-following-changed", let params = message["params"] as? [String: Any] {
                        if params["following"] as? Bool == false { self.unsubscribed.fulfill() }
                        else {
                            self.send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "fixture-owner", "params": ["conversationId": "one", "hostId": "local", "change": ["type": "snapshot", "revision": 1, "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": []], "hasUnreadTurn": false]]]])
                        }
                    } else { XCTFail("Unexpected mutating IPC message: \(method ?? "unknown")") }
                }
            }
            if !complete && error == nil { self.receive(connection) }
        }
    }
}
