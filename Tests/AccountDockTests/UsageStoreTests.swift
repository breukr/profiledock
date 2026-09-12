import XCTest
import DockCore
@testable import AccountDock

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
}
