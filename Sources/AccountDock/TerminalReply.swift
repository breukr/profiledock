import AppKit
import DockCore

/// Why a reply was not sent. Each case has a short sentence for the pop-up.
enum TerminalReplyError: LocalizedError, Equatable {
    /// The item is a permission or question, or the agent started working again.
    case notWaiting
    case noTerminal
    case emptyText
    case automationDenied(app: String)
    /// The tab, pane or session with this TTY (the terminal device the agent reads from) is gone.
    case sessionGone
    /// The session runs in an app ProfileDock cannot type into (for example Ghostty, Warp or an editor).
    case unsupportedHost
    case failed(String)
    /// Not an error: the reply went to the pasteboard because the session has no terminal and no held hook.
    case copiedForChat

    var errorDescription: String? {
        switch self {
        case .notWaiting: return "The agent is busy. Reply once it is waiting for you."
        case .noTerminal: return "This session has no terminal to reply to. Open it to answer."
        case .emptyText: return "Type a reply first."
        case .automationDenied(let app): return "Allow ProfileDock to control \(app) in System Settings > Privacy & Security > Automation."
        case .sessionGone: return "This session’s terminal has closed."
        case .unsupportedHost: return "Replies work in Terminal, iTerm2 and tmux. Open the session to answer there."
        case .failed(let detail): return detail
        case .copiedForChat: return "Copied. Paste with ⌘V in the chat."
        }
    }
    var opensAutomationSettings: Bool { if case .automationDenied = self { return true }; return false }
    /// Confirmation rather than a failure, shown without a warning sign.
    var isInformational: Bool { self == .copiedForChat }
}

/// Where a reply typed in the pop-up goes, for any agent. Text is never dropped: when neither the agent's hook nor its
/// terminal can take it, it goes to the pasteboard (the system clipboard) and the exact chat opens.
enum ReplyRoute: Equatable, Sendable {
    /// A held Stop hook continues the session with the text (`AttentionDecision.reply`), terminal or desktop chat alike.
    case decision
    /// Typed into the session's own terminal tab, found by its TTY.
    case terminal
    /// Copied, then the chat opens so the user pastes it.
    case pasteboard

    static func `for`(_ item: AgentAttention) -> ReplyRoute {
        if item.awaitsDecision, item.kind == .finished || item.kind == .waiting { return .decision }
        return TerminalReply.canReply(to: item) ? .terminal : .pasteboard
    }
}

/// Result of one helper process (osascript or tmux).
struct CommandResult: Sendable, Equatable {
    let status: Int32
    let output: String
    let error: String
}

/// Types a reply into exactly the terminal session an attention item came from, identified by its TTY.
/// It never types into the frontmost window: tmux panes, Terminal.app tabs and iTerm2 sessions are matched by TTY,
/// and the text crosses into the helper as an argument (argv), never as script source, so quotes need no escaping.
struct TerminalReply: Sendable {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> CommandResult
    enum Route: String, Sendable, Equatable { case tmux, terminal, iTerm }
    static let terminalBundle = "com.apple.Terminal"
    static let iTermBundle = "com.googlecode.iterm2"
    static let maximumLength = 4000

    var run: Runner = TerminalReply.process
    var isRunning: @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    var tmuxPath: @Sendable () -> String? = { TerminalReply.installedTmux() }
    /// Gap between the text and Return, so the agent sees a typed line instead of one pasted chunk with a newline in it.
    var pause: Duration = .milliseconds(120)

    /// Only waiting or finished items can receive typed text, never while the agent works. Returns the TTY to use.
    static func target(for item: AgentAttention, working: Bool) throws -> String {
        guard item.kind == .waiting || item.kind == .finished, !item.awaitsDecision, !working else { throw TerminalReplyError.notWaiting }
        guard let tty = item.tty, validTTY(tty) else { throw TerminalReplyError.noTerminal }
        return tty
    }
    static func canReply(to item: AgentAttention) -> Bool { (try? target(for: item, working: false)) != nil }
    static func validTTY(_ tty: String) -> Bool { tty.range(of: "^/dev/tty[a-z]?[0-9]+$", options: .regularExpression) != nil }

    /// Line endings become "\n", control characters (escape sequences included) are removed, outer blank space is trimmed.
    static func normalized(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = unified.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(maximumLength))
    }

    // MARK: Commands (pure, so tests check exactly what would run)

    static let tmuxListArguments = ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]
    /// `-l` sends the text literally (no key names), `--` stops option parsing so text starting with "-" is still text.
    static func tmuxArguments(pane: String, text: String) -> (text: [String], enter: [String]) {
        (["send-keys", "-t", pane, "-l", "--", text], ["send-keys", "-t", pane, "Enter"])
    }
    static func tmuxPane(for tty: String, in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == tty, parts[1].hasPrefix("%") { return parts[1] }
        }
        return nil
    }

    // Terminal.app has no "write text"; `do script` in a given tab types into the program running there.
    static let terminalScript = #"""
    function run(argv) {
      const app = Application('com.apple.Terminal');
      if (!app.running()) return 'missing';
      for (const w of app.windows()) for (const t of w.tabs()) {
        if (t.tty() === argv[0]) { app.doScript(argv[1], {in: t}); return 'sent'; }
      }
      return 'missing';
    }
    """#
    // iTerm2 writes the text without a newline, then Return (a carriage return) after a short pause.
    static let iTermScript = #"""
    function run(argv) {
      const app = Application('com.googlecode.iterm2');
      if (!app.running()) return 'missing';
      for (const w of app.windows()) for (const t of w.tabs()) for (const s of t.sessions()) {
        if (s.tty() === argv[0]) { s.write({text: argv[1], newline: false}); delay(Number(argv[2])); s.write({text: '\r', newline: false}); return 'sent'; }
      }
      return 'missing';
    }
    """#
    static func scriptArguments(_ script: String, tty: String, text: String, pause: Duration = .milliseconds(120)) -> [String] {
        let seconds = Double(pause.components.seconds) + Double(pause.components.attoseconds) / 1e18
        return ["-l", "JavaScript", "-e", script, tty, text] + (script == iTermScript ? [String(format: "%.2f", seconds)] : [])
    }

    // MARK: Delivery

    @discardableResult
    func send(_ text: String, to item: AgentAttention, working: Bool) async throws -> Route {
        let tty = try Self.target(for: item, working: working)
        guard let text = Self.normalized(text) else { throw TerminalReplyError.emptyText }
        if let tmux = tmuxPath(), let listing = try? await run(tmux, Self.tmuxListArguments), listing.status == 0,
           let pane = Self.tmuxPane(for: tty, in: listing.output) {
            let commands = Self.tmuxArguments(pane: pane, text: text)
            guard try await run(tmux, commands.text).status == 0 else { throw TerminalReplyError.sessionGone }
            try? await Task.sleep(for: pause)
            guard try await run(tmux, commands.enter).status == 0 else { throw TerminalReplyError.sessionGone }
            return .tmux
        }
        for (route, bundle, script, name) in [(Route.terminal, Self.terminalBundle, Self.terminalScript, "Terminal"), (.iTerm, Self.iTermBundle, Self.iTermScript, "iTerm2")] where isRunning(bundle) {
            let result = try await run("/usr/bin/osascript", Self.scriptArguments(script, tty: tty, text: text, pause: pause))
            if result.status != 0 {
                if result.error.contains("-1743") { throw TerminalReplyError.automationDenied(app: name) }
                if result.error.contains("-600") || result.error.contains("-1728") { continue }
                throw TerminalReplyError.failed("\(name) could not send the reply.")
            }
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "sent" { return route }
        }
        throw isRunning(Self.terminalBundle) || isRunning(Self.iTermBundle) || tmuxPath() != nil ? TerminalReplyError.unsupportedHost : TerminalReplyError.sessionGone
    }

    @Sendable static func installedTmux() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a helper with a 10 s limit. The helper is stopped on timeout; the terminal app itself is never touched.
    static let process: Runner = { executable, arguments in
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let out = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return CommandResult(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self), error: String(decoding: err, as: UTF8.self))
        }.value
    }
}
