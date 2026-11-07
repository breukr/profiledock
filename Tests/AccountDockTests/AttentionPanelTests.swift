import AppKit
import SwiftUI
import XCTest
import DockCore
@testable import AccountDock

/// Records helper calls instead of running osascript or tmux, so no real terminal is touched.
private final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(String, [String])] = []
    let respond: @Sendable (String, [String]) -> CommandResult
    init(_ respond: @escaping @Sendable (String, [String]) -> CommandResult) { self.respond = respond }
    var calls: [(String, [String])] { lock.withLock { log } }
    var runner: TerminalReply.Runner {
        { [self] executable, arguments in lock.withLock { log.append((executable, arguments)) }; return respond(executable, arguments) }
    }
}

private func item(_ kind: AttentionKind, id: String = UUID().uuidString, source: String = "claude", session: String = "s1", title: String = "Done",
                  message: String = "", preview: String? = nil, questions: [AttentionQuestion] = [], cwd: String? = "/tmp/meridian-api",
                  config: String? = nil, tty: String? = nil, received: Date = Date(), deadline: Date? = nil, tool: String? = nil) -> AgentAttention {
    AgentAttention(id: id, source: source, sessionID: session, kind: kind, title: title, message: message, toolName: tool, preview: preview, questions: questions,
                   cwd: cwd, configDirectory: config, tty: tty, entrypoint: "cli", receivedAt: received, deadline: deadline)
}

final class AttentionPanelTests: XCTestCase {
    private var home: URL!
    override func setUp() { home = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-attention-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func profiles() -> [Profile] {
        var shared = Profile(id: "noordhaven", name: "Noordhaven", color: "377CF6"); shared.provider = .claude
        var separate = Profile(id: "atlas", name: "Atlas", color: "009B87"); separate.provider = .claude; separate.separateClaudeAccount = true
        var terminal = Profile(id: "meridian-tab", name: "Meridian", color: "955CE5"); terminal.provider = .claudeCode; terminal.terminalTTY = "/dev/ttys004"
        let codex = Profile(id: "default", name: "Default", color: "339958")
        let work = Profile(id: "work", name: "Work", color: "D77620")
        var gemini = Profile(id: "gemini-shared", name: "Gemini", color: "CA528B"); gemini.provider = .agent; gemini.agentID = "gemini"
        return [shared, separate, terminal, codex, work, gemini]
    }

    // MARK: Profile matching

    @MainActor func testProfileMatchingPrefersTerminalThenSeparateAccountThenShared() throws {
        let all = profiles()
        func match(_ value: AgentAttention) -> String? { AttentionPanelController.profile(for: value, profiles: all, home: home)?.id }
        let atlasConfig = try XCTUnwrap(all[1].claudeConfigPath(in: home))
        XCTAssertEqual(match(item(.finished, config: atlasConfig, tty: "/dev/ttys004")), "meridian-tab", "A tracked terminal tab wins")
        XCTAssertEqual(match(item(.finished, config: atlasConfig)), "atlas")
        XCTAssertEqual(match(item(.finished, config: atlasConfig + "/")), "atlas", "Trailing slashes do not matter")
        XCTAssertEqual(match(item(.finished)), "noordhaven", "No CLAUDE_CONFIG_DIR is the shared account")
        XCTAssertEqual(match(item(.finished, config: home.appendingPathComponent(".claude").path)), "noordhaven", "The default folder is the shared account")
        XCTAssertNil(match(item(.finished, config: "/tmp/somebody-else")), "An unknown account shows the agent glyph")
        XCTAssertEqual(match(item(.finished, tty: "/dev/ttys099")), "noordhaven", "An untracked tab still belongs to the account")
        XCTAssertEqual(match(item(.finished, source: "codex", config: home.appendingPathComponent(".codex-work").path)), "work")
        XCTAssertEqual(match(item(.finished, source: "codex")), "default")
        XCTAssertEqual(match(item(.finished, source: "gemini")), "gemini-shared")
        XCTAssertNil(match(item(.finished, source: "hermes")))
    }

    // MARK: Queue and auto-hide

    @MainActor func testPickKeepsTheItemInUseAndJumpsToMoreUrgentOtherwise() {
        let finished = item(.finished, id: "f", session: "a", received: Date(timeIntervalSince1970: 1))
        let permission = item(.permission, id: "p", session: "b", received: Date(timeIntervalSince1970: 2), deadline: Date(timeIntervalSince1970: 100))
        let queue = [permission, finished].sorted(by: AttentionCenter.urgency)
        XCTAssertEqual(AttentionPanelController.pick(current: nil, items: queue, sticky: false), "p")
        XCTAssertEqual(AttentionPanelController.pick(current: "f", items: queue, sticky: false), "p", "A request that holds an agent comes first")
        XCTAssertEqual(AttentionPanelController.pick(current: "f", items: queue, sticky: true), "f", "Never yank an item the user is typing into")
        XCTAssertEqual(AttentionPanelController.pick(current: "gone", items: queue, sticky: true), "p")
        XCTAssertNil(AttentionPanelController.pick(current: "f", items: [], sticky: true))
    }

    @MainActor func testFinishedItemsAutoHideAfterSixSecondsUnlessHoveredOrDrafted() {
        let start = Date(timeIntervalSince1970: 1000)
        let done = item(.finished)
        func hides(after seconds: TimeInterval, hovered: Bool = false, draft: String = "", sending: Bool = false, value: AgentAttention? = nil) -> Bool {
            AttentionPanelController.shouldAutoHide(value ?? done, lastActivity: start, now: start.addingTimeInterval(seconds), hovered: hovered, draft: draft, sending: sending)
        }
        XCTAssertFalse(hides(after: 5.9))
        XCTAssertTrue(hides(after: 6))
        XCTAssertFalse(hides(after: 30, hovered: true))
        XCTAssertFalse(hides(after: 30, draft: "keep going"))
        XCTAssertTrue(hides(after: 30, draft: "  \n"), "Blank drafts do not hold the pop-up")
        XCTAssertFalse(hides(after: 30, sending: true))
        XCTAssertFalse(hides(after: 30, value: item(.waiting)), "Waiting prompts stay until handled")
        XCTAssertFalse(hides(after: 30, value: item(.permission, deadline: start.addingTimeInterval(60))))
    }

    @MainActor func testControllerQueueAnswersAndAutoHideWithoutAWindow() throws {
        var clock = Date(timeIntervalSince1970: 5000)
        let center = AttentionCenter(now: { clock })
        var decisions: [(String, AttentionDecision)] = []
        center.onDecision = { decisions.append(($0, $1)) }
        let model = DockModel(home: home)
        let controller = AttentionPanelController(center: center, model: model, now: { clock })
        controller.showsWindow = false
        controller.start()
        center.post(item(.finished, id: "done", session: "a", received: clock))
        XCTAssertEqual(controller.currentID, "done")
        XCTAssertTrue(controller.revealed)
        center.post(item(.question, id: "q", session: "b", questions: [AttentionQuestion(header: nil, question: "Which?", options: [.init(label: "A"), .init(label: "B")], multiSelect: true)], received: clock, deadline: clock.addingTimeInterval(90)))
        XCTAssertEqual(controller.currentID, "q", "The request that holds an agent jumps ahead")
        XCTAssertEqual(controller.position.index, 1); XCTAssertEqual(controller.position.count, 2)
        let question = try XCTUnwrap(controller.current)
        XCTAssertNil(AttentionPanelController.labels(for: question, selection: controller.selections["q"] ?? [:]))
        controller.toggle(question, question: 0, option: 1); controller.toggle(question, question: 0, option: 0)
        XCTAssertEqual(AttentionPanelController.labels(for: question, selection: controller.selections["q"] ?? [:]), ["A, B"])
        controller.answer(question, labels: ["A, B"])
        XCTAssertEqual(decisions.map(\.0), ["q"]); XCTAssertEqual(decisions.first?.1, .answer(["A, B"]))
        XCTAssertEqual(controller.currentID, "done")
        // The finished item hides from the pop-up after six quiet seconds but stays in the center for the strip.
        clock = clock.addingTimeInterval(6)
        controller.autoHideIfDue()
        XCTAssertNil(controller.currentID)
        XCTAssertFalse(controller.revealed)
        XCTAssertEqual(center.items.map(\.id), ["done"])
        // Turning pop-ups off hides a new request; answering still goes through the center.
        model.preferences.attentionPopups = false
        center.post(item(.permission, id: "p", session: "c", received: clock, deadline: clock.addingTimeInterval(90)))
        XCTAssertFalse(controller.revealed)
        controller.stop()
    }

    @MainActor func testSingleChoiceKeepsOneOptionAndDenyNoteIsTrimmed() throws {
        let center = AttentionCenter()
        var decisions: [AttentionDecision] = []
        center.onDecision = { decisions.append($1) }
        let controller = AttentionPanelController(center: center, model: DockModel(home: home))
        controller.showsWindow = false; controller.start()
        let single = item(.question, id: "s", questions: [AttentionQuestion(header: "Plan", question: "Pick", options: [.init(label: "A"), .init(label: "B")], multiSelect: false)], deadline: Date().addingTimeInterval(60))
        controller.toggle(single, question: 0, option: 0); controller.toggle(single, question: 0, option: 1)
        XCTAssertEqual(AttentionPanelController.labels(for: single, selection: controller.selections["s"] ?? [:]), ["B"])
        center.post(item(.permission, id: "p", deadline: Date().addingTimeInterval(60)))
        controller.deny(try XCTUnwrap(controller.current), note: "  use the staging database  ")
        center.post(item(.permission, id: "p2", deadline: Date().addingTimeInterval(60)))
        controller.deny(try XCTUnwrap(controller.current), note: "   ")
        XCTAssertEqual(decisions, [.deny(message: "use the staging database"), .deny(message: nil)])
        controller.stop()
    }

    @MainActor func testFrameHangsFromTheNotchAndSitsBelowTheMenuBarElsewhere() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = AttentionPanelController.frame(screen: screen, visible: CGRect(x: 0, y: 0, width: 1512, height: 944), notchHeight: 38, contentHeight: 220)
        XCTAssertEqual(notch.maxY, screen.maxY)
        XCTAssertEqual(notch.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(notch.width, AttentionPanelController.cardWidth + AttentionPanelController.margin * 2)
        let plain = AttentionPanelController.frame(screen: screen, visible: CGRect(x: 0, y: 0, width: 1512, height: 957), notchHeight: 0, contentHeight: 220)
        XCTAssertEqual(plain.maxY, 951)
    }

    func testAgeLabels() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(AttentionPanelController.age(of: now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(AttentionPanelController.age(of: now.addingTimeInterval(-125), now: now), "2 min")
        XCTAssertEqual(AttentionPanelController.age(of: now.addingTimeInterval(-7300), now: now), "2 h")
        XCTAssertEqual(AttentionPanelController.age(of: now.addingTimeInterval(-200_000), now: now), "2 d")
        XCTAssertEqual(AttentionPanelController.age(of: now.addingTimeInterval(30), now: now), "now")
    }

    // MARK: Terminal reply

    func testReplyIsRefusedWhileWorkingWithoutTerminalOrForRequests() {
        XCTAssertThrowsError(try TerminalReply.target(for: item(.finished, tty: "/dev/ttys004"), working: true)) { XCTAssertEqual($0 as? TerminalReplyError, .notWaiting) }
        XCTAssertThrowsError(try TerminalReply.target(for: item(.permission, tty: "/dev/ttys004", deadline: Date()), working: false)) { XCTAssertEqual($0 as? TerminalReplyError, .notWaiting) }
        XCTAssertThrowsError(try TerminalReply.target(for: item(.question, tty: "/dev/ttys004"), working: false)) { XCTAssertEqual($0 as? TerminalReplyError, .notWaiting) }
        XCTAssertThrowsError(try TerminalReply.target(for: item(.waiting), working: false)) { XCTAssertEqual($0 as? TerminalReplyError, .noTerminal) }
        XCTAssertThrowsError(try TerminalReply.target(for: item(.waiting, tty: "/dev/ttys004; rm"), working: false)) { XCTAssertEqual($0 as? TerminalReplyError, .noTerminal) }
        XCTAssertEqual(try TerminalReply.target(for: item(.waiting, tty: "/dev/ttys004"), working: false), "/dev/ttys004")
        XCTAssertTrue(TerminalReply.canReply(to: item(.finished, tty: "/dev/ttys012")))
        XCTAssertFalse(TerminalReply.canReply(to: item(.finished)))
    }

    func testReplyTextIsNormalizedAndEscapesStripped() {
        XCTAssertNil(TerminalReply.normalized("  \n\t "))
        XCTAssertEqual(TerminalReply.normalized("yes\r\nand \"quotes\" 'too'\r"), "yes\nand \"quotes\" 'too'")
        XCTAssertEqual(TerminalReply.normalized("go\u{1B}[2J\u{07} on"), "go[2J on", "Escape sequences cannot reach the terminal")
        XCTAssertEqual(TerminalReply.normalized(String(repeating: "a", count: 5000))?.count, TerminalReply.maximumLength)
    }

    func testCommandsCarryTextAsArgumentsNeverAsScriptSource() {
        let text = "it's \"done\"; $(rm -rf ~)\n`whoami` -flag"
        let tmux = TerminalReply.tmuxArguments(pane: "%3", text: text)
        XCTAssertEqual(tmux.text, ["send-keys", "-t", "%3", "-l", "--", text])
        XCTAssertEqual(tmux.enter, ["send-keys", "-t", "%3", "Enter"])
        let terminal = TerminalReply.scriptArguments(TerminalReply.terminalScript, tty: "/dev/ttys004", text: text)
        XCTAssertEqual(Array(terminal.prefix(3)), ["-l", "JavaScript", "-e"])
        XCTAssertEqual(Array(terminal.suffix(2)), ["/dev/ttys004", text])
        XCTAssertFalse(terminal[3].contains("rm -rf"))
        XCTAssertTrue(terminal[3].contains("doScript(argv[1], {in: t})"))
        XCTAssertTrue(terminal[3].contains("t.tty() === argv[0]"), "Only the tab with this TTY is addressed")
        let iTerm = TerminalReply.scriptArguments(TerminalReply.iTermScript, tty: "/dev/ttys004", text: text, pause: .milliseconds(120))
        XCTAssertEqual(Array(iTerm.suffix(3)), ["/dev/ttys004", text, "0.12"])
        XCTAssertEqual(TerminalReply.tmuxPane(for: "/dev/ttys004", in: "/dev/ttys002 %0\n/dev/ttys004 %7\n"), "%7")
        XCTAssertNil(TerminalReply.tmuxPane(for: "/dev/ttys00", in: "/dev/ttys002 %0\n/dev/ttys004 %7"))
    }

    func testSendUsesTheTmuxPaneWithTheSessionTTY() async throws {
        let fake = FakeRunner { _, arguments in
            arguments.first == "list-panes" ? CommandResult(status: 0, output: "/dev/ttys001 %1\n/dev/ttys004 %5\n", error: "") : CommandResult(status: 0, output: "", error: "")
        }
        let reply = TerminalReply(run: fake.runner, isRunning: { _ in true }, tmuxPath: { "/opt/homebrew/bin/tmux" }, pause: .zero)
        let route = try await reply.send("ship it\r\n", to: item(.finished, tty: "/dev/ttys004"), working: false)
        XCTAssertEqual(route, .tmux)
        XCTAssertEqual(fake.calls.map(\.1), [TerminalReply.tmuxListArguments, ["send-keys", "-t", "%5", "-l", "--", "ship it"], ["send-keys", "-t", "%5", "Enter"]])
    }

    func testSendFallsBackToTerminalThenITermAndReportsErrors() async throws {
        let terminalOnly = FakeRunner { _, arguments in CommandResult(status: 0, output: arguments[3] == TerminalReply.terminalScript ? "sent\n" : "missing", error: "") }
        var reply = TerminalReply(run: terminalOnly.runner, isRunning: { _ in true }, tmuxPath: { nil }, pause: .zero)
        let route = try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: false)
        XCTAssertEqual(route, .terminal)
        XCTAssertEqual(terminalOnly.calls.count, 1, "Stops at the first app that has the tab")

        let iTermOnly = FakeRunner { _, arguments in CommandResult(status: 0, output: arguments[3] == TerminalReply.iTermScript ? "sent" : "missing", error: "") }
        reply = TerminalReply(run: iTermOnly.runner, isRunning: { _ in true }, tmuxPath: { nil }, pause: .zero)
        let iTermRoute = try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: false)
        XCTAssertEqual(iTermRoute, .iTerm)

        let denied = FakeRunner { _, _ in CommandResult(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Terminal. (-1743)") }
        reply = TerminalReply(run: denied.runner, isRunning: { $0 == TerminalReply.terminalBundle }, tmuxPath: { nil }, pause: .zero)
        do { try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: false); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TerminalReplyError, .automationDenied(app: "Terminal")); XCTAssertTrue((error as? TerminalReplyError)?.opensAutomationSettings == true) }

        let nowhere = FakeRunner { _, _ in CommandResult(status: 0, output: "missing", error: "") }
        reply = TerminalReply(run: nowhere.runner, isRunning: { $0 == TerminalReply.terminalBundle }, tmuxPath: { nil }, pause: .zero)
        do { try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: false); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TerminalReplyError, .unsupportedHost) }

        reply = TerminalReply(run: nowhere.runner, isRunning: { _ in false }, tmuxPath: { nil }, pause: .zero)
        do { try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: false); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TerminalReplyError, .sessionGone) }
        let calls = nowhere.calls.count
        do { try await reply.send("yes", to: item(.waiting, tty: "/dev/ttys004"), working: true); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TerminalReplyError, .notWaiting) }
        do { try await reply.send(" ", to: item(.waiting, tty: "/dev/ttys004"), working: false); XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TerminalReplyError, .emptyText) }
        XCTAssertEqual(nowhere.calls.count, calls, "Refused replies never run a helper")
    }

    // MARK: Renders (opt-in: PROFILEDOCK_RENDER_ATTENTION=<folder>)

    /// `cacheDisplay` cannot capture Liquid Glass or the behind-window blur, so renders use the macOS 14-25 fallback
    /// (blur plus a black 0.35 layer) over a stand-in desktop, and the Reduce Transparency surface.
    @MainActor func testRenderAttentionPanels() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_ATTENTION"] else { return }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = DockModel(home: home)
        model.preferences.profiles = profiles()
        let atlasConfig = model.preferences.profiles[1].claudeConfigPath(in: home)
        let now = Date()
        let command = "cd ~/Projects/meridian-api && npm run migrate -- --env staging --seed fixtures/atlas.json && git push origin feature/noordhaven-sync --force-with-lease && rm -rf build/.cache"
        let threeOptions = AttentionQuestion(header: "Approach", question: "Which database should the Meridian sync use?", options: [
            .init(label: "Staging", detail: "Safe to reset, shared with the Atlas team"), .init(label: "Local SQLite", detail: "Fast, no network"), .init(label: "Production read replica", detail: "Read-only")], multiSelect: false)
        let multi = AttentionQuestion(header: "Checks", question: "Which checks should run before the push?", options: [
            .init(label: "Unit tests"), .init(label: "Lint"), .init(label: "Snapshot renders", detail: "About 45 s")], multiSelect: true)
        let longMessage = "Finished the Noordhaven importer. Parsed 1,204 rows, skipped 3 with missing postcodes and wrote a summary to reports/import.md. The Meridian API now accepts the new field, and the migration ran cleanly on staging. Next I can add the retry queue or clean up the old CSV reader; tell me which you prefer."
        struct Case { let name: String; let items: [AgentAttention]; var style: AttentionSurfaceStyle = .fallback; var draft: String? = nil; var select: [Int]? = nil; var note: Bool = false; var error: TerminalReplyError? = nil; var band: CGFloat = 38 }
        let cases = [
            Case(name: "permission-long-command", items: [item(.permission, id: "p", title: "Run a command?", message: "Claude wants to run a shell command in meridian-api.", preview: command, config: atlasConfig, tty: "/dev/ttys004", received: now.addingTimeInterval(-40), deadline: now.addingTimeInterval(50), tool: "Bash")]),
            Case(name: "permission-deny-note", items: [item(.permission, id: "p", title: "Edit a file?", message: "Claude wants to edit src/sync.ts.", preview: "src/sync.ts", config: atlasConfig, received: now.addingTimeInterval(-80), deadline: now.addingTimeInterval(8), tool: "Edit")], note: true),
            Case(name: "question-three-options", items: [item(.question, id: "q", title: "Claude has a question", message: threeOptions.question, questions: [threeOptions], tty: "/dev/ttys004", received: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(80))]),
            Case(name: "question-multi-select", items: [item(.question, id: "q", title: "Claude has a question", message: multi.question, questions: [multi], received: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(80))], select: [0, 2]),
            Case(name: "question-read-only", items: [item(.question, id: "q", title: "Claude has a question", message: threeOptions.question, questions: [threeOptions], received: now.addingTimeInterval(-200))]),
            Case(name: "finished-reply", items: [item(.finished, id: "f", title: "Done", message: longMessage, tty: "/dev/ttys004", received: now.addingTimeInterval(-125))], draft: "Add the retry queue, keep the CSV reader for now"),
            Case(name: "finished-reply-error", items: [item(.finished, id: "f", title: "Done", message: "Tests pass. Ready for review.", tty: "/dev/ttys004", received: now.addingTimeInterval(-5))], error: .automationDenied(app: "Terminal")),
            Case(name: "waiting-no-tty", items: [item(.waiting, id: "w", source: "codex", title: "Codex is waiting", message: "Waiting for your next prompt in noordhaven-web.", cwd: "/tmp/noordhaven-web", received: now.addingTimeInterval(-400))]),
            Case(name: "queue-of-three", items: [
                item(.permission, id: "p", session: "a", title: "Run a command?", message: "Claude wants to run tests.", preview: "swift test --filter Atlas", config: atlasConfig, received: now.addingTimeInterval(-30), deadline: now.addingTimeInterval(60), tool: "Bash"),
                item(.waiting, id: "w", source: "codex", session: "b", title: "Codex is waiting", message: "Waiting for input.", received: now.addingTimeInterval(-90)),
                item(.finished, id: "f", session: "c", title: "Done", message: "Updated the README.", tty: "/dev/ttys004", received: now.addingTimeInterval(-300))]),
            Case(name: "reduce-transparency", items: [item(.permission, id: "p", title: "Run a command?", message: "Claude wants to run a shell command.", preview: command, received: now.addingTimeInterval(-40), deadline: now.addingTimeInterval(50), tool: "Bash")], style: .opaque),
            Case(name: "floating-no-notch", items: [item(.finished, id: "f", title: "Done", message: "Refactored the Atlas client.", tty: "/dev/ttys004", received: now.addingTimeInterval(-60))], band: 0),
        ]
        for value in cases {
            let center = AttentionCenter()
            let controller = AttentionPanelController(center: center, model: model)
            controller.showsWindow = false; controller.notchHeight = value.band; controller.start()
            value.items.forEach(center.post)
            let current = try XCTUnwrap(controller.current)
            if let draft = value.draft { controller.drafts[current.id] = draft }
            if let options = value.select { options.forEach { controller.toggle(current, question: 0, option: $0) } }
            if value.note { controller.noteOpen.insert(current.id); controller.notes[current.id] = "Use a feature branch instead" }
            if let error = value.error { controller.setNotice(error, for: current.id) }
            let width = AttentionPanelController.cardWidth + AttentionPanelController.margin * 2
            let root = AttentionPanelView(controller: controller, style: value.style).padding(.bottom, 24)
                .background(LinearGradient(colors: [.indigo, .teal.opacity(0.7), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            let view = NSHostingView(rootView: root.frame(width: width))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            try await Task.sleep(for: .milliseconds(150))
            let height = max(120, view.fittingSize.height)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(for: .milliseconds(450))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(height, 560, "\(value.name) must fit on a laptop screen")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(value.name + ".png"))
            window.close(); controller.stop()
        }
    }
}
