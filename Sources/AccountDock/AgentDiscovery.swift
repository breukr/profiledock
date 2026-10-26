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
                // A preview or test home never looks at this Mac's own PATH or apps.
                let scan = live ? AgentProbe.scan(home: home, applications: applications)
                    : AgentProbe.scan(home: home, path: "", applicationRoots: [home.appendingPathComponent("Applications")])
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

    /// Copies on mounted disk images and other read-only volumes are installers, not installs. An app on a
    /// writable external drive counts.
    nonisolated static func launchServicesApplications() -> [AgentApplication] {
        agentBundleIdentifiers.sorted().flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
            .filter { !$0.path.hasPrefix("/Volumes/") || (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false }
            .compactMap { AgentProbe.readApplication($0) }
    }

    func installedAgent(_ toolID: String) -> InstalledAgent? { installedAgents?.first { $0.id == toolID } }

    /// Whether a profile's tool can be opened. Unknown until the first scan of a terminal tool finishes.
    func agentAvailability(_ profile: Profile) -> AgentAvailability {
        guard profile.kind == .agent, let tool = profile.agentTool else { return .installed }
        if running[profile.id]?.isEmpty == false { return .installed }
        // A tab running it, or the user's word that their shell finds it, beats the scan.
        if companions.window(for: profile)?.agent?.rawValue == tool.id || profile.opensByCommandName == true { return .installed }
        // No verdict, and no file system or Launch Services work on the main thread, until the background scan lands.
        guard let installedAgents else { return .unknown }
        let found = installedAgents.first { $0.id == tool.id }
        return (tool.launchesInTerminal ? found?.executablePath : found?.applicationPath) != nil ? .installed : .missing
    }

    /// The command for a terminal tool: the scanned install, else a direct check of the usual folders.
    func resolvedExecutable(for tool: AgentTool) -> String? {
        if let path = installedAgent(tool.id)?.executablePath { return path }
        return installedAgents == nil ? AgentProbe.executable(for: tool, home: home, path: probePath) : nil
    }

    /// A preview or test home never looks at this Mac's own PATH.
    nonisolated var probePath: String { tracksApplications ? ProcessInfo.processInfo.environment["PATH"] ?? "" : "" }

    /// What to do when a profile's tool is missing, in one sentence with the fix.
    func missingToolMessage(_ tool: AgentTool) -> String {
        if !tool.launchesInTerminal {
            return "\(tool.name) isn’t installed. Install it in Applications, then try again."
        }
        let command = tool.preferredExecutable.map { "“\($0)”" } ?? tool.name
        let install = tool.installHint.map { " Install it with this command, then open it again:\n\($0)" } ?? " Install it, then open it again."
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
        let fm = FileManager.default
        let folder = home.appendingPathComponent("Library/Application Support/Account Dock/Launch")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A file Terminal never ran is cleared on the next launch.
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where old.pathExtension == "command" {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 600 { try? fm.removeItem(at: old) }
        }
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        guard fm.createFile(atPath: file.path, contents: Data(AgentLaunch.commandFile(command: command).utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CompanionError.message("Could not prepare the Terminal window.")
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw CompanionError.message("Terminal is not available.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            if error != nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// A problem a tile shows instead of its shortcut, with the fix for its tooltip.
    func tileWarning(_ profile: Profile) -> (text: String, symbol: String, fix: String)? {
        guard profile.kind == .agent, running[profile.id]?.isEmpty != false, !opening.contains(profile.id), let tool = profile.agentTool else { return nil }
        if agentAvailability(profile) == .missing { return ("Not installed", "exclamationmark", missingToolMessage(tool)) }
        if agentsNeedingSignIn.contains(profile.id) { return ("Sign-in needed", "person.fill", "Open \(profile.name) and sign in with the account for this profile.") }
        return nil
    }

    /// A saved terminal tool shows its badge even before a tab runs it, like a discovered tab does.
    func savedTerminalTool(_ profile: Profile) -> TerminalAgent? {
        guard profile.kind == .agent, let tool = profile.agentTool, tool.launchesInTerminal else { return nil }
        return TerminalAgent(rawValue: tool.id)
    }

    /// The first installed copy for these bundle ids, looked up once. A miss is retried after apps launch or quit.
    func cachedApplicationPath(_ bundles: [String]) -> String? {
        let key = bundles.joined(separator: ",")
        if let path = applicationPathCache[key] { return path }
        guard !missingApplicationCache.contains(key) else { return nil }
        let path = bundles.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first { !AgentApplications.excluded($0.path) }?.path
        if let path { applicationPathCache[key] = path } else { missingApplicationCache.insert(key) }
        return path
    }

    func cachedIcon(_ path: String) -> NSImage {
        if let icon = iconCache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    /// The Terminal mark in a terminal tool's color, the same artwork its tiles use.
    func toolArtwork(_ tool: AgentTool) -> NSImage {
        if let image = toolArtworkCache[tool.id] { return image }
        var profile = Profile(id: tool.id, name: tool.name, color: tool.color)
        profile.dockIconStyle = .chatgpt
        let vendor = cachedApplicationPath(["com.apple.Terminal"]).map(cachedIcon)
        let image = NativeProfileArtwork.preview(profile: profile, image: nil, vendor: vendor, margin: 0)
        toolArtworkCache[tool.id] = image
        return image
    }

    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
