import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class PreferencesSafetyTests: XCTestCase {
    func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    func settings(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json") }
    func write(_ text: String, to home: URL) throws {
        try FileManager.default.createDirectory(at: settings(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: settings(home))
    }
    func json(_ home: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings(home))) as? [String: Any])
    }

    /// A newer version's provider, placement, icon style and setting must not cost the other profiles, and survive a save.
    @MainActor func testValuesFromNewerVersionKeepOtherProfilesAndAreWrittenBack() throws {
        let home = try home()
        try write("""
        {"scale": 1.1, "placement": "spiral", "futureSetting": {"enabled": true}, "claudeReadAt": {},
         "profiles": [
          {"id": "one", "name": "One", "color": "377CF6", "provider": "agent", "agentID": "gemini", "dockIconStyle": "hologram", "futureField": 3},
          {"id": "two", "name": "Two", "color": "377CF6", "provider": "future"},
          "not a profile",
          {"id": "three", "name": "Three", "color": "377CF6", "provider": "agent", "agentID": "gemini", "terminalProcessStarted": 1762512345.123456}
         ]}
        """, to: home)
        let model = DockModel(home: home)
        XCTAssertFalse(model.preferencesLocked)
        XCTAssertEqual(model.preferences.profiles.map(\.id), ["one", "three"])
        XCTAssertNil(model.preferences.placement)
        XCTAssertNil(model.preferences.profiles[0].dockIconStyle)
        XCTAssertEqual(model.preferences.scale, 1.1)
        XCTAssertEqual(model.preferences.profiles[1].terminalProcessStarted, 1762512345.123456)

        model.preferences.profiles[0].name = "Renamed"; model.save()
        let saved = try json(home)
        XCTAssertEqual(saved["placement"] as? String, "spiral")
        XCTAssertEqual((saved["futureSetting"] as? [String: Any])?["enabled"] as? Bool, true)
        let profiles = try XCTUnwrap(saved["profiles"] as? [Any])
        let objects = profiles.compactMap { $0 as? [String: Any] }
        XCTAssertEqual(objects.compactMap { $0["id"] as? String }, ["one", "three", "two"])
        XCTAssertTrue(profiles.contains { $0 as? String == "not a profile" })
        XCTAssertEqual(objects[0]["name"] as? String, "Renamed")
        XCTAssertEqual(objects[0]["dockIconStyle"] as? String, "hologram")
        XCTAssertEqual(objects[0]["futureField"] as? Int, 3)
        XCTAssertEqual(objects[2]["provider"] as? String, "future")

        let reopened = DockModel(home: home)
        XCTAssertEqual(reopened.preferences.profiles.map(\.name), ["Renamed", "Three"])
        XCTAssertEqual(reopened.preferences.profiles[1].terminalProcessStarted, 1762512345.123456, "Doubles survive the lenient round trip exactly")
    }

    /// This version's own choice wins over a kept value of the same key.
    @MainActor func testOwnValueReplacesKeptValue() throws {
        let home = try home()
        try write(#"{"scale": 1, "placement": "spiral", "profiles": []}"#, to: home)
        let model = DockModel(home: home)
        model.preferences.placement = .free; model.save()
        XCTAssertEqual(try json(home)["placement"] as? String, "free")
    }

    @MainActor func testMissingScaleAndProfilesUseDefaults() throws {
        let home = try home()
        try write(#"{"showDockIcon": true}"#, to: home)
        let model = DockModel(home: home)
        XCTAssertFalse(model.preferencesLocked)
        XCTAssertEqual(model.preferences.showDockIcon, true)
        XCTAssertEqual(model.preferences.scale, 1)
    }

    @MainActor func testCorruptFileIsBackedUpAndNeverOverwritten() throws {
        let home = try home()
        let original = #"{"profiles": [{"id": "one", "#
        try write(original, to: home)
        let model = DockModel(home: home)
        XCTAssertTrue(model.preferencesLocked)
        XCTAssertNotNil(model.message)
        let folder = settings(home).deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("preferences.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(backups[0]), encoding: .utf8), original)
        var notified = 0
        model.onPreferencesChanged = { notified += 1 }
        model.preferences.scale = 1.2; model.save()
        model.saveSoon(); model.flushPendingSave()
        XCTAssertEqual(try String(contentsOf: settings(home), encoding: .utf8), original)
        XCTAssertEqual(notified, 2, "The running app still applies the change in memory")
    }

    @MainActor func testSaveSoonCoalescesChangesIntoOneWrite() async throws {
        let model = DockModel(home: try home())
        var writes = 0
        model.onPreferencesChanged = { writes += 1 }
        for volume in stride(from: 0.1, through: 0.5, by: 0.1) { model.preferences.activitySoundVolume = volume; model.saveSoon() }
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings(model.home).path))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try json(model.home)["activitySoundVolume"] as? Double ?? 0, 0.5, accuracy: 0.0001)
        // Releasing the slider writes at once, and a later timer does not write again.
        model.preferences.activitySoundVolume = 0.2; model.saveSoon(); model.flushPendingSave()
        XCTAssertEqual(writes, 2)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(writes, 2)
        model.flushPendingSave()
        XCTAssertEqual(writes, 2, "Nothing pending, nothing written")
    }
}

final class CompanionEfficiencyTests: XCTestCase {
    func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testIntervalFollowsAttentionAndTerminals() {
        XCTAssertEqual(CompanionPolling.interval(expanded: true, busy: false, terminalRunning: false), 2)
        XCTAssertEqual(CompanionPolling.interval(expanded: false, busy: true, terminalRunning: false), 2)
        XCTAssertEqual(CompanionPolling.interval(expanded: false, busy: false, terminalRunning: true), 10)
        XCTAssertEqual(CompanionPolling.interval(expanded: false, busy: false, terminalRunning: false), 30)
        XCTAssertTrue(CompanionPolling.isTerminalApp("com.apple.Terminal"))
        XCTAssertTrue(CompanionPolling.isTerminalApp("com.jetbrains.intellij"))
        XCTAssertFalse(CompanionPolling.isTerminalApp("com.apple.Safari"))
        XCTAssertFalse(CompanionPolling.isTerminalApp(nil))
    }

    func testOnlyLiveWorkingOrWaitingSessionsAreBusy() {
        var session = ClaudeSession(id: "s", project: "/p")
        for (state, busy) in [(ClaudeSession.State.working, true), (.waiting, true), (.idle, false), (.closed, false), (.failed, false)] {
            session.state = state
            XCTAssertEqual(CompanionPolling.busy([session], isAlive: { _ in true }), busy, "\(state)")
        }
        session.state = .working
        XCTAssertFalse(CompanionPolling.busy([session], isAlive: { _ in false }), "A working session whose process died does not keep the fast interval")
    }

    @MainActor func testStripExpansionIsTrackedPerScreen() throws {
        let model = DockModel(home: try home())
        model.companions.setStripExpanded(true, id: "a"); model.companions.setStripExpanded(true, id: "b")
        model.companions.setStripExpanded(false, id: "a")
        XCTAssertTrue(model.companions.stripExpanded)
        model.companions.setStripExpanded(false, id: "b")
        XCTAssertFalse(model.companions.stripExpanded)
    }

    func testProcessSnapshotInspectsEachProcessOnce() {
        final class Counter: @unchecked Sendable { var launches = 0, paths = 0 }
        let counter = Counter()
        let snapshot = ProcessSnapshot(taken: Date(), rows: ProcessRow.rows("10 1 10 ttys001 S+ node\n"),
                                       inspect: { _ in counter.launches += 1; return AgentProcessLaunch(executable: "node", arguments: ["node"]) },
                                       path: { _ in counter.paths += 1; return nil })
        for _ in 0..<3 { _ = snapshot.launch(10); _ = snapshot.executablePath(10) }
        XCTAssertEqual(counter.launches, 1); XCTAssertEqual(counter.paths, 1)
        XCTAssertEqual(ProcessRow.agentTable(snapshot.rows), "10 10 ttys001 S+ node")
    }

    /// Only a scan that changes something notifies the strip and activity cues.
    @MainActor func testSessionRefreshNotifiesOnlyOnChange() async throws {
        let model = DockModel(home: try home())
        let store = ClaudeSessionStore(home: model.home)
        _ = try store.record(payload: ["session_id": "fixture", "cwd": "/project", "hook_event_name": "UserPromptSubmit"], statusline: false, process: nil, tty: nil)
        let before = model.companionRevision
        model.companions.refreshSessions()
        for _ in 0..<40 where model.companionRevision == before { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.companionRevision, before + 1)
        XCTAssertEqual(model.companions.sessions.map(\.state), [.working])
        model.companions.refreshSessions()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.companionRevision, before + 1)
    }

    @MainActor func testReadMarkersAreTrimmedToRemainingSessions() throws {
        let model = DockModel(home: try home())
        model.preferences.claudeReadAt = ["kept": Date(), "gone": Date()]
        model.trimReadMarkers(keeping: ["kept", "other"])
        XCTAssertEqual(model.preferences.claudeReadAt?.keys.sorted(), ["kept"])
        XCTAssertEqual(DockModel(home: model.home).preferences.claudeReadAt?.keys.sorted(), ["kept"])
    }

    /// A session that closed while working and is later resumed with the same id must not raise "Done".
    @MainActor func testResumedSessionDoesNotRaiseStaleFinishedCue() throws {
        let model = DockModel(home: try home())
        try model.createCompanion(kind: .claude, name: "Assistant", project: nil)
        let monitor = ActivityMonitor(home: model.home)
        var session = ClaudeSession(id: "fixture", project: "/project", processID: getpid(), processStarted: ClaudeProcess.startTime(getpid()))
        session.state = .working; model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertEqual(monitor.companionStates.count, 1)
        model.companions.sessions = []
        monitor.updateCompanions(model: model)
        XCTAssertTrue(monitor.companionStates.isEmpty)
        session.state = .idle; session.completedAt = Date(); model.companions.sessions = [session]
        monitor.updateCompanions(model: model)
        XCTAssertNil(monitor.event)
    }
}
