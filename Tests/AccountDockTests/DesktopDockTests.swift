import XCTest
import DockCore
@testable import AccountDock

final class DesktopDockIntegrationTests: XCTestCase {
    func testOlderPreferencesKeepOptInDockAndDefaultGrouping() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"profiles\":[],\"scale\":1}".utf8))
        XCTAssertFalse(old.desktopDockEnabled == true)
        XCTAssertTrue(old.groupChatGPTApps != false)
        XCTAssertEqual(old.appIconAppearance ?? .auto, .auto)
    }

    @MainActor func testProfileProjectionUpdatesWithoutChangingProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(home: home)
        let profiles = [Profile(id: "profile-one", name: "One", color: "377CF6"), Profile(id: "profile-two", name: "Two", color: "377CF6")]
        model.preferences.profiles = profiles
        let store = DesktopDockStore(model: model, observesWorkspace: false)
        defer { store.shutdown() }
        XCTAssertEqual(store.entries.map(\.id), [DesktopDockEntry.groupID])
        model.preferences.groupChatGPTApps = false; store.refresh()
        XCTAssertEqual(store.entries.map(\.profileID), ["profile-one", "profile-two"])
        model.preferences.groupChatGPTApps = true; store.refresh()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(model.preferences.profiles, profiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testNewPreferencesPersistExplicitChoices() throws {
        var preferences = Preferences()
        preferences.desktopDockEnabled = true
        preferences.groupChatGPTApps = false
        preferences.appIconAppearance = .clear
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.desktopDockEnabled, true)
        XCTAssertEqual(restored.groupChatGPTApps, false)
        XCTAssertEqual(restored.appIconAppearance, .clear)
    }
}
