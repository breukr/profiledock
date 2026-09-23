import AppKit
import DockCore

@MainActor final class CompanionMonitor {
    weak var model: DockModel?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    var windows: [TerminalWindow] = []
    var sessions: [ClaudeSession] = []
    var terminalStarted: Double?
    var terminalError: String?
    init(model: DockModel) { self.model = model }
    func start() {
        guard timer == nil else { return }
        if let model, model.claudeBridge.enabled,
           !(model.preferences.removedProfiles ?? []).contains(where: { $0.kind == .claude }) {
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: ProfileProvider.claude.bundleIdentifier).first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ProfileProvider.claude.bundleIdentifier)
            _ = try? model.recognizeClaudeDesktop(application: application)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.5
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); task = nil }
    func refresh() {
        guard task == nil, let model else { return }
        let home = model.home
        let terminals = model.preferences.discoverTerminals != false || model.preferences.profiles.contains { $0.kind.usesTerminal && $0.discoveredTerminal != true }
        task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { self.task = nil }
            let records = await Task.detached(priority: .utility) { ClaudeSessionStore(home: home).read() }.value
            guard !Task.isCancelled else { return }
            self.sessions = records
            if terminals, NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty == false {
                do {
                    self.windows = try await TerminalClient.shared.windows()
                    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
                    self.terminalStarted = pid.flatMap { ClaudeProcess.startTime($0) }
                    self.terminalError = nil
                } catch { self.windows = []; self.terminalError = error.localizedDescription }
            } else { self.windows = []; self.terminalStarted = nil; self.terminalError = nil }
            guard !Task.isCancelled else { return }
            if self.terminalError == nil { model.reconcileDiscoveredTerminals() }
            model.rememberCompanionSessions()
            model.refresh()
            model.companionRevision += 1
        }
    }
    func window(for profile: Profile) -> TerminalWindow? { windows.first { $0.matches(profile, processStarted: terminalStarted) } }
    func sessions(for profile: Profile) -> [ClaudeSession] {
        if profile.kind == .claude { return sessions.filter { $0.tty == nil } }
        guard profile.kind.usesTerminal else { return [] }
        if window(for: profile)?.agent == .codex { return [] }
        return sessions.filter { session in
            if let id = profile.claudeSessionID, session.id == id { return true }
            return window(for: profile) != nil && session.tty == profile.terminalTTY && ClaudeProcess.isAlive(session)
        }
    }
}

@MainActor extension DockModel {
    var displayedProfiles: [Profile] {
        preferences.profiles.filter { !$0.kind.usesTerminal } + (preferences.terminalsExpanded == false ? [] : liveTerminalProfiles)
    }
    var liveTerminalProfiles: [Profile] {
        preferences.profiles.filter { $0.kind.usesTerminal && companions.window(for: $0)?.agent != nil && ($0.discoveredTerminal != true || preferences.discoverTerminals != false) }
    }
    var activityProfiles: [Profile] {
        preferences.profiles.filter { $0.kind != .codex || preferences.codexActivityEnabled != false }
    }
    func setTerminalsExpanded(_ expanded: Bool) {
        preferences.terminalsExpanded = expanded; save(); companions.refresh()
    }
    /// Only an authoritative scan removes automatically discovered entries. Saved projects stay intact.
    func reconcileDiscoveredTerminals() {
        var profiles = preferences.profiles
        profiles.removeAll { $0.discoveredTerminal == true && companions.window(for: $0)?.agent == nil }
        if preferences.discoverTerminals != false, let started = companions.terminalStarted {
            for window in companions.windows where window.agent != nil {
                guard !profiles.contains(where: { window.matches($0, processStarted: started) }) else { continue }
                let id = "terminal-\(Int(started))-\(window.windowID)-\(window.tty.split(separator: "/").last ?? "tab")"
                guard !(preferences.hiddenProfileIDs ?? []).contains(id) else { continue }
                var profile = Profile(id: id, name: "\(window.agent!.label) · \(window.tty.replacingOccurrences(of: "/dev/ttys", with: ""))", color: "546E7A")
                profile.provider = .terminal; profile.discoveredTerminal = true; profile.dockIconStyle = .chatgpt
                profile.terminalTTY = window.tty; profile.terminalWindowID = window.windowID
                profile.terminalProcessStarted = started; profile.terminalAgent = window.agent
                profiles.append(profile)
            }
        }
        if profiles != preferences.profiles { preferences.profiles = profiles; save() }
    }
    @discardableResult func recognizeClaudeDesktop(application: URL?) throws -> Bool {
        guard let application, Bundle(url: application)?.bundleIdentifier == ProfileProvider.claude.bundleIdentifier else { return false }
        if !preferences.profiles.contains(where: { $0.kind == .claude }) {
            try createCompanion(kind: .claude, name: "Claude", project: nil)
        }
        return true
    }
    func terminalAgent(for profile: Profile) -> TerminalAgent? { companions.window(for: profile)?.agent }
    func moveDisplayed(_ id: String, by delta: Int) {
        guard let profile = preferences.profiles.first(where: { $0.id == id }) else { return }
        let shown = displayedProfiles.filter { $0.kind.usesTerminal == profile.kind.usesTerminal }
        guard let index = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(index + delta) else { return }
        move(id, to: shown[index + delta].id)
    }
    var claudeBridge: ClaudeBridge { ClaudeBridge(home: home) }
    func rememberCompanionSessions() {
        var changed = false
        for index in preferences.profiles.indices {
            let profile = preferences.profiles[index]
            guard profile.kind.usesTerminal, let window = companions.window(for: profile) else { continue }
            if let agent = window.agent, agent != profile.terminalAgent {
                preferences.profiles[index].terminalAgent = agent; changed = true
            }
            guard window.agent == .claude,
                  let latest = companions.sessions.filter({ $0.tty == profile.terminalTTY && ClaudeProcess.isAlive($0) }).max(by: { $0.updatedAt < $1.updatedAt }),
                  profile.claudeSessionID != latest.id else { continue }
            preferences.profiles[index].claudeSessionID = latest.id
            changed = true
        }
        if changed { save() }
    }
    func createCompanion(kind: ProfileProvider, name: String, project: URL?, window: TerminalWindow? = nil) throws {
        guard kind != .codex, let seed = ProfileLaunch.newProfile(name: name) else { throw CompanionError.message("Use a name between 1 and 32 characters.") }
        if kind == .claude, preferences.profiles.contains(where: { $0.kind == .claude }) { throw CompanionError.message("Claude Desktop is already in ProfileDock. It uses your existing Claude sign-in.") }
        if let window, preferences.profiles.contains(where: { companions.window(for: $0)?.id == window.id }) { throw CompanionError.message("This Terminal tab is already in ProfileDock.") }
        var profile = seed
        profile.provider = kind; profile.color = kind == .claude ? "C97B5D" : "546E7A"
        profile.projectPath = project?.standardizedFileURL.path ?? home.path
        profile.dockIconStyle = .chatgpt
        if let window { bind(&profile, to: window) }
        try FileManager.default.createDirectory(at: profile.home(in: home), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        preferences.profiles.append(profile); save(); refresh()
    }
    func bind(_ profile: inout Profile, to window: TerminalWindow) {
        profile.terminalTTY = window.tty; profile.terminalWindowID = window.windowID
        profile.terminalAgent = window.agent
        profile.terminalProcessStarted = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first.flatMap { ClaudeProcess.startTime($0.processIdentifier) }
        profile.claudeSessionID = companions.sessions.filter { $0.tty == window.tty && ClaudeProcess.isAlive($0) }.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }
    func companionApplications(_ applications: [NSRunningApplication]) -> [String: [RunningProfileApplication]] {
        var result: [String: [RunningProfileApplication]] = [:]
        for profile in preferences.profiles where profile.kind != .codex {
            guard profile.kind == .claude || companions.window(for: profile)?.agent != nil,
                  let app = applications.first(where: { $0.bundleIdentifier == profile.kind.bundleIdentifier }),
                  let running = RunningProfileApplication(app) else { continue }
            result[profile.id] = [running]
        }
        return result
    }
    func selectCompanion(_ profile: Profile) {
        guard !opening.contains(profile.id), !closing.contains(profile.id) else { return }
        message = nil
        if profile.kind == .claude {
            guard let app = applicationURL(for: profile) else { showProfileMessage("Install Claude Desktop in Applications, then try again.", for: profile); return }
            opening.insert(profile.id)
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] application, error in
                Task { @MainActor in
                    guard let self else { return }; self.opening.remove(profile.id)
                    if let error { self.showProfileMessage(error.localizedDescription, for: profile) }
                    else if let application { try? ApplicationReopen.send(processIdentifier: application.processIdentifier); self.markCompanionRead(profile) }
                    self.refresh()
                }
            }
            return
        }
        opening.insert(profile.id)
        Task {
            defer { opening.remove(profile.id); companions.refresh() }
            do {
                let windows = try await TerminalClient.shared.windows()
                let started = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first.flatMap { ClaudeProcess.startTime($0.processIdentifier) }
                if let window = windows.first(where: { $0.matches(profile, processStarted: started) }) {
                    try await TerminalClient.shared.select(window)
                } else {
                    let window = try await TerminalClient.shared.open(project: profile.projectPath ?? home.path, agent: profile.kind == .claudeCode ? .claude : profile.terminalAgent)
                    if var current = preferences.profiles.first(where: { $0.id == profile.id }) {
                        bind(&current, to: window); update(current)
                    }
                }
                markCompanionRead(profile)
            } catch { showProfileMessage(error.localizedDescription, for: profile) }
        }
    }
    func closeCompanion(_ profile: Profile) {
        guard !closing.contains(profile.id) else { return }
        if profile.kind == .claude {
            if running[profile.id]?.first?.terminate() == false { showProfileMessage("Claude could not close. Check its window for a confirmation.", for: profile, actionTitle: "Show Window") }
            return
        }
        guard let window = companions.window(for: profile) else { return }
        closing.insert(profile.id)
        Task {
            defer { closing.remove(profile.id); companions.refresh() }
            do { try await TerminalClient.shared.close(window) }
            catch { showProfileMessage(error.localizedDescription, for: profile, actionTitle: "Show Window") }
        }
    }
    func markCompanionRead(_ profile: Profile) {
        if preferences.claudeReadAt == nil { preferences.claudeReadAt = [:] }
        for session in companions.sessions(for: profile) { preferences.claudeReadAt?[session.id] = Date() }
        save()
    }
    func move(_ id: String, to target: String) {
        let ordered = ProfileOrder.move(preferences.profiles, id: id, to: target)
        guard ordered != preferences.profiles else { return }
        preferences.profiles = ordered; save()
    }
}
