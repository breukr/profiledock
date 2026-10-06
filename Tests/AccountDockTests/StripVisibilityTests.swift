import XCTest
import DockCore
@testable import AccountDock

extension CompanionIntegrationTests {
    @MainActor func testHiddenProfilesLeaveTheStripButKeepTheirDataAndOrder() throws {
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Claude", project: nil)
        try model.createCompanion(kind: .claudeCode, name: "Project", project: nil)
        model.companions.terminalStarted = 42
        model.companions.windows = [TerminalWindow(windowID: 1, tty: "/dev/ttys001", title: "Fixture", selected: true, front: true, agent: .codex)]
        model.reconcileDiscoveredTerminals()
        let claude = model.preferences.profiles[0].id, terminal = try XCTUnwrap(model.preferences.profiles.first { $0.discoveredTerminal == true }).id
        let order = model.preferences.profiles.map(\.id)
        XCTAssertEqual(model.displayedProfiles.map(\.id), [claude, terminal])

        model.setShownInStrip(claude, false)
        model.setShownInStrip(terminal, false)
        XCTAssertTrue(model.displayedProfiles.isEmpty)
        XCTAssertFalse(model.activityProfiles.contains { $0.id == claude })
        XCTAssertFalse(model.stripProfiles.contains { $0.id == claude })
        // Hiding never removes the profile, its folder or its place in the order.
        XCTAssertEqual(model.preferences.profiles.map(\.id), order)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.preferences.profiles[0].home(in: model.home).path))
        XCTAssertFalse(model.preferences.hiddenProfileIDs?.contains(claude) ?? false)

        let restored = DockModel(home: model.home)
        XCTAssertEqual(restored.preferences.profiles.first { $0.id == claude }?.isShownInStrip, false)
        model.setShownInStrip(claude, true)
        XCTAssertEqual(model.displayedProfiles.map(\.id), [claude])
        XCTAssertNil(model.preferences.profiles[0].hiddenFromStrip, "Showing again stores the default instead of a redundant flag")
    }
}
