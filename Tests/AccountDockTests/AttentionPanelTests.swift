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

/// Collects what the controller hands to its seams.
@MainActor private final class Box {
    var decisions: [(String, AttentionDecision)] = []
    var extended: [(String, Date)] = []
    var copied: [String] = []
    var opened: [String] = []
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

    @MainActor func testPillsAutoHideAfterFiveSecondsUnlessHoveredDraftedOrReplying() {
        let start = Date(timeIntervalSince1970: 1000)
        let done = item(.finished)
        func hides(after seconds: TimeInterval, hovered: Bool = false, draft: String = "", sending: Bool = false, replying: Bool = false, value: AgentAttention? = nil) -> Bool {
            AttentionPanelController.shouldAutoHide(value ?? done, lastActivity: start, now: start.addingTimeInterval(seconds), hovered: hovered, draft: draft, sending: sending, replying: replying)
        }
        XCTAssertFalse(hides(after: 4.9))
        XCTAssertTrue(hides(after: 5))
        XCTAssertFalse(hides(after: 30, hovered: true))
        XCTAssertFalse(hides(after: 30, draft: "keep going"))
        XCTAssertTrue(hides(after: 30, draft: "  \n"), "Blank drafts do not hold the pop-up")
        XCTAssertFalse(hides(after: 30, sending: true))
        XCTAssertFalse(hides(after: 30, replying: true), "An open reply card stays")
        XCTAssertTrue(hides(after: 5, value: item(.waiting)), "A waiting pill leaves too; the strip still lists it")
        XCTAssertFalse(hides(after: 30, value: item(.permission, deadline: start.addingTimeInterval(60))), "Requests stay until answered")
        XCTAssertFalse(hides(after: 30, value: item(.question, deadline: start.addingTimeInterval(60))))
    }

    // MARK: Presentation, geometry and labels

    func testDoneAndWaitingArePillsAndRequestsShowContent() {
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.finished), replying: false), .compact)
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.waiting), replying: false), .compact)
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.finished), replying: true), .reply)
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.waiting, deadline: Date()), replying: true), .reply)
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.permission, deadline: Date()), replying: false), .full)
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.question, deadline: Date()), replying: true), .full, "Reply never applies to a request")
        XCTAssertEqual(AttentionPanelController.presentation(for: item(.question), replying: false), .full)
    }

    func testShapeIsCenteredOnTheIslandForEverySize() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982), visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let island = CGSize(width: 200, height: 38)
        for midX in [screen.midX, 700.5, 1200.25] {
            let panel = AttentionPanelController.frame(screen: screen, visible: visible, notchHeight: 38, contentHeight: 300, islandMidX: midX)
            XCTAssertEqual(panel.maxY, screen.maxY)
            for presentation in [AttentionPresentation.compact, .reply, .full] {
                let geometry = AttentionBlobGeometry.target(presentation: presentation, contentHeight: 180, band: 38, origin: island, fused: true, open: true)
                let shape = AttentionPanelController.shapeFrame(panel: panel, size: geometry.size)
                XCTAssertEqual(shape.midX, midX, accuracy: 0.25, "\(presentation) at \(midX)")
                XCTAssertEqual(shape.maxY, panel.maxY, "Hangs from the top edge")
                XCTAssertLessThanOrEqual(geometry.size.width, panel.width, "Fits the panel with its shoulders")
                // The body without shoulders is the presentation's width, so text insets do not depend on the shoulders.
                XCTAssertEqual(geometry.size.width - 2 * geometry.shoulder, AttentionPanelController.shapeWidth(presentation))
            }
            let folded = AttentionBlobGeometry.target(presentation: .full, contentHeight: 180, band: 38, origin: island, fused: true, open: false)
            XCTAssertEqual(AttentionPanelController.shapeFrame(panel: panel, size: folded.size).midX, midX, accuracy: 0.25, "The folded shape is the island itself")
            XCTAssertEqual(folded.size, island)
        }
        let pill = AttentionBlobGeometry.target(presentation: .compact, contentHeight: nil, band: 38, origin: island, fused: true, open: true)
        XCTAssertEqual(pill.size, CGSize(width: AttentionPanelController.pillWidth + 2 * NotchShape.shoulderSize, height: 38 + AttentionPanelController.pillRow))
        XCTAssertEqual(pill.bottomRadius, AttentionPanelController.pillRow / 2, "The pill's bottom is fully round")
        let floating = AttentionBlobGeometry.target(presentation: .compact, contentHeight: nil, band: 0, origin: .zero, fused: false, open: true)
        XCTAssertEqual(floating.topRadius, floating.bottomRadius, "Without a notch the pill is a capsule")
    }

    func testPillNamesTheInstanceThenStatusAndAnyAgent() {
        let profile = Profile(id: "p", name: "Atlas", color: "377CF6")
        let done = item(.finished)
        XCTAssertEqual(AttentionPanelController.headline(done, profile: profile), "Atlas")
        XCTAssertEqual(AttentionPanelController.compactSubtitle(done, profile: profile), "Done · meridian-api")
        XCTAssertEqual(AttentionPanelController.compactSubtitle(item(.waiting), profile: profile), "Waiting · meridian-api")
        let codex = item(.waiting, source: "codex", cwd: "/tmp/noordhaven-web")
        XCTAssertEqual(AttentionPanelController.headline(codex, profile: nil), "noordhaven-web")
        XCTAssertEqual(AttentionPanelController.compactSubtitle(codex, profile: nil), "Waiting · Codex")
        let gemini = item(.finished, source: "gemini", cwd: nil)
        XCTAssertEqual(AttentionPanelController.headline(gemini, profile: nil), "Gemini CLI")
        XCTAssertEqual(AttentionPanelController.compactSubtitle(gemini, profile: nil), "Done", "Never repeats the headline")
        XCTAssertEqual(AttentionPanelController.answerLabel(gemini), "Answer in Gemini CLI")
        XCTAssertEqual(AttentionPanelController.answerLabel(item(.permission, source: "opencode")), "Answer in OpenCode")
        XCTAssertEqual(AttentionPanelController.compactSubtitle(item(.finished, source: "some-new-agent"), profile: nil), "Done · Some-New-Agent", "Unknown agents still get a label")
    }

    func testShiftOrOptionReturnAddsALineAndReturnSends() throws {
        func event(_ flags: NSEvent.ModifierFlags, key: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: key))
        }
        XCTAssertTrue(AttentionWindow.isNewlineChord(try event(.shift)))
        XCTAssertTrue(AttentionWindow.isNewlineChord(try event(.option)))
        XCTAssertTrue(AttentionWindow.isNewlineChord(try event(.shift, key: 76)), "The keypad Enter key too")
        XCTAssertFalse(AttentionWindow.isNewlineChord(try event([])), "Plain Return sends")
        XCTAssertFalse(AttentionWindow.isNewlineChord(try event(.command)), "Command-Return stays a shortcut")
        XCTAssertFalse(AttentionWindow.isNewlineChord(try event([.shift, .command])))
    }

    // MARK: Reply routing

    @MainActor private func replyHarness(_ clock: @escaping () -> Date = Date.init) -> (AttentionCenter, AttentionPanelController, Box) {
        let center = AttentionCenter(now: clock)
        let box = Box()
        center.onDecision = { box.decisions.append(($0, $1)) }
        center.onExtend = { box.extended.append(($0, $1)) }
        let controller = AttentionPanelController(center: center, model: DockModel(home: home), now: clock)
        controller.showsWindow = false
        controller.copyToPasteboard = { box.copied.append($0) }
        controller.openSession = { box.opened.append($0.id) }
        controller.start()
        return (center, controller, box)
    }

    @MainActor func testReplyToAHeldHookContinuesTheSession() throws {
        let (center, controller, box) = replyHarness()
        center.post(item(.finished, id: "held", tty: "/dev/ttys004", deadline: Date().addingTimeInterval(30)))
        let held = try XCTUnwrap(controller.current)
        controller.openReply(held)
        XCTAssertEqual(controller.presentation(for: held), .reply)
        controller.setDraft("  Ship it,\r\nthen tag 1.2  ", for: "held")
        XCTAssertNil(controller.sendReply(held), "The decision goes out at once, no helper process")
        XCTAssertEqual(box.decisions.map(\.0), ["held"])
        XCTAssertEqual(box.decisions.first?.1, .reply("Ship it,\nthen tag 1.2"), "A held hook wins over the terminal")
        XCTAssertTrue(center.items.isEmpty); XCTAssertTrue(box.copied.isEmpty); XCTAssertTrue(box.opened.isEmpty)
        controller.stop()
    }

    @MainActor func testReplyWithATerminalIsTypedIntoThatTab() async throws {
        let (center, controller, box) = replyHarness()
        let fake = FakeRunner { _, arguments in
            arguments.first == "list-panes" ? CommandResult(status: 0, output: "/dev/ttys004 %5\n", error: "") : CommandResult(status: 0, output: "", error: "")
        }
        controller.reply = TerminalReply(run: fake.runner, isRunning: { _ in false }, tmuxPath: { "/opt/homebrew/bin/tmux" }, pause: .zero)
        center.post(item(.finished, id: "t", tty: "/dev/ttys004"))
        let done = try XCTUnwrap(controller.current)
        controller.openReply(done); controller.setDraft("add the retry queue", for: "t")
        await controller.sendReply(done)?.value
        XCTAssertEqual(fake.calls.map(\.1)[1], ["send-keys", "-t", "%5", "-l", "--", "add the retry queue"])
        XCTAssertTrue(center.items.isEmpty, "Answered in the terminal")
        XCTAssertTrue(box.decisions.isEmpty, "Nothing waits on a decision"); XCTAssertTrue(box.copied.isEmpty)
        controller.stop()
    }

    @MainActor func testReplyWithoutHookOrTerminalIsCopiedAndTheChatOpens() throws {
        let (center, controller, box) = replyHarness()
        center.post(item(.waiting, id: "c", source: "codex", config: "/tmp/unknown-codex"))
        let waiting = try XCTUnwrap(controller.current)
        XCTAssertEqual(ReplyRoute.for(waiting), .pasteboard)
        controller.openReply(waiting)
        controller.sendReply(waiting)
        XCTAssertEqual(controller.notice?.error, .emptyText, "Empty replies are refused, never sent")
        XCTAssertTrue(box.copied.isEmpty)
        controller.setDraft("Use the staging database", for: "c")
        controller.sendReply(waiting)
        XCTAssertEqual(box.copied, ["Use the staging database"])
        XCTAssertEqual(box.opened, ["c"], "Opens the exact chat")
        XCTAssertEqual(controller.notice?.error, .copiedForChat)
        XCTAssertEqual(controller.notice?.error.isInformational, true)
        XCTAssertEqual(controller.presentation(for: waiting), .compact, "Back to the pill with the confirmation")
        XCTAssertEqual(center.items.map(\.id), ["c"], "Not answered yet: the strip keeps it")
        XCTAssertNil(controller.drafts["c"])
        controller.stop()
    }

    @MainActor func testTypingIntoAHeldReplyExtendsTheHoldAtMostEveryTenSeconds() throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let (center, controller, box) = replyHarness({ clock })
        center.post(item(.finished, id: "h", session: "a", received: clock, deadline: clock.addingTimeInterval(30)))
        center.post(item(.finished, id: "n", session: "b", received: clock))
        let held = try XCTUnwrap(center.items.first { $0.id == "h" })
        controller.openReply(held)
        XCTAssertTrue(box.extended.isEmpty, "Opening the card alone does not hold the agent")
        controller.replyFocusChanged("h", focused: true)
        XCTAssertEqual(box.extended.map(\.1), [clock.addingTimeInterval(120)])
        XCTAssertEqual(center.items.first { $0.id == "h" }?.deadline, clock.addingTimeInterval(120), "The countdown stays truthful")
        clock = clock.addingTimeInterval(5); controller.setDraft("a", for: "h")
        XCTAssertEqual(box.extended.count, 1, "Throttled")
        clock = clock.addingTimeInterval(6); controller.setDraft("ab", for: "h")
        XCTAssertEqual(box.extended.map(\.1).last, clock.addingTimeInterval(120))
        XCTAssertEqual(box.extended.count, 2)
        controller.replyFocusChanged("h", focused: false)
        clock = clock.addingTimeInterval(30); controller.setDraft("", for: "h")
        XCTAssertEqual(box.extended.count, 2, "Not focused and empty: no hold")
        controller.replyFocusChanged("n", focused: true); controller.setDraft("hello", for: "n")
        XCTAssertEqual(box.extended.count, 2, "Items without a held hook are never extended")
        XCTAssertTrue(AttentionPanelController.shouldExtendHold(lastExtended: nil, now: clock))
        XCTAssertFalse(AttentionPanelController.shouldExtendHold(lastExtended: clock.addingTimeInterval(-9.9), now: clock))
        XCTAssertTrue(AttentionPanelController.shouldExtendHold(lastExtended: clock.addingTimeInterval(-10), now: clock))
        controller.stop()
    }

    // MARK: Questions

    @MainActor func testOtherAnswerSendsTheTypedText() throws {
        let (center, controller, box) = replyHarness()
        let question = AttentionQuestion(header: nil, question: "Which database?", options: [.init(label: "Staging"), .init(label: "Local")], multiSelect: false)
        center.post(item(.question, id: "q", questions: [question], deadline: Date().addingTimeInterval(60)))
        let current = try XCTUnwrap(controller.current)
        controller.toggle(current, question: 0, option: 1)
        controller.toggleOther(current, question: 0)
        XCTAssertNil(controller.selections["q"]?[0], "A single choice and a typed answer exclude each other")
        controller.answerOther(current, question: 0)
        XCTAssertTrue(box.decisions.isEmpty, "Nothing typed yet")
        controller.setOther("  Postgres in Docker ", for: current, question: 0)
        controller.answerOther(current, question: 0)
        XCTAssertEqual(box.decisions.first?.1, .answer(["Postgres in Docker"]))
        controller.stop()
    }

    @MainActor func testOtherTextJoinsAMultipleChoiceAndReplacesASingleOne() {
        let multi = AttentionQuestion(header: nil, question: "Checks?", options: [.init(label: "Unit tests"), .init(label: "Lint")], multiSelect: true)
        let single = AttentionQuestion(header: nil, question: "Branch?", options: [.init(label: "main"), .init(label: "dev")], multiSelect: false)
        let value = item(.question, questions: [multi, single], deadline: Date())
        XCTAssertNil(AttentionPanelController.labels(for: value, selection: [0: [1]]), "Every question needs an answer")
        XCTAssertEqual(AttentionPanelController.labels(for: value, selection: [0: [1]], other: [0: "Docs", 1: "release/1.2"]), ["Lint, Docs", "release/1.2"])
        XCTAssertEqual(AttentionPanelController.labels(for: value, selection: [0: [0], 1: [0]], other: [1: "  "]), ["Unit tests", "main"], "Blank text is no answer")
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

    func testHeaderNamesTheInstanceFirstAndNeverRepeatsTheAgent() {
        let item = AgentAttention(source: "claude", sessionID: "s", kind: .waiting, title: "Waiting", message: "", cwd: "/tmp/meridian-api")
        let profile = Profile(id: "p", name: "Atlas", color: "377CF6")
        XCTAssertEqual(AttentionPanelController.headline(item, profile: profile), "Atlas")
        XCTAssertEqual(AttentionPanelController.subtitle(item, profile: profile), "Claude Code · meridian-api")
        XCTAssertEqual(AttentionPanelController.headline(item, profile: nil), "meridian-api")
        XCTAssertEqual(AttentionPanelController.subtitle(item, profile: nil), "Claude Code")
        let bare = AgentAttention(source: "claude", sessionID: "s", kind: .waiting, title: "Waiting", message: "")
        XCTAssertEqual(AttentionPanelController.headline(bare, profile: nil), "Claude Code")
        XCTAssertEqual(AttentionPanelController.subtitle(bare, profile: nil), "")
    }

    func testCountdownUsesPlainDigitsAndMinutesForLongHolds() {
        XCTAssertEqual(AttentionPanelController.countdown(49.2), "50s")
        XCTAssertEqual(AttentionPanelController.countdown(99), "99s")
        XCTAssertEqual(AttentionPanelController.countdown(3586), "60 min", "Never a locale-grouped \"3.586s\"")
        XCTAssertEqual(AttentionPanelController.countdown(-3), "0s")
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
    /// (blur plus the black shade) over a stand-in desktop, and the Reduce Transparency surface. Animations are off, so each
    /// render is the settled state. Fused renders also measure the black band's top row: it must sit centered.
    @MainActor func testRenderAttentionPanels() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_ATTENTION"] else { return }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = DockModel(home: home)
        model.preferences.profiles = profiles()
        let atlasConfig = model.preferences.profiles[1].claudeConfigPath(in: home)
        let now = Date()
        let command = "cd ~/Projects/meridian-api && npm run migrate -- --env staging --seed fixtures/atlas.json && git push origin feature/noordhaven-sync --force-with-lease && rm -rf build/.cache && swift test --filter AtlasSyncTests --parallel"
        let threeOptions = AttentionQuestion(header: "Approach", question: "Which database should the Meridian sync use?", options: [
            .init(label: "Staging", detail: "Safe to reset, shared with the Atlas team"), .init(label: "Local SQLite", detail: "Fast, no network"), .init(label: "Production read replica", detail: "Read-only")], multiSelect: false)
        let multi = AttentionQuestion(header: "Checks", question: "Which checks should run before the push?", options: [
            .init(label: "Unit tests"), .init(label: "Lint"), .init(label: "Snapshot renders", detail: "About 45 s")], multiSelect: true)
        let menuBar = CGSize(width: 194, height: 31)
        enum Setup { case none, reply(String?), hover, notice(TerminalReplyError), other(String), select([Int]), note, preview }
        struct Case { let name: String; let items: [AgentAttention]; var setup: Setup = .none; var style: AttentionSurfaceStyle = .fallback; var band: CGFloat = 38; var island: CGSize = CGSize(width: 200, height: 38) }
        let held = now.addingTimeInterval(40)
        let cases = [
            // Pills: one row, no message.
            Case(name: "compact-done", items: [item(.finished, id: "f", title: "Done", message: "Finished the Noordhaven importer.", config: atlasConfig, received: now.addingTimeInterval(-20))]),
            Case(name: "compact-waiting", items: [item(.waiting, id: "w", title: "Waiting", message: "Waiting for your next prompt.", tty: "/dev/ttys004", received: now.addingTimeInterval(-60))], band: 31, island: menuBar),
            Case(name: "done-hover", items: [item(.finished, id: "f", title: "Done", config: atlasConfig, received: now)], setup: .hover),
            Case(name: "compact-floating", items: [item(.finished, id: "f", title: "Done", config: atlasConfig, received: now)], band: 0, island: .zero),
            Case(name: "compact-queue", items: [
                item(.finished, id: "f1", session: "a", title: "Done", config: atlasConfig, received: now.addingTimeInterval(-30)),
                item(.waiting, id: "w2", source: "codex", session: "b", title: "Waiting", cwd: "/tmp/noordhaven-web", config: "/tmp/unknown-codex", received: now)]),
            Case(name: "codex-waiting", items: [item(.waiting, id: "w", source: "codex", title: "Codex is waiting", cwd: "/tmp/noordhaven-web", config: "/tmp/unknown-codex", received: now)]),
            Case(name: "opencode-done", items: [item(.finished, id: "f", source: "opencode", title: "Done", cwd: "/tmp/rijnstaal-docs", received: now)], band: 31, island: menuBar),
            Case(name: "compact-copied", items: [item(.waiting, id: "w", source: "codex", title: "Waiting", cwd: "/tmp/noordhaven-web", config: "/tmp/unknown-codex", received: now)], setup: .notice(.copiedForChat)),
            // Reply cards grown out of the pill.
            Case(name: "compact-reply-open", items: [item(.finished, id: "f", title: "Done", config: atlasConfig, tty: "/dev/ttys004", received: now, deadline: held)], setup: .reply("Add the retry queue next, and keep the old CSV reader for now")),
            Case(name: "compact-reply-empty", items: [item(.finished, id: "f", title: "Done", config: atlasConfig, received: now, deadline: held)], setup: .reply(nil)),
            Case(name: "compact-reply-copy", items: [item(.waiting, id: "w", source: "codex", title: "Waiting", cwd: "/tmp/noordhaven-web", config: "/tmp/unknown-codex", received: now)], setup: .reply("Use the staging database")),
            Case(name: "compact-reply-error", items: [item(.finished, id: "f", title: "Done", tty: "/dev/ttys004", received: now)], setup: .notice(.automationDenied(app: "Terminal"))),
            // Cards with content.
            Case(name: "permission", items: [item(.permission, id: "p", title: "Run a command?", message: "Claude wants to run a shell command in meridian-api.", preview: command, config: atlasConfig, tty: "/dev/ttys004", received: now.addingTimeInterval(-40), deadline: now.addingTimeInterval(50), tool: "Bash")]),
            Case(name: "permission-preview-open", items: [item(.permission, id: "p", title: "Run a command?", message: "Claude wants to run a shell command in meridian-api.", preview: command, config: atlasConfig, received: now.addingTimeInterval(-40), deadline: now.addingTimeInterval(50), tool: "Bash")], setup: .preview),
            Case(name: "permission-deny-note", items: [item(.permission, id: "p", title: "Edit a file?", message: "Claude wants to edit src/sync.ts.", preview: "src/sync.ts", config: atlasConfig, received: now.addingTimeInterval(-80), deadline: now.addingTimeInterval(8), tool: "Edit")], setup: .note),
            Case(name: "question-other", items: [item(.question, id: "q", title: "Claude has a question", message: threeOptions.question, questions: [threeOptions], tty: "/dev/ttys004", received: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(80))], setup: .other("Postgres in Docker, seeded from fixtures")),
            Case(name: "question-multi-select", items: [item(.question, id: "q", title: "Claude has a question", message: multi.question, questions: [multi], received: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(80))], setup: .select([0, 2])),
            Case(name: "question-read-only", items: [item(.question, id: "q", title: "Claude has a question", message: threeOptions.question, questions: [threeOptions], received: now.addingTimeInterval(-200))]),
            Case(name: "queue-of-three", items: [
                item(.permission, id: "p", session: "a", title: "Run a command?", message: "Claude wants to run tests.", preview: "swift test --filter Atlas", config: atlasConfig, received: now.addingTimeInterval(-30), deadline: now.addingTimeInterval(60), tool: "Bash"),
                item(.waiting, id: "w", source: "codex", session: "b", title: "Codex is waiting", message: "Waiting for input.", received: now.addingTimeInterval(-90)),
                item(.finished, id: "f", session: "c", title: "Done", message: "Updated the README.", tty: "/dev/ttys004", received: now.addingTimeInterval(-300))]),
            // Reduce Transparency: opaque surface, same geometry.
            Case(name: "reduce-transparency-permission", items: [item(.permission, id: "p", title: "Run a command?", message: "Claude wants to run a shell command.", preview: "npm run migrate -- --env staging", received: now.addingTimeInterval(-40), deadline: now.addingTimeInterval(50), tool: "Bash")], style: .opaque),
            Case(name: "reduce-transparency-pill", items: [item(.finished, id: "f", title: "Done", config: atlasConfig, received: now)], style: .opaque),
        ]
        for value in cases {
            let center = AttentionCenter()
            let controller = AttentionPanelController(center: center, model: model)
            controller.showsWindow = false; controller.notchHeight = value.band; controller.origin = value.island; controller.start()
            value.items.forEach(center.post)
            let current = try XCTUnwrap(controller.current)
            switch value.setup {
            case .none: break
            case .reply(let draft): controller.openReply(current); if let draft { controller.drafts[current.id] = draft }
            case .hover: controller.hovered = true
            case .notice(let error):
                if !error.isInformational { controller.openReply(current); controller.drafts[current.id] = "Ship it" }
                controller.setNotice(error, for: current.id)
            case .other(let text): controller.toggleOther(current, question: 0); controller.setOther(text, for: current, question: 0)
            case .select(let options): options.forEach { controller.toggle(current, question: 0, option: $0) }
            case .note: controller.noteOpen.insert(current.id); controller.notes[current.id] = "Use a feature branch instead"
            case .preview: controller.togglePreview(current.id)
            }
            let width = AttentionPanelController.cardWidth + AttentionPanelController.margin * 2
            let root = AttentionPanelView(controller: controller, style: value.style).padding(.bottom, 24)
                .background(LinearGradient(colors: [.indigo, .teal.opacity(0.8), .gray], startPoint: .topLeading, endPoint: .bottomTrailing))
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let view = NSHostingView(rootView: root.frame(width: width))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            try await Task.sleep(for: .milliseconds(200))
            let height = max(120, view.fittingSize.height)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(for: .milliseconds(500))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(height, 560, "\(value.name) must fit on a laptop screen")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(value.name + ".png"))
            if value.band > 0 {
                // The black band's top row spans the shape (shoulders included) and must be centered on the island.
                let row = 1, black = (0..<bitmap.pixelsWide).filter { x in (bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB)).map { max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.04 } ?? false }
                let scale = CGFloat(bitmap.pixelsWide) / width
                let body = AttentionPanelController.shapeWidth(controller.presentation(for: current)) * scale
                if let first = black.first, let last = black.last {
                    XCTAssertEqual(CGFloat(first + last + 1) / 2, CGFloat(bitmap.pixelsWide) / 2, accuracy: scale, "\(value.name): band centered")
                    // Wider than the body (the shoulders flare into the top edge), never wider than body plus both shoulders.
                    XCTAssertGreaterThan(CGFloat(last - first + 1), body, "\(value.name): shoulders")
                    XCTAssertLessThanOrEqual(CGFloat(last - first + 1), body + 2 * NotchShape.shoulderSize * scale + scale, "\(value.name): band width")
                } else { XCTFail("\(value.name): no black band found") }
            }
            window.close(); controller.stop()
        }
    }

}
