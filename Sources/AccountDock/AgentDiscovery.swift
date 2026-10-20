import AppKit
import DockCore

enum AgentAvailability: Equatable {
    case installed, missing, unknown
}

@MainActor extension DockModel {
    nonisolated static let agentBundleIdentifiers = Set(AgentRegistry.tools.flatMap(\.bundleIdentifiers))
    /// Desktop agents that get a tile on their own while they run. Claude Desktop keeps its own entry type.
    nonisolated static let autoAddBundleIdentifiers = Set(AgentRegistry.tools.filter { $0.addsWhenRunning && !$0.legacy }.flatMap(\.bundleIdentifiers))
        .union([ProfileProvider.claude.bundleIdentifier])

    /// File existence, symlink targets and Info.plist only, off the main thread. Repeated requests within
    /// half a minute reuse the last result unless forced.
    func scanAgents(force: Bool = false) {
        if !force, let last = agentScannedAt, Date().timeIntervalSince(last) < 30 { return }
        guard agentScanTask == nil else { return }
        let home = self.home, live = tracksApplications
        let statuses = preferences.profiles.compactMap { profile -> (String, AgentSignInStatus, URL)? in
            guard let status = profile.agentTool?.signInStatus, let data = profile.agentUserDataDirectory(in: home) else { return nil }
            return (profile.id, status, data)
        }
        agentScanTask = Task { [weak self] in
            let (installed, signedOut) = await Task.detached(priority: .utility) { () -> ([InstalledAgent], Set<String>) in
                // Launch Services knows renamed and duplicate copies without reading every app in /Applications.
                let applications = live ? Self.launchServicesApplications() : []
                let scan = AgentProbe.scan(home: home, applications: applications, applicationRoots: live ? nil : [home.appendingPathComponent("Applications")])
                let signedOut = Set(statuses.filter { AgentProbe.signedIn($0.1, userData: $0.2) == false }.map(\.0))
                return (AgentDetector.installed(scan), signedOut)
            }.value
            guard let self else { return }
            self.agentScanTask = nil
            self.agentScannedAt = Date()
            if self.installedAgents != installed { self.installedAgents = installed }
            if self.agentsNeedingSignIn != signedOut { self.agentsNeedingSignIn = signedOut }
        }
    }

    nonisolated static func launchServicesApplications() -> [AgentApplication] {
        agentBundleIdentifiers.sorted().flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }.compactMap { AgentProbe.readApplication($0) }
    }

    func installedAgent(_ toolID: String) -> InstalledAgent? { installedAgents?.first { $0.id == toolID } }

    /// Whether a profile's tool can be opened. Unknown until the first scan of a terminal tool finishes.
    func agentAvailability(_ profile: Profile) -> AgentAvailability {
        guard profile.kind == .agent, let tool = profile.agentTool else { return .installed }
        if running[profile.id]?.isEmpty == false { return .installed }
        if !tool.launchesInTerminal { return applicationURL(for: profile) == nil ? .missing : .installed }
        guard let installedAgents else { return .unknown }
        return installedAgents.first { $0.id == tool.id }?.executablePath != nil ? .installed : .missing
    }

    /// The command for a terminal tool: the scanned install, else a direct check of the usual folders.
    func resolvedExecutable(for tool: AgentTool) -> String? {
        if let path = installedAgent(tool.id)?.executablePath { return path }
        return installedAgents == nil ? AgentProbe.executable(for: tool, home: home) : nil
    }

    /// What to do when a profile's tool is missing, in one sentence with the fix.
    func missingToolMessage(_ tool: AgentTool) -> String {
        if !tool.launchesInTerminal {
            return "\(tool.name) isn’t installed. Install it in Applications, then try again."
        }
        let command = tool.preferredExecutable.map { "`\($0)`" } ?? tool.name
        let install = tool.installHint.map { " Install it with \($0), then try again." } ?? " Install it, then try again."
        return "ProfileDock can’t find \(command) in the usual install folders." + install
    }

    /// Running desktop agents with the shared sign-in get a tile once. Separate accounts are always chosen by hand.
    func autoAddRunningAgents(_ applications: [NSRunningApplication]) {
        guard tracksApplications, preferences.autoAddAgents != false, autoAddingTools.isEmpty else { return }
        let dismissed = Set(preferences.dismissedAgentTools ?? [])
        let candidates = applications.filter { app in
            guard !app.isTerminated, let bundle = app.bundleIdentifier, Self.autoAddBundleIdentifiers.contains(bundle) else { return false }
            if bundle == ProfileProvider.claude.bundleIdentifier { return needsClaudeDesktopEntry }
            // Read argv only for tools that still lack a tile.
            guard let tool = AgentRegistry.tools.first(where: { $0.bundleIdentifiers.contains(bundle) }) else { return false }
            return !dismissed.contains(tool.id) && !preferences.profiles.contains { $0.kind == .agent && $0.agentID == tool.id && !$0.usesIsolatedAgentHome }
        }
        guard !candidates.isEmpty else { return }
        autoAdd(running: candidates.compactMap { app in app.bundleIdentifier.map { AgentAutoAdd.RunningApp(bundleIdentifier: $0, arguments: Self.arguments(pid: app.processIdentifier)) } })
    }

    /// Adds the tiles on the next turn of the main loop, never in the middle of a refresh.
    func autoAdd(running: [AgentAutoAdd.RunningApp]) {
        guard preferences.autoAddAgents != false, autoAddingTools.isEmpty else { return }
        let dismissed = Set(preferences.dismissedAgentTools ?? [])
        var additions = AgentAutoAdd.toolsToAdd(running: running, profiles: preferences.profiles, dismissed: dismissed).map(\.id)
        // Claude Desktop without its own data folder is the shared sign-in.
        if needsClaudeDesktopEntry, running.contains(where: { $0.bundleIdentifier == ProfileProvider.claude.bundleIdentifier && $0.arguments.map { ProcessIdentity.userDataPath($0) == nil } == true }) {
            additions.append("claude-desktop")
        }
        guard !additions.isEmpty else { return }
        autoAddingTools = Set(additions)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.autoAddingTools = [] }
            for id in additions {
                if id == "claude-desktop" {
                    guard self.needsClaudeDesktopEntry else { continue }
                    try? self.createCompanion(kind: .claude, name: "Claude", project: nil, automatic: true)
                } else if let tool = AgentRegistry.tool(id: id),
                          !self.preferences.profiles.contains(where: { $0.kind == .agent && $0.agentID == id && !$0.usesIsolatedAgentHome }) {
                    try? self.createAgentProfile(toolID: id, name: tool.name, project: nil, separate: false, automatic: true)
                }
            }
        }
    }

    /// No Claude Desktop entry with the shared sign-in, and the user has not removed one.
    var needsClaudeDesktopEntry: Bool {
        !preferences.profiles.contains { $0.kind == .claude && !$0.usesSeparateClaudeAccount }
            && !(preferences.removedProfiles ?? []).contains { $0.kind == .claude && !$0.usesSeparateClaudeAccount }
            && !(preferences.dismissedAgentTools ?? []).contains("claude-desktop")
    }

    /// One click from Settings or the strip: the existing sign-in, in the home folder for terminal tools.
    func addDetectedAgent(_ toolID: String) {
        guard let tool = AgentRegistry.tool(id: toolID) else { return }
        do { try createAgentProfile(toolID: toolID, name: tool.name, project: nil, separate: false) }
        catch { message = error.localizedDescription }
    }

    func setAutoAddAgents(_ enabled: Bool) {
        preferences.autoAddAgents = enabled ? nil : false
        save()
        if enabled { refresh() }
    }

    /// A removed shared entry is not added back automatically. Separate accounts never were.
    func rememberDismissal(of profile: Profile) {
        let id: String?
        if profile.kind == .agent, !profile.usesIsolatedAgentHome { id = profile.agentID }
        else if profile.kind == .claude, !profile.usesSeparateClaudeAccount { id = "claude-desktop" }
        else { id = nil }
        guard let id, !(preferences.dismissedAgentTools ?? []).contains(id) else { return }
        preferences.dismissedAgentTools = (preferences.dismissedAgentTools ?? []) + [id]
    }

    func forgetDismissal(of toolID: String) {
        guard let dismissed = preferences.dismissedAgentTools, dismissed.contains(toolID) else { return }
        preferences.dismissedAgentTools = dismissed.filter { $0 != toolID }
    }

    /// When Terminal automation is denied, a one-time command file still opens the tool in a new window.
    /// It runs the same command in the user's login shell and deletes itself first.
    func openTerminalWithoutAutomation(command: String) throws {
        let folder = home.appendingPathComponent("Library/Application Support/Account Dock/Launch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        let inner = command + "; exec \"${SHELL:-/bin/zsh}\" -l"
        let script = "#!/bin/sh\nrm -f \"$0\"\nexec \"${SHELL:-/bin/zsh}\" -l -i -c " + ClaudeBridgeSettings.shellQuote(inner) + "\n"
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw CompanionError.message("Terminal is not available.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            if error != nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
