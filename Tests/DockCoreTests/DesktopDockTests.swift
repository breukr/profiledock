import XCTest
@testable import DockCore

final class DesktopDockTests: XCTestCase {
    func testGroupKeepsOtherPinsInOrderAndReflectsAnyRunningProfile() {
        let entries = [
            DesktopDockEntry(id: "finder", name: "Finder"),
            DesktopDockEntry(id: "profile:a", name: "One", profileID: "a", isChatGPT: true),
            DesktopDockEntry(id: "safari", name: "Safari", isRunning: true),
            DesktopDockEntry(id: "profile:b", name: "Two", profileID: "b", isRunning: true, isChatGPT: true),
            DesktopDockEntry(id: "classic", name: "ChatGPT Classic", isChatGPT: true)
        ]
        let grouped = DesktopDockLayout.items(entries, grouped: true)
        XCTAssertEqual(grouped.map(\.id), ["finder", DesktopDockEntry.groupID, "safari"])
        XCTAssertTrue(grouped[1].isRunning)
        XCTAssertEqual(DesktopDockLayout.items(entries, grouped: false), entries)
        XCTAssertEqual(entries.count, 5)
    }

    func testFamilyRecognitionExcludesUnrelatedAppsAndHelpers() {
        for id in ["com.openai.chat", "com.openai.codex", "com.openai.codex.beta", "nl.breukr.profiledock.launcher.profile-test"] {
            XCTAssertTrue(DesktopDockLayout.isChatGPT(bundleIdentifier: id), id)
        }
        for id in ["nl.breukr.account-dock", "com.example.chatgpt", "com.openai.codex-helper", "com.openai.codex.helper.renderer", ""] {
            XCTAssertFalse(DesktopDockLayout.isChatGPT(bundleIdentifier: id), id)
        }
    }

    func testNoPhantomGroupAndDeduplicatesPinnedRunningApps() {
        let app = DesktopDockEntry(id: "app:path", name: "Editor")
        XCTAssertEqual(DesktopDockLayout.items([app, app], grouped: true), [app])
        XCTAssertEqual(DesktopDockLayout.items([], grouped: true), [])
    }

    func testIconModeRoundTrips() throws {
        for mode in AppIconAppearance.allCases {
            XCTAssertEqual(try JSONDecoder().decode(AppIconAppearance.self, from: JSONEncoder().encode(mode)), mode)
        }
    }
}
