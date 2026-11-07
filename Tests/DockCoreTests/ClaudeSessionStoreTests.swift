import XCTest
@testable import DockCore

final class ClaudeSessionStoreTests: XCTestCase {
    func store() throws -> ClaudeSessionStore {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let store = ClaudeSessionStore(home: home)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        return store
    }
    func write(_ store: ClaudeSessionStore, _ id: String, state: ClaudeSession.State = .idle, age: TimeInterval, now: Date) throws {
        var session = ClaudeSession(id: id, project: "/project", processID: 99_999, processStarted: 1, now: now)
        session.state = state
        let url = store.root.appendingPathComponent(id + ".json")
        try JSONEncoder().encode(session).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testReadKeepsTheNewestFilesWhenCapped() throws {
        let store = try store(), now = Date()
        for (index, id) in ["a", "b", "c", "d", "e"].enumerated() { try write(store, id, age: Double(index) * 60, now: now) }
        XCTAssertEqual(store.read(limit: 2).map(\.id), ["a", "b"])
        XCTAssertEqual(store.read().map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testCacheSkipsUnchangedFilesAndRereadsChangedOnes() throws {
        let store = try store(), cache = ClaudeSessionCache(), now = Date()
        try write(store, "fixture", state: .working, age: 10, now: now)
        XCTAssertEqual(store.read(cache: cache).map(\.state), [.working])
        let url = store.root.appendingPathComponent("fixture.json")
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        // Same size and date: served from the cache without decoding.
        let size = try Data(contentsOf: url).count
        try Data(repeating: UInt8(ascii: " "), count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        XCTAssertEqual(store.read(cache: cache).map(\.state), [.working])
        // A newer write is decoded again.
        try write(store, "fixture", state: .waiting, age: 0, now: now)
        XCTAssertEqual(store.read(cache: cache).map(\.state), [.waiting])
        // A removed file leaves the cache.
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(store.read(cache: cache).isEmpty)
        XCTAssertEqual(cache.count, 0)
    }

    func testPruneRemovesOnlyOldEndedSessionsBeyondTheNewest() throws {
        let store = try store(), now = Date(), week = 7 * 86_400.0
        try write(store, "newest-old-closed", state: .closed, age: week + 10, now: now)  // within `keep`
        try write(store, "recent-closed", state: .closed, age: 3600, now: now)
        try write(store, "old-closed", state: .closed, age: week + 100, now: now)
        try write(store, "old-dead", state: .working, age: week + 200, now: now)
        try write(store, "old-alive", state: .idle, age: week + 300, now: now)
        let junk = store.root.appendingPathComponent("junk.json")
        try Data("future format".utf8).write(to: junk)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-week * 2)], ofItemAtPath: junk.path)
        for id in ["old-closed", "orphan"] {
            let lock = store.root.appendingPathComponent(id + ".lock")
            try Data().write(to: lock)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-week * 2)], ofItemAtPath: lock.path)
        }
        // "recent-closed" is newer than "newest-old-closed", so keep 2 protects both.
        let remaining = store.prune(now: now, keep: 2, isAlive: { $0.id == "old-alive" })
        XCTAssertEqual(remaining, ["newest-old-closed", "recent-closed", "old-alive", "junk"])
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path))
        XCTAssertEqual(files, ["newest-old-closed.json", "recent-closed.json", "old-alive.json", "junk.json"])
    }

    func testPruneLeavesALockedSessionAlone() throws {
        let store = try store(), now = Date()
        try write(store, "busy", state: .closed, age: 30 * 86_400, now: now)
        let descriptor = open(store.root.appendingPathComponent("busy.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        XCTAssertEqual(store.prune(now: now, keep: 0, isAlive: { _ in false }), ["busy"])
    }

    func testPruneOfAMissingFolderReportsNothing() {
        let store = ClaudeSessionStore(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(store.prune())
        XCTAssertTrue(store.read().isEmpty)
    }
}
