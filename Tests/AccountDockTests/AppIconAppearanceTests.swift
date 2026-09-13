import XCTest
import AppKit
import DockCore
@testable import AccountDock

final class AppIconAppearanceTests: XCTestCase {
    @MainActor func testManualDockIconHasNativeMargins() throws {
        let artwork = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { bounds in
            NSColor.white.setFill(); bounds.fill(); return true
        }
        let icon = AppIconImages.dockImage(from: artwork)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide, 512)
        XCTAssertEqual(bitmap.pixelsHigh, 512)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 49, y: 256)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 50, y: 256)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 461, y: 256)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 462, y: 256)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 256, y: 49)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 256, y: 462)).alphaComponent, 0, accuracy: 0.01)
    }

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
