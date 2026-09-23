import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class CompanionIntegrationTests: XCTestCase {
    @MainActor func testDiscoveryWithoutSavedTerminalsDeduplicatesPersistsAndPrunes() throws {
        let model = DockModel(home: try temporaryHome())
        let desktop = Profile(id: "default", name: "Personal", color: "123456")
        model.preferences.profiles = [desktop]
        model.companions.terminalStarted = 42
        let first = TerminalWindow(windowID: 1, tty: "/dev/ttys001", title: "Fixture", selected: true, front: true, agent: .claude)
        let second = TerminalWindow(windowID: 2, tty: "/dev/ttys002", title: "Fixture", selected: true, front: false, agent: .codex)
        let shell = TerminalWindow(windowID: 3, tty: "/dev/ttys003", title: "claude", selected: true, front: false)
        model.companions.windows = [first, second, shell]
        model.reconcileDiscoveredTerminals()
        let terminals = model.liveTerminalProfiles
        XCTAssertEqual(terminals.count, 2)
        XCTAssertEqual(model.displayedProfiles.count, 3)
        XCTAssertTrue(terminals.allSatisfy { $0.discoveredTerminal == true })
        model.move(terminals[1].id, to: terminals[0].id)
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.liveTerminalProfiles.map(\.id), terminals.reversed().map(\.id))
        XCTAssertEqual(DockModel(home: model.home).preferences.profiles.filter { $0.kind.usesTerminal }.map(\.id), terminals.reversed().map(\.id))
        model.preferences.terminalsExpanded = false; model.save()
        XCTAssertEqual(model.displayedProfiles.map(\.id), [desktop.id])
        XCTAssertEqual(model.liveTerminalProfiles.count, 2)
        XCTAssertEqual(DockModel(home: model.home).preferences.terminalsExpanded, false)
        model.preferences.terminalsExpanded = true
        var saved = terminals[0]; saved.discoveredTerminal = nil
        model.update(saved)
        model.companions.windows = []
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.map(\.id), [desktop.id, saved.id])
        XCTAssertEqual(model.liveTerminalProfiles.count, 0)
    }
    @MainActor func testDiscoveryOptOutAndTerminalRestartDoNotReuseOldIdentity() throws {
        let model = DockModel(home: try temporaryHome())
        model.companions.terminalStarted = 42
        model.companions.windows = [TerminalWindow(windowID: 1, tty: "/dev/ttys001", title: "Fixture", selected: true, front: true, agent: .codex)]
        model.preferences.discoverTerminals = false
        model.reconcileDiscoveredTerminals()
        XCTAssertTrue(model.preferences.profiles.isEmpty)
        model.preferences.discoverTerminals = true
        model.reconcileDiscoveredTerminals()
        let old = try XCTUnwrap(model.preferences.profiles.first)
        model.companions.terminalStarted = 43
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.count, 1)
        XCTAssertNotEqual(model.preferences.profiles[0].id, old.id)
        let current = model.preferences.profiles[0]
        try model.removeProfile(current, trashData: false)
        model.reconcileDiscoveredTerminals()
        XCTAssertTrue(model.preferences.profiles.isEmpty)
    }
    @MainActor func testClaudeRecognitionAddsInstalledAppOnceWithoutLaunchingIt() throws {
        let model = DockModel(home: try temporaryHome())
        let app = model.home.appendingPathComponent("Claude.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.anthropic.claudefordesktop"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertFalse(try model.recognizeClaudeDesktop(application: nil))
        XCTAssertTrue(try model.recognizeClaudeDesktop(application: app))
        XCTAssertTrue(try model.recognizeClaudeDesktop(application: app))
        XCTAssertEqual(model.preferences.profiles.filter { $0.kind == .claude }.count, 1)
        XCTAssertTrue(model.opening.isEmpty)
    }
    @MainActor func testCodexConnectorCanDisconnectWithoutRemovingProfiles() throws {
        let model = DockModel(home: try temporaryHome())
        model.preferences.profiles = [Profile(id: "default", name: "Personal", color: "123456")]
        try model.createCompanion(kind: .claude, name: "Claude", project: nil)
        XCTAssertEqual(model.activityProfiles.count, 2)
        model.preferences.codexActivityEnabled = false
        XCTAssertEqual(model.activityProfiles.map(\.kind), [.claude])
        XCTAssertEqual(model.preferences.profiles.count, 2)
        model.preferences.codexActivityEnabled = true
        XCTAssertEqual(model.activityProfiles.count, 2)
    }
    func testLiveTerminalRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["PROFILEDOCK_TEST_TERMINAL"] == "1" else { throw XCTSkip("Opt-in Terminal window test") }
        let client = TerminalClient.shared
        let before = try await client.windows()
        let created = try await client.open(project: "/private/tmp")
        XCTAssertFalse(before.contains(where: { $0.id == created.id }))
        do {
            try await client.select(created)
            let selected = try await client.windows()
            XCTAssertTrue(selected.contains(where: { $0.id == created.id && $0.selected && $0.front }))
        } catch {
            try? await client.close(created)
            throw error
        }
        try await client.close(created)
        let after = try await client.windows()
        XCTAssertFalse(after.contains(where: { $0.id == created.id }))
        XCTAssertTrue(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
    }
    func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    @MainActor func testCompanionsAndOrderPersistWithoutCodexDirectories() throws {
        let home = try temporaryHome(), model = DockModel(home: home)
        try model.createCompanion(kind: .claude, name: "Assistant", project: nil)
        try model.createCompanion(kind: .terminal, name: "Project", project: home)
        let ids = model.preferences.profiles.map(\.id)
        model.move(ids[0], to: ids[1])
        XCTAssertEqual(DockModel(home: home).preferences.profiles.map(\.id), ids.reversed())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        XCTAssertEqual(AppUpdateGroup.make(profiles: model.preferences.profiles, defaultApplication: URL(fileURLWithPath: "/fake/ChatGPT.app")), [])
        try model.removeProfile(model.preferences.profiles[0], trashData: false)
        model.restoreImportedProfiles()
        XCTAssertEqual(model.preferences.profiles.count, 2)
    }
    func testTerminalIdentityRejectsReusedTTYWindowOrProcess() {
        var profile = Profile(id: "terminal", name: "Terminal", color: "123456")
        profile.provider = .terminal; profile.terminalTTY = "/dev/ttys003"; profile.terminalWindowID = 4; profile.terminalProcessStarted = 123
        let window = TerminalWindow(windowID: 4, tty: "/dev/ttys003", title: "Fixture", selected: true, front: true)
        XCTAssertTrue(window.matches(profile, processStarted: 123))
        XCTAssertFalse(window.matches(profile, processStarted: 124))
        XCTAssertFalse(window.matches(profile, processStarted: nil))
        profile.terminalWindowID = 5
        XCTAssertFalse(window.matches(profile, processStarted: 123))
    }
    @MainActor func testNewClaudeSessionIsRememberedAfterItsTabCloses() throws {
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claudeCode, name: "Project", project: model.home)
        var profile = model.preferences.profiles[0]
        profile.terminalTTY = "/dev/fixture"; profile.terminalWindowID = 123; profile.terminalProcessStarted = 42
        model.update(profile)
        model.companions.windows = [TerminalWindow(windowID: 123, tty: "/dev/fixture", title: "Fixture", selected: true, front: true, agent: .claude)]
        model.companions.terminalStarted = 42
        var session = ClaudeSession(id: "new-session", project: model.home.path, processID: getpid(), processStarted: ClaudeProcess.startTime(getpid()))
        session.tty = "/dev/fixture"
        model.companions.sessions = [session]
        model.rememberCompanionSessions()
        profile = model.preferences.profiles[0]
        XCTAssertEqual(profile.claudeSessionID, session.id)
        model.companions.windows = []
        XCTAssertEqual(model.companions.sessions(for: profile).map(\.id), [session.id])
        XCTAssertEqual(DockModel(home: model.home).preferences.profiles[0].claudeSessionID, session.id)
    }
    func testBridgeRoundTripKeepsCustomStatuslineAndUnrelatedSettings() throws {
        let home = try temporaryHome(), bridge = ClaudeBridge(home: home)
        try FileManager.default.createDirectory(at: bridge.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"theme":"dark","permissions":{"allow":["Read"]},"statusLine":{"type":"command","command":"printf 'custom status'","padding":2}}"#.utf8)
        try original.write(to: bridge.settings)
        let helper = home.appendingPathComponent("fixture-helper")
        try Data("fixture executable".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try bridge.setEnabled(true, bundledHelper: helper)
        XCTAssertTrue(bridge.enabled)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.originalStatusline)) as! [String: Any]
        XCTAssertEqual(saved["command"] as? String, "printf 'custom status'")
        try bridge.setEnabled(true, bundledHelper: helper)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.originalStatusline)) as? NSDictionary, saved as NSDictionary)
        try bridge.setEnabled(false, bundledHelper: nil)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.settings)) as! [String: Any]
        XCTAssertEqual(restored["statusLine"] as? NSDictionary, saved as NSDictionary)
        XCTAssertEqual(restored["theme"] as? String, "dark")
        XCTAssertFalse(bridge.enabled)
    }
    @MainActor func testClaudeActivityStartsQuietThenSignalsAndUsesReadMarkers() throws {
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Assistant", project: nil)
        let profile = model.preferences.profiles[0], monitor = ActivityMonitor(home: model.home)
        var session = ClaudeSession(id: "fixture", project: "/project", processID: getpid(), processStarted: ClaudeProcess.startTime(getpid()))
        session.state = .working
        model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertNil(monitor.event)
        session.state = .waiting; model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertEqual(monitor.event?.signal, .needsInput)
        session.state = .idle; session.completedAt = Date(); model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertEqual(monitor.event?.signal, .finished)
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 1)
        model.markCompanionRead(profile); monitor.updateCompanions(model: model)
        XCTAssertEqual(monitor.entries[profile.id]?.unread, 0)
        session.state = .working; session.processStarted = 1; model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertEqual(monitor.entries[profile.id]?.working, 0)
    }
    @MainActor func testDragKeepsIslandOpenUntilCancelled() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display") }
        let model = DockModel(home: try temporaryHome()), usage = UsageStore()
        let island = IslandController(screen: screen, model: model, usage: usage, presentWindows: false, settings: {})
        defer { island.shutdown(); usage.shutdown() }
        island.pointerMoved(to: CGPoint(x: island.layout.collapsed.midX, y: island.layout.collapsed.midY))
        model.draggingProfileID = "fixture"
        island.pointerMoved(to: CGPoint(x: -999, y: -999))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(island.expanded)
        model.draggingProfileID = nil
        island.pointerMoved(to: CGPoint(x: -999, y: -999))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(island.expanded)
    }
    @MainActor func testDragPreviewFollowsPointerAndCleansUpOnCancel() throws {
        _ = NSApplication.shared
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Fixture", project: nil)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        defer { window.close() }
        let session = ProfileDragSession(model: model, profileID: model.preferences.profiles[0].id, window: window)
        let preview = try XCTUnwrap(window.childWindows?.first)
        XCTAssertTrue(preview.ignoresMouseEvents)
        session.move(to: NSPoint(x: 300, y: 300))
        let firstFrame = preview.frame
        session.move(to: NSPoint(x: 340, y: 340))
        XCTAssertNotEqual(preview.frame.origin, firstFrame.origin)
        session.finish(commit: false)
        XCTAssertTrue(window.childWindows?.isEmpty != false)
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(model.draggingProfileID)
    }
    @MainActor func testPointerReorderingCommitsBothDirectionsAndCancelsOutside() throws {
        _ = NSApplication.shared
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Assistant", project: nil)
        try model.createCompanion(kind: .terminal, name: "Project", project: model.home)
        let ids = model.preferences.profiles.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = ProfileDropTarget.Target(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        let second = ProfileDropTarget.Target(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        first.model = model; first.target = ids[0]; second.model = model; second.target = ids[1]
        window.contentView?.addSubview(first); window.contentView?.addSubview(second)
        func drag(_ id: String, to point: NSPoint, commit: Bool) {
            let session = ProfileDragSession(model: model, profileID: id, window: window)
            session.move(to: window.convertPoint(toScreen: point)); session.finish(commit: commit)
            XCTAssertNil(model.draggingProfileID)
        }
        drag(ids[0], to: NSPoint(x: 50, y: 50), commit: true)
        XCTAssertEqual(model.preferences.profiles.map(\.id), ids.reversed())
        drag(ids[1], to: NSPoint(x: 50, y: 150), commit: true)
        XCTAssertEqual(model.preferences.profiles.map(\.id), ids)
        drag(ids[0], to: NSPoint(x: 50, y: 50), commit: false)
        XCTAssertEqual(model.preferences.profiles.map(\.id), ids)
        drag(ids[0], to: NSPoint(x: -200, y: -200), commit: true)
        XCTAssertEqual(model.preferences.profiles.map(\.id), ids)
    }
    @MainActor func testOnlyOpenCodingTerminalsAppearAndAgentChangesClearClaudeUsage() throws {
        let model = DockModel(home: try temporaryHome())
        try model.createCompanion(kind: .claude, name: "Assistant", project: nil)
        try model.createCompanion(kind: .terminal, name: "Project", project: model.home)
        var profile = model.preferences.profiles[1]
        profile.terminalTTY = "/dev/ttys123"; profile.terminalWindowID = 123; profile.terminalProcessStarted = 42
        profile.claudeSessionID = "old-claude-session"
        model.update(profile)
        model.companions.terminalStarted = 42
        var window = TerminalWindow(windowID: 123, tty: "/dev/ttys123", title: "claude in title only", selected: true, front: true)
        model.companions.windows = [window]
        XCTAssertEqual(model.displayedProfiles.count, 1)
        window.agent = .claude; model.companions.windows = [window]
        XCTAssertEqual(model.displayedProfiles.count, 2)
        XCTAssertEqual(model.terminalAgent(for: profile), .claude)
        model.companions.sessions = [ClaudeSession(id: "old-claude-session", project: model.home.path)]
        window.agent = .codex; model.companions.windows = [window]
        XCTAssertEqual(model.terminalAgent(for: profile), .codex)
        XCTAssertTrue(model.companions.sessions(for: profile).isEmpty)
        model.rememberCompanionSessions()
        XCTAssertEqual(model.preferences.profiles[1].terminalAgent, .codex)
        window.agent = nil; model.companions.windows = [window]
        XCTAssertEqual(model.displayedProfiles.count, 1)
        model.companions.windows = []
        XCTAssertEqual(model.displayedProfiles.count, 1)
        XCTAssertEqual(model.preferences.profiles.count, 2)
    }
}
