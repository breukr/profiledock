import XCTest
@testable import AccountDock

@MainActor
private final class FakeDockAutoHide: DockAutoHideSettings {
    var value: Bool?
    var writes: [Bool?] = []
    var shouldFail = false
    init(_ value: Bool?) { self.value = value }
    func read() -> Bool? { value }
    func write(_ value: Bool?) throws {
        if shouldFail { throw NSError(domain: "test", code: 1) }
        self.value = value; writes.append(value)
    }
}

final class SystemDockAutoHideTests: XCTestCase {
    @MainActor func testRestoresAbsentAndExplicitOriginalValues() throws {
        for original: Bool? in [nil, false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = FakeDockAutoHide(original)
            let owner = SystemDockAutoHide(directory: directory, settings: settings)
            try owner.apply(true); try owner.apply(true)
            XCTAssertEqual(settings.value, true)
            XCTAssertEqual(settings.writes.count, original == true ? 0 : 1)
            try owner.apply(false)
            XCTAssertEqual(settings.value, original)
        }
    }

    @MainActor func testNextRunRecoversInterruptedChangeAndPreservesExternalOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = FakeDockAutoHide(false)
        try SystemDockAutoHide(directory: directory, settings: settings).apply(true)
        try SystemDockAutoHide(directory: directory, settings: settings).restore()
        XCTAssertEqual(settings.value, false)
        let owner = SystemDockAutoHide(directory: directory, settings: settings)
        try owner.apply(true)
        settings.value = false
        let count = settings.writes.count
        try owner.restore()
        XCTAssertEqual(settings.writes.count, count)
        XCTAssertEqual(settings.value, false)
    }

    @MainActor func testFailureKeepsRecoverySnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = FakeDockAutoHide(false)
        let owner = SystemDockAutoHide(directory: directory, settings: settings)
        settings.shouldFail = true
        XCTAssertThrowsError(try owner.apply(true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-dock-autohide.json").path))
        settings.shouldFail = false
        try owner.restore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-dock-autohide.json").path))
    }
}
