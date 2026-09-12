import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class AppManagementTests: XCTestCase {
    func testAtomicSwapRetainsOldAppAndCanRollBackWithoutTouchingOtherApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Current.app"), new = root.appendingPathComponent("Prepared.app"), other = root.appendingPathComponent("Other.app")
        for (url, content) in [(old, "old"), (new, "new"), (other, "unselected")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url.appendingPathComponent("marker"))
        }
        try AppReplacement.swap(prepared: new, destination: old)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker")), "new")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("marker")), "old")
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("marker")), "unselected")
        try AppReplacement.swap(prepared: new, destination: old)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker")), "old")
    }
    @MainActor func testManagedProfilesPersistAndRemovedImportsStayHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [".codex", ".codex-profile-example"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true) }
        let model = DockModel(home: root)
        let managed = Profile(id: "profile-example", name: "Work", color: "377CF6")
        model.preferences.profiles.append(managed); model.save()
        let reloaded = DockModel(home: root)
        XCTAssertTrue(reloaded.preferences.profiles.contains(managed))
        let stock = try XCTUnwrap(reloaded.preferences.profiles.first { $0.id == "default" })
        try reloaded.removeProfile(stock, trashData: false)
        XCTAssertFalse(DockModel(home: root).preferences.profiles.contains { $0.id == "default" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
        let restore = DockModel(home: root)
        restore.restoreImportedProfiles()
        XCTAssertTrue(restore.preferences.profiles.contains { $0.id == stock.id && $0.name == stock.name })
    }
    @MainActor func testImportedProfileDataCannotBeTrashedByManager() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let model = DockModel(home: root)
        XCTAssertThrowsError(try model.removeProfile(model.preferences.profiles[0], trashData: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
    }
    func testNonVendorAppIsRejectedBeforeCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("copy.app")
        XCTAssertThrowsError(try AppFiles.copyVendorApp(from: URL(fileURLWithPath: "/System/Applications/Calculator.app"), to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
