import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class AgentDiscoveryTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let grokBot = AgentAutoAdd.RunningApp(bundleIdentifier: "com.anysphere.sand", arguments: ["/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"])

    @MainActor private func settle() async { for _ in 0..<3 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) } }

    @MainActor func testRunningDesktopAgentsAreAddedOnceWithTheExistingSignIn() async throws {
        let model = DockModel(home: try home())
        model.autoAdd(running: [grokBot, grokBot, AgentAutoAdd.RunningApp(bundleIdentifier: "dev.zed.Zed", arguments: ["Zed"])])
        await settle()
        let added = model.preferences.profiles.filter { $0.kind == .agent }
        XCTAssertEqual(added.map(\.agentID), ["grok-bot"], "Zed is offered, not added")
        XCTAssertEqual(added.first?.addedAutomatically, true)
        XCTAssertFalse(added.first?.usesIsolatedAgentHome ?? true)
        model.autoAdd(running: [grokBot])
        await settle()
        XCTAssertEqual(model.preferences.profiles.filter { $0.kind == .agent }.count, 1)
        // The entry survives a restart even though a shared sign-in has no folder of its own.
        XCTAssertEqual(DockModel(home: model.home).preferences.profiles.filter { $0.kind == .agent }.map(\.agentID), ["grok-bot"])
    }

    @MainActor func testRemovingOrHidingAnAutomaticEntrySticksAndTheSettingTurnsItOff() async throws {
        let model = DockModel(home: try home())
        model.autoAdd(running: [grokBot])
        await settle()
        let entry = try XCTUnwrap(model.preferences.profiles.first { $0.agentID == "grok-bot" })
        model.setShownInStrip(entry.id, false)
        model.autoAdd(running: [grokBot])
        await settle()
        XCTAssertEqual(model.preferences.profiles.filter { $0.agentID == "grok-bot" }.count, 1, "hidden is not missing")
        try model.removeProfile(entry, trashData: false)
        model.autoAdd(running: [grokBot])
        await settle()
        XCTAssertTrue(model.preferences.profiles.filter { $0.agentID == "grok-bot" }.isEmpty)
        let restarted = DockModel(home: model.home)
        restarted.autoAdd(running: [grokBot])
        await settle()
        XCTAssertTrue(restarted.preferences.profiles.filter { $0.agentID == "grok-bot" }.isEmpty)
        // Adding it by hand clears the dismissal.
        try restarted.createAgentProfile(toolID: "grok-bot", name: "Grok Bot", project: nil, separate: false)
        XCTAssertEqual(restarted.preferences.dismissedAgentTools ?? [], [])

        let off = DockModel(home: try home())
        off.setAutoAddAgents(false)
        off.autoAdd(running: [grokBot])
        await settle()
        XCTAssertTrue(off.preferences.profiles.isEmpty)
        XCTAssertEqual(DockModel(home: off.home).preferences.autoAddAgents, false)
    }

    @MainActor func testAnotherAccountsInstanceAndClaudeDesktopFollowTheirOwnRules() async throws {
        let model = DockModel(home: try home())
        model.autoAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.anysphere.sand", arguments: ["Grok Bot", "--user-data-dir=/Users/someone/elsewhere"])])
        await settle()
        XCTAssertTrue(model.preferences.profiles.isEmpty, "an instance with its own data folder is not the shared sign-in")
        model.autoAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.anthropic.claudefordesktop", arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"])])
        await settle()
        let claude = try XCTUnwrap(model.preferences.profiles.first { $0.kind == .claude })
        XCTAssertFalse(claude.usesSeparateClaudeAccount)
        XCTAssertEqual(claude.addedAutomatically, true)
        try model.removeProfile(claude, trashData: false)
        model.autoAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.anthropic.claudefordesktop", arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"])])
        await settle()
        XCTAssertFalse(model.preferences.profiles.contains { $0.kind == .claude })
    }

    @MainActor func testMissingToolsShowNotInstalledWithTheFix() throws {
        let model = DockModel(home: try home())
        try model.createAgentProfile(toolID: "pi", name: "pi", project: nil, separate: false)
        let pi = try XCTUnwrap(model.preferences.profiles.first)
        XCTAssertEqual(model.agentAvailability(pi), .unknown, "no verdict before the first scan")
        model.installedAgents = []
        XCTAssertEqual(model.agentAvailability(pi), .missing)
        XCTAssertEqual(model.state(pi), "Not installed")
        XCTAssertTrue(model.missingToolMessage(try XCTUnwrap(pi.agentTool)).contains("npm install -g @earendil-works/pi-coding-agent"))
        // Opening shows the fix and offers to try the user's own shell instead of failing silently.
        model.select(pi)
        XCTAssertEqual(model.messageRecovery?.title, "Open Anyway")
        XCTAssertEqual(model.messageRecovery?.opensAnyway, true)
        XCTAssertTrue(model.message?.contains("`pi`") == true)
        model.installedAgents = [InstalledAgent(tool: try XCTUnwrap(pi.agentTool), executablePath: "/opt/homebrew/bin/pi", applicationPath: nil, configPath: nil, evidence: [.executable])]
        XCTAssertEqual(model.agentAvailability(pi), .installed)
        XCTAssertEqual(model.state(pi), "Closed")
    }

    @MainActor func testSeparateDesktopAccountsReportSignInNeededFromTheirStatusFile() throws {
        let model = DockModel(home: try home())
        try model.createAgentProfile(toolID: "grok-bot", name: "Work", project: nil, separate: true)
        let work = try XCTUnwrap(model.preferences.profiles.first)
        model.agentsNeedingSignIn = [work.id]
        model.installedAgents = []
        XCTAssertEqual(model.state(work), "Not installed", "a missing app wins over the sign-in hint")
        let tool = try XCTUnwrap(work.agentTool)
        model.installedAgents = [InstalledAgent(tool: tool, executablePath: nil, applicationPath: "/Applications/Grok Bot.app", configPath: nil, evidence: [.application])]
        XCTAssertEqual(model.state(work), "Sign-in needed")
        XCTAssertEqual(model.applicationURL(for: work)?.path, "/Applications/Grok Bot.app")
        model.agentsNeedingSignIn = []
        XCTAssertEqual(model.state(work), "Closed")
    }

    @MainActor func testADiscoveredTabNeverDuplicatesTheSavedProfileThatOwnsIt() throws {
        let model = DockModel(home: try home())
        try model.createAgentProfile(toolID: "hermes", name: "Hermes", project: model.home, separate: false)
        model.companions.terminalStarted = 42
        let window = TerminalWindow(windowID: 9, tty: "/dev/ttys009", title: "Fixture", selected: true, front: true, agent: TerminalAgent(rawValue: "hermes"))
        model.companions.windows = [window]
        // Discovery can run before the new tab is bound to its profile.
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.filter { $0.discoveredTerminal == true }.count, 1)
        var saved = try XCTUnwrap(model.preferences.profiles.first { $0.kind == .agent })
        saved.terminalTTY = window.tty; saved.terminalWindowID = window.windowID; saved.terminalProcessStarted = 42
        model.update(saved)
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.filter { $0.discoveredTerminal == true }.count, 0)
        XCTAssertEqual(model.companions.window(for: saved)?.id, window.id)
        // When the tool exits, the idle shell is no coding session and nothing is rediscovered.
        model.companions.windows = [TerminalWindow(windowID: 9, tty: "/dev/ttys009", title: "Fixture", selected: true, front: true)]
        model.reconcileDiscoveredTerminals()
        XCTAssertTrue(model.liveTerminalProfiles.isEmpty)
    }

    @MainActor func testCommandFileFallbackRunsTheSameCommandAndDeletesItself() throws {
        let command = "cd -- '/Work' && HERMES_HOME='/x' hermes"
        let inner = command + "; exec \"${SHELL:-/bin/zsh}\" -l"
        XCTAssertEqual(ClaudeBridgeSettings.shellQuote(inner), "'cd -- '\\''/Work'\\'' && HERMES_HOME='\\''/x'\\'' hermes; exec \"${SHELL:-/bin/zsh}\" -l'")
        XCTAssertEqual(TerminalClientError.automationDenied.errorDescription?.contains("Automation"), true)
    }
}
