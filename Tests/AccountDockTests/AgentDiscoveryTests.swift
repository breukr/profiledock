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

    @MainActor func testMissingToolsShowNotInstalledWithTheFix() async throws {
        let model = DockModel(home: try home())
        try model.createAgentProfile(toolID: "pi", name: "pi", project: nil, separate: false)
        let pi = try XCTUnwrap(model.preferences.profiles.first)
        XCTAssertEqual(model.agentAvailability(pi), .unknown, "no verdict before the first scan")
        model.installedAgents = []
        XCTAssertEqual(model.agentAvailability(pi), .missing)
        XCTAssertEqual(model.state(pi), "Not installed")
        XCTAssertTrue(model.missingToolMessage(try XCTUnwrap(pi.agentTool)).contains("npm install -g @earendil-works/pi-coding-agent"))
        // Opening looks again off the main thread, then shows the fix and offers the user's own shell.
        model.select(pi)
        for _ in 0..<50 where model.messageRecovery == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.messageRecovery?.title, "Open Anyway")
        XCTAssertEqual(model.messageRecovery?.opensAnyway, true)
        XCTAssertTrue(model.message?.contains("“pi”") == true)
        model.installedAgents = [InstalledAgent(tool: try XCTUnwrap(pi.agentTool), executablePath: "/opt/homebrew/bin/pi", applicationPath: nil, configPath: nil, evidence: [.executable])]
        XCTAssertEqual(model.agentAvailability(pi), .installed)
        XCTAssertEqual(model.state(pi), "Closed")
        // Open Anyway is remembered, and a tab running the tool always counts as installed.
        model.installedAgents = []
        model.retryMessage()
        XCTAssertEqual(model.preferences.profiles.first?.opensByCommandName, true)
        XCTAssertEqual(model.agentAvailability(try XCTUnwrap(model.preferences.profiles.first)), .installed)
        var bound = try XCTUnwrap(model.preferences.profiles.first); bound.opensByCommandName = nil
        bound.terminalTTY = "/dev/ttys004"; bound.terminalWindowID = 4; bound.terminalProcessStarted = 42; model.update(bound)
        model.companions.terminalStarted = 42
        model.companions.windows = [TerminalWindow(windowID: 4, tty: "/dev/ttys004", title: "Fixture", selected: true, front: true, agent: TerminalAgent(rawValue: "pi"))]
        XCTAssertEqual(model.agentAvailability(bound), .installed)
    }

    @MainActor func testAddingASeparateAccountDoesNotUndoARemovedSharedTile() async throws {
        let model = DockModel(home: try home())
        model.autoAdd(running: [grokBot])
        await settle()
        try model.removeProfile(try XCTUnwrap(model.preferences.profiles.first), trashData: false)
        try model.createAgentProfile(toolID: "grok-bot", name: "Work", project: nil, separate: true)
        XCTAssertEqual(model.preferences.dismissedAgentTools, ["grok-bot"])
        model.autoAdd(running: [grokBot])
        await settle()
        XCTAssertEqual(model.preferences.profiles.filter { $0.agentID == "grok-bot" }.map(\.name), ["Work"])
    }

    @MainActor func testNotNowHidesSuggestionsButKeepsAutomaticAdding() async throws {
        let model = DockModel(home: try home())
        model.preferences.hiddenAgentOffers = ["grok-bot"]
        model.autoAdd(running: [grokBot])
        await settle()
        XCTAssertEqual(model.preferences.profiles.map(\.agentID), ["grok-bot"])
    }

    @MainActor func testTheSettingAlsoStopsTheStartupClaudeDesktopEntry() async throws {
        let model = DockModel(home: try home())
        model.setAutoAddAgents(false)
        model.autoAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.anthropic.claudefordesktop", arguments: ["Claude"])])
        await settle()
        XCTAssertFalse(model.preferences.profiles.contains { $0.kind == .claude })
        XCTAssertTrue(model.needsClaudeDesktopEntry)
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

    func testCommandFileFallbackRunsTheSameCommandAndDeletesItself() throws {
        let root = try home().appendingPathComponent("Folder With 'Quotes'")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("ran")
        let command = try XCTUnwrap(AgentLaunch.shellCommand(project: root.path, environment: ["HERMES_HOME": root.path], executable: "/usr/bin/touch"))
        let file = root.appendingPathComponent("launch.command")
        // `exec $SHELL -l` keeps the tab open afterwards; with no input that shell ends at once here.
        try Data(AgentLaunch.commandFile(command: command + " ran").utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
        process.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the command ran in the project folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the file removed itself")
        XCTAssertEqual(TerminalClientError.automationDenied.errorDescription?.contains("Automation"), true)
    }
}

final class HostedTerminalTests: XCTestCase {
    @MainActor func testSessionsInOtherTerminalAppsAppearOnceAndLeaveWithTheAgent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home)
        let iterm = TerminalWindow(windowID: 503, tty: "/dev/ttys001", title: "iTerm2", selected: false, front: false, agent: .claude, host: "com.googlecode.iterm2", agentStarted: 1000)
        let tmux = TerminalWindow(windowID: 702, tty: "/dev/ttys003", title: "tmux", selected: false, front: false, agent: TerminalAgent(rawValue: "opencode"), host: "tmux", agentStarted: 2000)
        model.companions.hostedWindows = [iterm, tmux]
        model.reconcileDiscoveredTerminals()
        model.reconcileDiscoveredTerminals()
        let found = model.preferences.profiles.filter { $0.discoveredTerminal == true }
        XCTAssertEqual(found.map(\.name), ["Claude Code · 001", "OpenCode · 003"])
        XCTAssertEqual(found.map(\.terminalHost), ["com.googlecode.iterm2", "tmux"])
        XCTAssertEqual(model.liveTerminalProfiles.count, 2)
        XCTAssertEqual(model.state(found[1]), "Running in tmux")
        // Hosted sessions keep their state while Terminal.app itself cannot be read.
        model.companions.terminalError = TerminalClientError.automationDenied.localizedDescription
        XCTAssertEqual(model.state(found[0]), "Running in iTerm2")
        model.companions.terminalError = nil
        // A failed process scan keeps the tiles.
        model.reconcileDiscoveredTerminals(includeHosted: false)
        model.companions.hostedWindows = []
        model.reconcileDiscoveredTerminals(includeHosted: false)
        XCTAssertEqual(model.preferences.profiles.filter { $0.discoveredTerminal == true }.count, 2)
        model.companions.hostedWindows = [iterm, tmux]
        XCTAssertEqual(model.terminalAgent(for: found[0]), .claude)
        // A Terminal.app tab with the same TTY number is a different session.
        XCTAssertFalse(TerminalWindow(windowID: 503, tty: "/dev/ttys001", title: "Fixture", selected: false, front: false, agent: .claude).matches(found[0], processStarted: 1000))
        // A new agent in the same TTY is a new session; the old entry leaves with its process.
        model.companions.hostedWindows = [TerminalWindow(windowID: 900, tty: "/dev/ttys001", title: "iTerm2", selected: false, front: false, agent: .claude, host: "com.googlecode.iterm2", agentStarted: 3000)]
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.filter { $0.discoveredTerminal == true }.map(\.terminalProcessStarted), [3000])
        // Selecting a tmux session explains where it is instead of failing silently.
        model.companions.hostedWindows = [tmux]
        model.reconcileDiscoveredTerminals()
        let pane = try XCTUnwrap(model.preferences.profiles.first { $0.terminalHost == "tmux" })
        model.select(pane)
        XCTAssertTrue(model.message?.contains("tmux") == true)
    }

    @MainActor func testTerminalEntriesStayWhileTerminalCannotBeRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home)
        model.companions.terminalStarted = 42
        model.companions.windows = [TerminalWindow(windowID: 1, tty: "/dev/ttys001", title: "Fixture", selected: true, front: true, agent: .codex)]
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.count, 1)
        model.companions.windows = []
        model.reconcileDiscoveredTerminals(includeTerminalApp: false)
        XCTAssertEqual(model.preferences.profiles.count, 1, "an unreadable Terminal is not an empty one")
        model.reconcileDiscoveredTerminals()
        XCTAssertEqual(model.preferences.profiles.count, 0)
    }
}
