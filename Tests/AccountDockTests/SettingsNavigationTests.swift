import XCTest
@testable import AccountDock

final class SettingsNavigationTests: XCTestCase {
    func testSettingsEntryPointsLandOnTheirActualDestination() {
        XCTAssertEqual(SettingsDestination.initial(arguments: []), .profiles)
        XCTAssertEqual(SettingsDestination.initial(arguments: ["--settings"]), .general)
        XCTAssertEqual(SettingsDestination.initial(arguments: ["--settings", "--context-settings"]), .access)
        XCTAssertEqual(SettingsDestination.initial(arguments: ["--search-chats"]), .search)
    }

    func testSettingsCanBeFoundByUserTermsInsteadOfOnlyCategoryNames() {
        func results(_ query: String) -> [SettingsDestination] {
            SettingsDestination.allCases.filter { $0.matches(query) }
        }
        XCTAssertEqual(results("menu bar"), [.general])
        XCTAssertEqual(results("  SOUND  "), [.appearance])
        XCTAssertEqual(results("native icon"), [.icons])
        XCTAssertEqual(results("permissions"), [.access])
        XCTAssertEqual(results("  "), SettingsDestination.allCases)
        XCTAssertTrue(results("dock").contains(.general))
        XCTAssertTrue(results("dock").contains(.icons))
    }
}
