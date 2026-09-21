import XCTest
import DockCore
import ContextCore
@testable import AccountDock

final class ContextSettingsStoreTests: XCTestCase {
    @MainActor func testSearchSourcesPersistAcrossNavigationAndFollowCallerPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = [Profile(id: "default", name: "Studio", color: "377CF6"), Profile(id: "research", name: "Research", color: "009B87")]
        for profile in profiles { try FileManager.default.createDirectory(at: profile.home(in: root), withIntermediateDirectories: true) }
        let model = DockModel(home: root); model.preferences.profiles = profiles; model.save()
        let registry = ContextRegistry(home: root)
        var access = ContextAccess(); access.set(caller: "default", source: "research", allowed: true); try registry.save(access)
        let store = model.contextSettings
        XCTAssertEqual(store.sources, ["default", "research"])
        store.sources = ["research"]; store.query = "workshop"; store.refresh()
        XCTAssertEqual(store.sources, ["research"])
        XCTAssertEqual(store.query, "workshop")
        XCTAssertTrue(model.contextSettings === store)
        store.selectCaller("research", check: false)
        XCTAssertEqual(store.sources, ["research"], "Reverse access must not be inferred")
        store.selectCaller("default", check: false)
        access.set(caller: "default", source: "research", allowed: false); try registry.save(access)
        store.refresh()
        XCTAssertEqual(store.sources, ["default"])
        XCTAssertTrue(store.allowed.isEmpty)
        XCTAssertNil(store.result)
    }
}
