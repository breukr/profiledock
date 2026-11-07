import XCTest
import DockCore
@testable import AccountDock

private final class CodexResponseProtocol: URLProtocol {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isUsage = request.url?.path.hasSuffix("/usage") == true
        if isUsage { Self.requests += 1 }
        let status = isUsage ? (Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()) : 404
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Readings that survive relaunch, stale tokens and wake, and reminders that do not nag.
@MainActor
final class UsageConnectionTests: XCTestCase {
    private var folder: URL!
    private var cacheURL: URL { folder.appendingPathComponent("usage-cache.json") }
    private let claude = { var p = Profile(id: "claude", name: "Claude", color: "377CF6"); p.provider = .claude; return p }()
    private let digest = String(repeating: "0a", count: 32)

    override func setUp() async throws { folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-connection-" + UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Asynchronous state did not settle", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func cachedReading(_ identity: String) -> UsageSnapshot {
        UsageSnapshot(identity: identity, plan: "max", windows: [UsageWindow(id: "five_hour", duration: 18000, usedPercent: 30, resetsAt: Date().addingTimeInterval(3600))],
                      bankedResets: nil, applicableResets: nil, resetExpiries: nil, fetchedAt: Date().addingTimeInterval(-7200))
    }

    func testLaunchShowsCachedReadingAndAStaleTokenOnlyAgesIt() async throws {
        let seed = UsageReadingCache(url: cacheURL)
        let store0 = UsageStore(claudeClient: FixtureUsageClient())
        seed.store(cachedReading(digest), for: store0.connectionKey(claude) + "|" + claude.id)
        let client = FixtureUsageClient()
        await client.setIdentityFailure(.claudeTokenStale)
        let store = UsageStore(claudeClient: client, cache: UsageReadingCache(url: cacheURL))
        defer { store.shutdown() }
        var nudges = 0
        store.onConnectionLost = { _ in nudges += 1 }
        store.configure([claude])
        XCTAssertEqual(store.entries[claude.id]?.snapshot?.identity, digest, "Bars appear before any network request")
        XCTAssertEqual(store.entries[claude.id]?.snapshot?.windows.first?.usedPercent, 30)
        XCTAssertEqual(store.entries[claude.id]?.validatingIdentity, false)
        for _ in 0..<4 { store.refreshAll(force: true); try await eventually { !store.isRefreshing } }
        XCTAssertEqual(store.entries[claude.id]?.snapshot?.windows.first?.usedPercent, 30)
        XCTAssertEqual(store.entries[claude.id]?.error, .claudeTokenStale)
        XCTAssertEqual(nudges, 0)
        XCTAssertTrue(store.signInNotices.isEmpty)
        // The next good reading replaces the cached one on disk.
        await client.setIdentityFailure(nil); await client.setIdentity(digest, for: claude.id)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertGreaterThan(UsageReadingCache(url: cacheURL).reading(for: store.connectionKey(claude) + "|" + claude.id)?.snapshot.fetchedAt ?? .distantPast, Date().addingTimeInterval(-60))
    }

    func testAnotherAccountDiscardsTheCachedReading() async throws {
        let key = "codex:work|work", work = Profile(id: "work", name: "Work", color: "377CF6")
        UsageReadingCache(url: cacheURL).store(cachedReading(digest), for: key)
        let client = FixtureUsageClient()
        await client.setIdentity(String(repeating: "0b", count: 32), for: work.id)
        await client.setPaused(true)
        let store = UsageStore(client: client, cache: UsageReadingCache(url: cacheURL))
        defer { store.shutdown() }
        store.configure([work]); store.refreshAll()
        try await eventually { await client.fetchCalls == 1 }
        XCTAssertNil(store.entries[work.id]?.snapshot, "Another account's reading never stays")
        XCTAssertNil(UsageReadingCache(url: cacheURL).reading(for: key))
        await client.setPaused(false)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(UsageReadingCache(url: cacheURL).reading(for: key)?.identity, String(repeating: "0b", count: 32))
    }

    func testClaudeConnectionChangeAndReconnectKeepTheReading() async throws {
        let client = FixtureUsageClient(), runner = FixtureSignInRunner()
        let store = UsageStore(claudeClient: client, signInRunner: runner, signInCommand: { _, _ in AccountSignInCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:]) })
        defer { store.shutdown() }
        store.configure([claude]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        let reading = store.entries[claude.id]?.snapshot
        XCTAssertNotNil(reading)
        await client.setPaused(true)
        store.claudeConnectionChanged(configDirectory: nil)
        XCTAssertEqual(store.entries[claude.id]?.snapshot, reading, "A reloaded claude.ai page or reconfigured connection keeps the bars")
        await client.setPaused(false)
        try await eventually { !store.isRefreshing }
        await client.setIdentityFailure(.claudeTokenStale)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        await runner.setAction { await client.setIdentityFailure(nil) }
        store.reconnect(claude, home: folder)
        XCTAssertNotNil(store.entries[claude.id]?.snapshot)
        try await eventually { store.reconnecting.isEmpty && store.entries[claude.id]?.error == nil }
        XCTAssertNotNil(store.entries[claude.id]?.snapshot)
    }

    func testNoReminderDuringTheFirstTwoRefreshCycles() async throws {
        let client = FixtureUsageClient()
        await client.setFailure(.authorizationRequired)
        let work = Profile(id: "work", name: "Work", color: "377CF6")
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        var nudges = 0
        store.onConnectionLost = { _ in nudges += 1 }
        store.configure([work])
        for _ in 0..<2 { store.refreshAll(force: true); try await eventually { !store.isRefreshing } }
        XCTAssertEqual(store.entries[work.id]?.error, .authorizationRequired)
        XCTAssertEqual(nudges, 0)
        XCTAssertTrue(store.signInNotices.isEmpty, "No banner while the app is still starting")
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertEqual(nudges, 1)
        XCTAssertEqual(store.signInNotices.map(\.id), [work.id])
    }

    func testWakeWaitsForNetworkAndStaysQuiet() async throws {
        let client = FixtureUsageClient(), waited = Counter()
        let work = Profile(id: "work", name: "Work", color: "377CF6")
        let store = UsageStore(client: client, launchGraceCycles: 0, wakeSettle: 0, waitForNetwork: { _ in waited.increment() })
        defer { store.shutdown() }
        var nudges = 0
        store.onConnectionLost = { _ in nudges += 1 }
        store.configure([work]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        let before = await client.fetchCalls
        await client.setFailure(.network)
        store.handleWake()
        try await eventually { await client.fetchCalls > before }
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(waited.count, 1)
        XCTAssertNil(store.entries[work.id]?.error, "Network errors right after wake are silent")
        XCTAssertNotNil(store.entries[work.id]?.snapshot)
        await client.setFailure(.authorizationRequired)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[work.id]?.error, .authorizationRequired)
        XCTAssertEqual(nudges, 0, "No reminder within a minute of wake")
        XCTAssertTrue(store.signInNotices.isEmpty)
    }

    func testLaterPersistsAcrossRelaunchUntilAGoodReading() async throws {
        let client = FixtureUsageClient()
        await client.setFailure(.authorizationRequired)
        let work = Profile(id: "work", name: "Work", color: "377CF6")
        var nudges = 0
        do {
            let store = UsageStore(client: client, cache: UsageReadingCache(url: cacheURL), launchGraceCycles: 0)
            store.onConnectionLost = { _ in nudges += 1 }
            store.configure([work]); store.refreshAll(force: true)
            try await eventually { !store.isRefreshing }
            XCTAssertEqual(store.signInNotices.map(\.id), [work.id])
            store.dismissNotices()
            XCTAssertTrue(store.signInNotices.isEmpty)
            store.shutdown()
        }
        XCTAssertEqual(nudges, 1)
        let store = UsageStore(client: client, cache: UsageReadingCache(url: cacheURL), launchGraceCycles: 0)
        defer { store.shutdown() }
        store.onConnectionLost = { _ in nudges += 1 }
        store.configure([work]); store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[work.id]?.error, .authorizationRequired)
        XCTAssertTrue(store.signInNotices.isEmpty, "Later is remembered after a relaunch")
        XCTAssertEqual(nudges, 1)
        await client.setFailure(nil)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertTrue(store.dismissedNotices.isEmpty, "A good reading ends Later")
        XCTAssertNil(UsageReadingCache(url: cacheURL).reminder(for: store.connectionKey(work)).snoozedUntil)
    }

    // MARK: Codex soft state

    private func authJSON(expiresIn: TimeInterval, refresh: String?) throws -> Data {
        func part(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        var tokens: [String: Any] = ["access_token": "e30.\(try part(["sub": "fixture-user", "exp": Date().timeIntervalSince1970 + expiresIn])).fixture",
                                     "account_id": "fixture-account", "id_token": "e30.\(try part(["sub": "fixture-user"])).fixture"]
        if let refresh { tokens["refresh_token"] = refresh }
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens])
    }

    func testCodexExpiredOrRefusedTokenWithRefreshTokenIsASoftState() async throws {
        let source = URL(fileURLWithPath: "/fixture/auth.json")
        XCTAssertThrowsError(try UsageCredentials.parse(data: authJSON(expiresIn: -60, refresh: "fixture-refresh"), source: source)) {
            XCTAssertEqual($0 as? UsageLoadError, .codexAppRefreshNeeded)
        }
        XCTAssertThrowsError(try UsageCredentials.parse(data: authJSON(expiresIn: -60, refresh: nil), source: source)) {
            XCTAssertEqual($0 as? UsageLoadError, .authorizationRequired)
        }
        let soft = UsageLoadError.codexAppRefreshNeeded
        XCTAssertFalse(soft.needsSignIn); XCTAssertTrue(soft.offersReconnect); XCTAssertTrue(soft.preservesReading)
        XCTAssertEqual(soft.statusLabel, "Open to refresh")
        XCTAssertEqual(soft.message, "Open this profile once; ChatGPT renews the sign-in itself.")

        // An unexpired token the server refuses twice: soft with a refresh token, a real sign-in without one.
        let profile = Profile(id: "work", name: "Work", color: "377CF6")
        let file = profile.home(in: folder).appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CodexResponseProtocol.self]
        let client = UsageClient(home: folder, session: URLSession(configuration: config))
        for (refresh, expected) in [("fixture-refresh", UsageLoadError.codexAppRefreshNeeded), (nil, .authorizationRequired)] as [(String?, UsageLoadError)] {
            try authJSON(expiresIn: 3600, refresh: refresh).write(to: file)
            CodexResponseProtocol.statuses = [401, 403]; CodexResponseProtocol.requests = 0
            let identity = try await client.identity(for: profile)
            do { _ = try await client.fetch(profile, expectedIdentity: identity); XCTFail("Refused token") }
            catch { XCTAssertEqual(error as? UsageLoadError, expected) }
            XCTAssertEqual(CodexResponseProtocol.requests, 2, "One retry after re-reading auth.json")
        }
        // A refusal followed by success (the app just rotated its token) is no error at all.
        CodexResponseProtocol.statuses = [401, 200]; CodexResponseProtocol.requests = 0
        let identity = try await client.identity(for: profile)
        do { _ = try await client.fetch(profile, expectedIdentity: identity) }
        catch { XCTAssertEqual(error as? UsageLoadError, .invalidResponse, "The empty fixture body only fails parsing") }
    }

    // MARK: Claude web fallback and credential reads

    private let account = Data(#"{"account":{"uuid":"11111111-1111-1111-1111-111111111111"},"organization":{"uuid":"22222222-2222-2222-2222-222222222222"}}"#.utf8)

    func testWebSessionAnswersWhenClaudeCodesTokenIsStale() async throws {
        let identity = ClaudeWebUsage.identity(accountID: "11111111-1111-1111-1111-111111111111", organizationID: "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(try ClaudeUsageAccount.parse(account).identity, identity, "Both sources give a tile the same identity")
        let reading = UsageSnapshot(identity: identity, plan: nil, windows: [UsageWindow(id: "five_hour", duration: 18000, usedPercent: 10, resetsAt: nil)],
                                    bankedResets: nil, applicableResets: nil, resetExpiries: nil, fetchedAt: Date())
        let calls = Counter()
        let stale: ClaudeUsageClient.Credentials = { throw UsageLoadError.claudeTokenStale }
        func client(_ outcome: ClaudeWebUsage.Outcome) -> ClaudeUsageClient {
            ClaudeUsageClient(credentials: stale, resetFetcher: { _ in nil }, webUsage: { _, _ in calls.increment(); return outcome })
        }
        let web = client(.reading(reading))
        let resolved = try await web.identity(for: claude)
        XCTAssertEqual(resolved, identity)
        let fetched = try await web.fetch(claude, expectedIdentity: resolved)
        XCTAssertEqual(fetched, reading)
        XCTAssertEqual(calls.count, 1, "A fresh web reading is reused for the fetch")
        for (outcome, expected) in [(ClaudeWebUsage.Outcome.notConnected, UsageLoadError.claudeTokenStale), (.signedOut, .claudeTokenStale),
                                    (.unavailable, .claudeTokenStale), (.otherAccount, .claudeOtherAccount)] {
            do { _ = try await client(outcome).identity(for: claude); XCTFail("No reading") }
            catch { XCTAssertEqual(error as? UsageLoadError, expected) }
        }
    }

    func testKeychainReadIsReusedAndReReadAfterARefusal() async throws {
        let reads = Counter(), statuses = StatusQueue([200, 200])
        let account = account
        ClaudeStatusProtocol.next = { path in path.hasSuffix("profile") ? (statuses.next(), account) : (200, Data(#"{"five_hour":{"utilization":5,"resets_at":"2027-01-01T00:00:00Z"}}"#.utf8)) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ClaudeStatusProtocol.self]
        let credential = ClaudeUsageCredential(token: "fixture", fingerprint: "fixture", plan: "max")
        let client = ClaudeUsageClient(session: URLSession(configuration: config), credentials: { reads.increment(); return credential }, resetFetcher: { _ in nil },
                                       webUsage: { _, _ in .notConnected }, credentialLifetime: 30)
        let identity = try await client.identity(for: claude)
        _ = try await client.fetch(claude, expectedIdentity: identity)
        XCTAssertEqual(reads.count, 1, "One Keychain read per 30 seconds instead of one per check")
        await client.invalidate()
        statuses.set([401, 401])
        let fresh = ClaudeUsageClient(session: URLSession(configuration: config), credentials: { reads.increment(); return credential }, resetFetcher: { _ in nil },
                                      webUsage: { _, _ in .notConnected }, credentialLifetime: 30)
        let before = reads.count
        do { _ = try await fresh.identity(for: claude); XCTFail("Refused twice") }
        catch { XCTAssertEqual(error as? UsageLoadError, .claudeSignInRequired) }
        XCTAssertEqual(reads.count - before, 2, "A refusal re-reads the Keychain before the single retry")
    }
}

private final class StatusQueue: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func set(_ values: [Int]) { lock.lock(); self.values = values; lock.unlock() }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; return values.isEmpty ? 200 : values.removeFirst() }
}

private final class ClaudeStatusProtocol: URLProtocol {
    nonisolated(unsafe) static var next: ((String) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.next!(request.url!.path)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
