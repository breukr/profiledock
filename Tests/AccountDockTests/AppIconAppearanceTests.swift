import XCTest
import DockCore
@testable import AccountDock

final class AppIconAppearanceTests: XCTestCase {
    func testOldPreferencesDefaultToAutomaticIcon() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"profiles":[],"scale":1}"#.utf8))
        XCTAssertEqual(prefs.appIconAppearance ?? .auto, .auto)
    }
    func testRemovedDockPreferencesAreIgnoredWhileKeepingProfilesAndIcon() throws {
        let data = Data(#"{"profiles":[{"id":"profile-one","name":"One","color":"377CF6"}],"scale":1,"desktopDockEnabled":true,"desktopDockAutoHideSystem":true,"groupChatGPTApps":false,"appIconAppearance":"dark"}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(prefs.profiles.map(\.id), ["profile-one"])
        XCTAssertEqual(prefs.appIconAppearance, .dark)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Any])
        for key in ["desktopDockEnabled", "desktopDockAutoHideSystem", "groupChatGPTApps"] { XCTAssertNil(saved[key]) }
    }
    func testEveryIconChoicePersists() throws {
        for mode in AppIconAppearance.allCases {
            var prefs = Preferences()
            prefs.appIconAppearance = mode
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
            XCTAssertEqual(restored.appIconAppearance, mode)
        }
    }
}
