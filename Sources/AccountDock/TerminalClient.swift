import AppKit
import DockCore

struct TerminalWindow: Codable, Identifiable, Equatable, Sendable {
    let windowID: Int
    let tty: String
    let title: String
    let selected: Bool
    let front: Bool
    var id: String { "\(windowID):\(tty)" }
    func matches(_ profile: Profile, processStarted: Double?) -> Bool {
        profile.kind.usesTerminal && profile.terminalTTY == tty && profile.terminalWindowID == windowID
            && processStarted != nil && profile.terminalProcessStarted == processStarted
    }
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
                throw CompanionError.message(detail.contains("1743") ? "Allow ProfileDock to control Terminal in System Settings → Privacy & Security → Automation, then try again." : "Terminal could not complete the request. \(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))")
            }
            return result
        }.value
    }
    func windows() async throws -> [TerminalWindow] { try JSONDecoder().decode([TerminalWindow].self, from: await run(["list"])) }
    func open(project: String, claude: Bool) async throws -> TerminalWindow {
        var directory: ObjCBool = false
        guard project.hasPrefix("/"), !project.contains("\0"), FileManager.default.fileExists(atPath: project, isDirectory: &directory), directory.boolValue else { throw CompanionError.message("Choose an existing project folder.") }
        let command = "cd -- " + ClaudeBridgeSettings.shellQuote(project) + (claude ? " && claude" : "")
        return try JSONDecoder().decode(TerminalWindow.self, from: await run(["open", command]))
    }
    func select(_ window: TerminalWindow) async throws { _ = try await run(["select", String(window.windowID), window.tty]) }
    func close(_ window: TerminalWindow) async throws { _ = try await run(["close", String(window.windowID), window.tty]) }
}
