import AppKit
import DockCore

struct TerminalWindow: Codable, Identifiable, Equatable, Sendable {
    let windowID: Int
    let tty: String
    let title: String
    let selected: Bool
    let front: Bool
    var agent: TerminalAgent? = nil
    /// Set for a session in another terminal app (bundle id) or in tmux / screen. Its `windowID` is the agent's pid.
    var host: String? = nil
    /// When the agent process started, which identifies a hosted session across refreshes.
    var agentStarted: Double? = nil
    /// The host app's main process, when known, so only that instance is brought forward.
    var hostProcess: Int32? = nil
    var suggestionLabel: String { [agent?.label ?? "", title, tty].joined(separator: " · ") }
    var id: String { "\(host ?? "terminal"):\(windowID):\(tty)" }
    func matches(_ profile: Profile, processStarted: Double?) -> Bool {
        if let host {
            return profile.tracksTerminalWindow && profile.terminalHost == host && profile.terminalTTY == tty
                && agentStarted != nil && profile.terminalProcessStarted == agentStarted
        }
        return profile.terminalHost == nil && profile.tracksTerminalWindow && profile.terminalTTY == tty && profile.terminalWindowID == windowID
            && processStarted != nil && profile.terminalProcessStarted == processStarted
    }
}

/// Names of host apps by bundle path, read once from Info.plist.
enum HostApps {
    private static let cache = NSCache<NSString, NSString>()
    /// Short names that fit a tile, for apps whose own names are long.
    static let short = ["com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor",
                        "com.googlecode.iterm2": "iTerm2", "com.mitchellh.ghostty": "Ghostty", "dev.warp.Warp-Stable": "Warp", "dev.warp.Warp-Preview": "Warp",
                        "com.anthropic.claudefordesktop": "Claude", "dev.zed.Zed": "Zed", "com.exafunction.windsurf": "Windsurf"]
    static func name(path: String) -> String {
        if let cached = cache.object(forKey: path as NSString) { return cached as String }
        let info = Bundle(path: path)?.infoDictionary
        if let bundle = info?["CFBundleIdentifier"] as? String, let name = short[bundle] {
            cache.setObject(name as NSString, forKey: path as NSString); return name
        }
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        cache.setObject(name as NSString, forKey: path as NSString)
        return name
    }
}

enum TerminalClientError: LocalizedError, Equatable {
    case automationDenied
    var errorDescription: String? { "Allow ProfileDock to control Terminal in System Settings → Privacy & Security → Automation, then try again." }
}

actor TerminalClient {
    static let shared = TerminalClient()
    // No terminal contents are read. Arguments cross the script boundary as argv, never executable source.
    static let script = #"""
    function run(argv) {
      const app = Application('com.apple.Terminal');
      const mode = argv[0];
      if (mode === 'list' && !app.running()) return '[]';
      if (mode === 'open') {
        const tab = app.doScript(argv[1]);
        app.activate();
        const tty = tab.tty();
        for (const w of app.windows()) for (const t of w.tabs()) {
          if (t.tty() === tty) return JSON.stringify({windowID:w.id(), tty:tty, title:(t.customTitle() || w.name()), selected:true, front:true});
        }
        throw Error('The new Terminal tab could not be identified.');
      }
      if (mode === 'list') {
        const rows = [];
        for (const w of app.windows()) for (const t of w.tabs()) {
          rows.push({windowID:w.id(), tty:t.tty(), title:(t.customTitle() || w.name()), selected:t.selected(), front:w.frontmost()});
        }
        return JSON.stringify(rows);
      }
      for (const w of app.windows()) {
        if (String(w.id()) !== argv[1]) continue;
        for (const t of w.tabs()) {
          if (t.tty() !== argv[2]) continue;
          if (mode === 'close') {
            if (w.tabs.length !== 1) {
              w.miniaturized = false; t.selected = true; w.index = 1; app.activate();
              throw Error('This window contains other tabs. Use Close Tab in Terminal to close only this tab.');
            }
            app.close(w);
          } else { w.miniaturized = false; t.selected = true; w.index = 1; app.activate(); }
          return 'ok';
        }
      }
      throw Error('This Terminal tab has closed. Open the entry again to start a new one.');
    }
    """#

    func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", Self.script] + arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            // Bound a stalled Automation request without ever terminating Terminal itself.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            guard process.terminationStatus == 0 else {
                let detail = String(data: error, encoding: .utf8) ?? ""
                if detail.contains("1743") { throw TerminalClientError.automationDenied }
                throw CompanionError.message("Terminal could not complete the request. \(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))")
            }
            return result
        }.value
    }
    /// `installs` are the commands the last scan confirmed, so a vendor install of a shared name is recognized.
    func windows(installs: [String: String] = [:]) async throws -> [TerminalWindow] {
        let windows = try JSONDecoder().decode([TerminalWindow].self, from: await run(["list"]))
        guard !windows.isEmpty else { return [] }
        let agents = try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,tpgid=,tty=,stat=,comm="]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CompanionError.message("Running coding terminals could not be detected.") }
            // Script-based CLIs run as node or python; their argv names the script. The environment is never read.
            return TerminalAgent.processes(String(data: data, encoding: .utf8) ?? "", installs: installs, inspect: DockModel.launch(pid:), executablePath: DockModel.executablePath(pid:), resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        }.value
        return windows.map { var value = $0; value.agent = agents[value.tty]; return value }
    }
    /// Coding agents in other terminal apps and in tmux, from one `ps` run. Only names, parents, paths and the argv of
    /// runtimes are read, as for Terminal.app.
    func hostedSessions(installs: [String: String], skip: @escaping @Sendable (AgentHost) -> Bool) async throws -> [TerminalWindow] {
        try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,ppid=,tpgid=,tty=,stat=,comm="]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CompanionError.message("Running coding terminals could not be detected.") }
            let rows = ProcessRow.rows(String(decoding: data, as: UTF8.self))
            let applications = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            return AgentHosts.sessions(rows: rows, installs: installs, inspect: DockModel.launch(pid:), executablePath: DockModel.executablePath(pid:),
                                       resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                                       isApplication: { applications.contains($0) }, skip: skip).compactMap { session in
                guard let host = session.host.applicationPath.flatMap({ Bundle(path: $0)?.bundleIdentifier }) ?? session.host.bundleIdentifier ?? session.host.multiplexer else { return nil }
                let name = session.host.multiplexer ?? HostApps.short[host] ?? session.host.applicationPath.map { HostApps.name(path: $0) } ?? host
                return TerminalWindow(windowID: Int(session.pid), tty: session.tty, title: name, selected: false, front: false,
                                      agent: TerminalAgent(rawValue: session.tool.id), host: host,
                                      agentStarted: ClaudeProcess.startTime(session.pid), hostProcess: session.host.processIdentifier)
            }
        }.value
    }

    /// iTerm2 can select a session by its TTY. Other apps are only brought forward.
    func selectInITerm(tty: String) async throws {
        let script = #"""
        function run(argv) {
          const app = Application('com.googlecode.iterm2');
          for (const w of app.windows()) for (const t of w.tabs()) for (const s of t.sessions()) {
            if (s.tty() === argv[0]) { w.select(); t.select(); s.select(); app.activate(); return 'ok'; }
          }
          throw Error('This iTerm2 session has closed.');
        }
        """#
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script, tty]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit(); timeout.cancel()
            guard process.terminationStatus == 0 else {
                if detail.contains("1743") { throw TerminalClientError.automationDenied }
                throw CompanionError.message("iTerm2 could not switch to this session.")
            }
        }.value
    }

    func open(project: String, agent: TerminalAgent? = nil) async throws -> TerminalWindow {
        var directory: ObjCBool = false
        guard project.hasPrefix("/"), !project.contains("\0"), FileManager.default.fileExists(atPath: project, isDirectory: &directory), directory.boolValue else { throw CompanionError.message("Choose an existing project folder.") }
        guard let command = AgentLaunch.terminalCommand(project: project, agent: agent) else { throw CompanionError.message("Choose an existing project folder.") }
        return try await open(command: command)
    }
    func open(command: String) async throws -> TerminalWindow {
        guard command.hasPrefix("cd -- "), !command.contains("\n"), !command.contains("\0"), command.utf8.count < 16_384 else { throw CompanionError.message("The launch command was rejected.") }
        return try JSONDecoder().decode(TerminalWindow.self, from: await run(["open", command]))
    }
    func select(_ window: TerminalWindow) async throws { _ = try await run(["select", String(window.windowID), window.tty]) }
    func close(_ window: TerminalWindow) async throws { _ = try await run(["close", String(window.windowID), window.tty]) }
}
