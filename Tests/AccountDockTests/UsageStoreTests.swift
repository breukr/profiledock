import XCTest
import DockCore
@testable import AccountDock

actor FixtureSignInRunner: AccountSigningIn {
    private(set) var calls = 0
    var action: @Sendable () async throws -> Void = {}
    func setAction(_ action: @escaping @Sendable () async throws -> Void) { self.action = action }
    func signIn(_ command: AccountSignInCommand) async throws { calls += 1; try await action() }
}

actor FixtureUsageClient: UsageFetching {
    var identities: [String: String] = [:]
    var failure: UsageLoadError?
    var returnedIdentity: String?
    var paused = false
    private(set) var fetchCalls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func identity(for profile: Profile) async throws -> String { identities[profile.id] ?? profile.id }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot {
        fetchCalls += 1
        if paused { await withCheckedContinuation { continuations.append($0) } }
        if let failure { throw failure }
        return UsageSnapshot(identity: returnedIdentity ?? expectedIdentity, plan: "fixture",
                             windows: [UsageWindow(id: "week", duration: 604800, usedPercent: profile.id == "a" ? 75 : 12, resetsAt: Date().addingTimeInterval(86400))],
                             bankedResets: profile.id == "a" ? 2 : 0, applicableResets: 0, resetExpiries: [], fetchedAt: Date())
    }
    func setIdentity(_ identity: String, for id: String) { identities[id] = identity }
    func setFailure(_ error: UsageLoadError?) { failure = error }
    func setReturnedIdentity(_ value: String) { returnedIdentity = value }
    func setPaused(_ value: Bool) {
        paused = value
        if !value { let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
    }
}

@MainActor
final class UsageStoreTests: XCTestCase {
    private let a = Profile(id: "a", name: "Account A", color: "377CF6")
    private let b = Profile(id: "b", name: "Account B", color: "377CF6")
    private let signInCommand: (Profile, URL) throws -> AccountSignInCommand = { _, _ in
        AccountSignInCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Asynchronous state did not settle", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testConcurrentRefreshesAreCoalescedAndKeepAccountsSeparate() async throws {
        let client = FixtureUsageClient()
        let subject = UsageStore(client: client)
        defer { subject.shutdown() }
        await client.setPaused(true)
        subject.configure([a, b]); subject.refreshAll(); subject.refreshAll(force: true)
        try await eventually { await client.fetchCalls == 2 }
        await client.setPaused(false)
        try await eventually { !subject.isRefreshing }
        XCTAssertEqual(subject.entries[a.id]?.snapshot?.windows.first?.remainingPercent, 25)
        XCTAssertEqual(subject.entries[b.id]?.snapshot?.windows.first?.remainingPercent, 88)
        XCTAssertEqual(subject.entries[a.id]?.snapshot?.bankedResets, 2)
        XCTAssertEqual(subject.entries[b.id]?.snapshot?.bankedResets, 0)
        XCTAssertEqual(subject.cardUsageRows, 1)
        subject.refreshAll()
        XCTAssertEqual(subject.cardUsageRows, 1, "Identity validation must not insert an empty usage row")
        try await eventually { !subject.isRefreshing }
        let calls = await client.fetchCalls
        XCTAssertEqual(calls, 2, "Fresh readings should not start another HTTP request")
    }

    func testChangedIdentityClearsFreshSnapshotAndBypassesAttemptThrottle() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        store.configure([a]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[a.id]?.snapshot?.identity, a.id)
        await client.setIdentity("new-signed-in-user", for: a.id)
        await client.setPaused(true)
        store.refreshAll()
        try await eventually { await client.fetchCalls == 2 }
        XCTAssertNil(store.entries[a.id]?.snapshot, "Old account data must disappear while the new request is pending")
        await client.setPaused(false)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[a.id]?.snapshot?.identity, "new-signed-in-user")
    }

    func testNetworkFailureRetainsStaleReadingButAuthorizationFailureClearsIt() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        store.configure([a]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        let reading = store.entries[a.id]?.snapshot
        await client.setFailure(.network)
        store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[a.id]?.snapshot, reading)
        XCTAssertEqual(store.entries[a.id]?.error, .network)
        await client.setFailure(.authorizationRequired)
        store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertNil(store.entries[a.id]?.snapshot)
        XCTAssertEqual(store.entries[a.id]?.error, .authorizationRequired)
    }

    func testRemovedProfileCannotBeRestoredByLateNetworkResponse() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        await client.setPaused(true)
        store.configure([a]); store.refreshAll()
        try await eventually { await client.fetchCalls == 1 }
        store.configure([])
        await client.setPaused(false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isRefreshing)
    }

    func testSnapshotFromAnotherIdentityIsRejected() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        await client.setReturnedIdentity("different-account")
        store.configure([a]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        XCTAssertNil(store.entries[a.id]?.snapshot)
        XCTAssertEqual(store.entries[a.id]?.error, .wrongAccount)
    }
    func testClaudeRefreshesWhileClosedAndUsesItsOwnClient() async throws {
        let codex = FixtureUsageClient(), claude = FixtureUsageClient()
        let profile = { var p = Profile(id: "claude", name: "Claude", color: "377CF6"); p.provider = .claude; return p }()
        let store = UsageStore(client: codex, claudeClient: claude, backgroundInterval: 0.05)
        defer { store.shutdown() }
        store.configure([profile]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[profile.id]?.snapshot?.identity, "claude")
        await claude.setIdentity("switched-claude-account", for: profile.id)
        try await eventually { store.entries[profile.id]?.snapshot?.identity == "switched-claude-account" }
        let codexCalls = await codex.fetchCalls
        XCTAssertEqual(codexCalls, 0)
        await claude.setFailure(.claudeSignInRequired)
        store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertNil(store.entries[profile.id]?.snapshot)
    }

    func testCompanionActivityCannotOverwriteClaudeAccountMeasurements() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home)
        var profile = a; profile.provider = .claude
        let client = FixtureUsageClient()
        let store = UsageStore(claudeClient: client)
        defer { store.shutdown() }
        store.configure([profile]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        let expected = store.entries[profile.id]?.snapshot
        XCTAssertNotNil(expected)
        store.updateCompanions(model: model)
        XCTAssertEqual(store.entries[profile.id]?.snapshot, expected)
    }

    func testNudgeOncePerAuthFailureEpisodeAndNotForNetworkErrors() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client)
        defer { store.shutdown() }
        var nudges: [String] = []
        store.onConnectionLost = { nudges.append($0.id) }
        store.configure([a])
        await client.setFailure(.network); store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertTrue(nudges.isEmpty)
        await client.setFailure(.authorizationRequired); store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertEqual(nudges, [a.id])
        XCTAssertEqual(store.disconnectedProfiles.map(\.id), [a.id])
        await client.setFailure(nil); store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertTrue(store.disconnectedProfiles.isEmpty)
        await client.setFailure(.notSignedIn); store.refreshAll(force: true)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(nudges, [a.id, a.id])
    }

    func testClaudeNudgeAndReconnectAreSharedAndRestoreAllTiles() async throws {
        let client = FixtureUsageClient(), runner = FixtureSignInRunner()
        var first = a, second = b; first.provider = .claude; second.provider = .claude
        let store = UsageStore(claudeClient: client, signInRunner: runner, signInCommand: signInCommand)
        defer { store.shutdown() }
        var nudges = 0
        store.onConnectionLost = { _ in nudges += 1 }
        store.configure([first, second]); await client.setFailure(.claudeSignInRequired)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        XCTAssertEqual(nudges, 1)
        XCTAssertEqual(store.disconnectedProfiles.count, 1)
        await runner.setAction { try await Task.sleep(for: .milliseconds(20)); await client.setFailure(nil) }
        store.reconnect(first, home: URL(fileURLWithPath: "/tmp")); store.reconnect(second, home: URL(fileURLWithPath: "/tmp"))
        try await eventually { store.reconnecting.isEmpty && store.entries[first.id]?.snapshot != nil && store.entries[second.id]?.snapshot != nil }
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.disconnectedProfiles.isEmpty)
    }

    func testReconnectionFailureCanRetryAndCancelWithoutTouchingAnotherProfile() async throws {
        let client = FixtureUsageClient(), runner = FixtureSignInRunner()
        let store = UsageStore(client: client, signInRunner: runner, signInCommand: signInCommand)
        defer { store.shutdown() }
        store.configure([a, b]); await client.setFailure(.authorizationRequired)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        await runner.setAction { throw AccountSignInError.failed }
        store.reconnect(a, home: URL(fileURLWithPath: "/tmp"))
        try await eventually { !store.isReconnecting(self.a) }
        XCTAssertEqual(store.reconnectionMessages[store.connectionKey(a)], AccountSignInError.failed.message)
        await runner.setAction { try await Task.sleep(for: .seconds(10)) }
        store.reconnect(a, home: URL(fileURLWithPath: "/tmp"))
        store.reconnect(b, home: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(store.isReconnecting(b), "One Codex callback server at a time")
        store.cancelReconnect(a)
        XCTAssertTrue(store.reconnecting.isEmpty)
        XCTAssertNotNil(store.entries[b.id]?.error)
        store.reconnect(a, home: URL(fileURLWithPath: "/tmp"))
        store.configure([b])
        XCTAssertTrue(store.reconnecting.isEmpty, "Removing a profile cancels only its login process")
    }

    func testCodexConnectionIsCheckedInBackground() async throws {
        let client = FixtureUsageClient()
        let store = UsageStore(client: client, backgroundInterval: 0.05)
        defer { store.shutdown() }
        store.configure([a]); store.refreshAll()
        try await eventually { !store.isRefreshing }
        await client.setIdentity("renewed-account", for: a.id)
        try await eventually { store.entries[self.a.id]?.snapshot?.identity == "renewed-account" }
    }

    func testSignInCompletionInvalidatesAnOlderInFlightUsageRequest() async throws {
        let client = FixtureUsageClient(), runner = FixtureSignInRunner()
        let store = UsageStore(client: client, signInRunner: runner, signInCommand: signInCommand)
        defer { store.shutdown() }
        store.configure([a]); await client.setFailure(.authorizationRequired)
        store.refreshAll(force: true); try await eventually { !store.isRefreshing }
        await client.setPaused(true); store.refreshAll(force: true)
        try await eventually { await client.fetchCalls == 2 }
        await runner.setAction {
            await client.setIdentity("renewed-account", for: "a")
            await client.setReturnedIdentity("renewed-account")
            await client.setFailure(nil)
        }
        store.reconnect(a, home: URL(fileURLWithPath: "/tmp"))
        try await eventually { await client.fetchCalls == 3 }
        await client.setPaused(false)
        try await eventually { !store.isRefreshing }
        XCTAssertEqual(store.entries[a.id]?.snapshot?.identity, "renewed-account")
        XCTAssertNil(store.entries[a.id]?.error)
    }

}
