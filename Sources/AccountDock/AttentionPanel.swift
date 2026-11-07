import AppKit
import SwiftUI
import Combine
import DockCore

/// How the pop-up shows an item. Finished turns and idle prompts are a one-row pill (who, done, Reply, Open); requests
/// that need a decision, and a pill whose Reply was clicked, are a card with content. All three are the same shape.
enum AttentionPresentation: Equatable, Sendable { case compact, reply, full }

/// The interactive notch pop-up: shows the most urgent `AttentionCenter` item and answers it (allow, deny, pick or type an
/// answer, reply). It never takes keyboard focus unless the user clicks Reply or into a text field.
@MainActor
final class AttentionPanelController: ObservableObject {
    nonisolated static let cardWidth: CGFloat = 440
    /// Width of the compact pill and the reply card that grows out of it.
    nonisolated static let pillWidth: CGFloat = 380
    /// Height of the pill's one row below the notch band.
    nonisolated static let pillRow: CGFloat = 52
    /// Shared left and right inset of every row in every presentation.
    nonisolated static let inset: CGFloat = 16
    /// Transparent room around the card for its shadow and the spring's small overshoot.
    nonisolated static let margin: CGFloat = 24
    static let autoHideDelay: TimeInterval = 5
    /// While the user types a reply, a held hook is asked to wait this long from now, at most once per `extendThrottle`.
    nonisolated static let holdExtension: TimeInterval = 120
    nonisolated static let extendThrottle: TimeInterval = 10
    static let openDuration = 0.55, closeDuration = 0.40, contentFade = 0.22, reducedFade = 0.16

    @Published private(set) var items: [AgentAttention] = []
    @Published private(set) var currentID: String?
    @Published private(set) var revealed = false
    @Published private(set) var sendingID: String?
    @Published private(set) var notice: (id: String, error: TerminalReplyError)?
    @Published var drafts: [String: String] = [:]
    @Published var notes: [String: String] = [:]
    @Published var noteOpen: Set<String> = []
    @Published var expanded: Set<String> = []
    /// Permission requests whose command preview shows every line.
    @Published var previewOpen: Set<String> = []
    /// Pills that turned into a reply card.
    @Published private(set) var replyOpen: Set<String> = []
    @Published private(set) var focusedReply: String?
    /// Chosen option indexes per item, then per question.
    @Published var selections: [String: [Int: Set<Int>]] = [:]
    /// Questions whose "Other…" field is open, and the text typed there, per item.
    @Published private(set) var otherOpen: [String: Set<Int>] = [:]
    @Published var otherText: [String: [Int: String]] = [:]
    /// +1 or -1 after the pager moved, 0 when the queue changed by itself. Drives the direction of the content slide.
    @Published private(set) var pageDirection = 0
    @Published var hovered = false {
        didSet { if oldValue != hovered { lastActivity = now(); scheduleAutoHide() } }
    }
    /// Height of the black band that continues the notch or the collapsed island in the menu bar (0 when the strip floats).
    @Published var notchHeight: CGFloat = 0
    /// Size of the collapsed island the pop-up grows out of, so opening reads as one shape morphing out of the notch.
    @Published var origin: CGSize = .zero
    /// Horizontal center of that island on screen; the pop-up's shape is centered on it at every size.
    var islandMidX: CGFloat?
    /// False in tests and renders: state updates as usual, but no window is put on screen.
    var showsWindow = true

    let center: AttentionCenter
    let model: DockModel
    var reply = TerminalReply()
    var isWorking: (AgentAttention) -> Bool
    var now: () -> Date
    /// Seams (replaceable entry points) so tests never touch the real pasteboard or open apps.
    var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    var openSession: ((AgentAttention) -> Void)?
    private var hiddenIDs: Set<String> = []
    private var pinned = false
    private var lastExtended: [String: Date] = [:]
    private(set) var lastActivity = Date()
    private var panel: AttentionWindow?
    private var contentHeight: CGFloat = 180
    private var subscriptions = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var holdWork: DispatchWorkItem?
    private(set) var isPresenting = false

    init(center: AttentionCenter, model: DockModel, now: @escaping () -> Date = Date.init) {
        self.center = center; self.model = model; self.now = now
        isWorking = { [weak model] item in model?.companions.sessions.first { $0.id == item.sessionID }?.state == .working }
    }

    var current: AgentAttention? { items.first { $0.id == currentID } }
    var position: (index: Int, count: Int) { (items.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? 0, items.count) }
    var enabled: Bool { model.preferences.attentionPopups != false }
    /// While the strip is open it covers the same spot; the pop-up folds back into the island and returns when it closes.
    private(set) var stripOpen = false
    static let stripExpansionChanged = Notification.Name("ProfileDockStripExpansionChanged")

    func start() {
        center.$items.sink { [weak self] items in self?.update(items) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: Self.stripExpansionChanged).sink { [weak self] note in
            guard let self else { return }
            let open = note.userInfo?["expanded"] as? Bool ?? false
            guard open != self.stripOpen else { return }
            self.stripOpen = open; self.present()
        }.store(in: &subscriptions)
        model.$preferences.map(\.attentionPopups).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.present() }
        }.store(in: &subscriptions)
    }
    func stop() {
        subscriptions.removeAll()
        [hideWork, closeWork, shrinkWork, holdWork].forEach { $0?.cancel() }
        panel?.orderOut(nil); panel = nil; isPresenting = false
    }

    /// Applies a new queue from the center. Items the pop-up already auto-hid stay out of it; the strip still lists them.
    func update(_ all: [AgentAttention]) {
        let ids = Set(all.map(\.id))
        hiddenIDs.formIntersection(ids)
        drafts = drafts.filter { ids.contains($0.key) }; notes = notes.filter { ids.contains($0.key) }
        selections = selections.filter { ids.contains($0.key) }
        otherOpen = otherOpen.filter { ids.contains($0.key) }; otherText = otherText.filter { ids.contains($0.key) }
        lastExtended = lastExtended.filter { ids.contains($0.key) }
        noteOpen.formIntersection(ids); expanded.formIntersection(ids); previewOpen.formIntersection(ids); replyOpen.formIntersection(ids)
        if let focused = focusedReply, !ids.contains(focused) { focusedReply = nil }
        let previous = currentID
        items = all.filter { !hiddenIDs.contains($0.id) }
        currentID = Self.pick(current: previous, items: items, sticky: pinned || hovered || isEngaged(previous))
        if currentID != previous {
            pinned = false; pageDirection = 0; lastActivity = now()
            if notice?.id != currentID { notice = nil }
        }
        present()
    }

    /// The user is typing or has a reply card open for this item, so the queue must not swap it away.
    private func isEngaged(_ id: String?) -> Bool {
        guard let id else { return false }
        func filled(_ text: String?) -> Bool { !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return replyOpen.contains(id) || focusedReply == id || filled(drafts[id]) || filled(notes[id]) || (otherText[id] ?? [:]).values.contains { filled($0) }
    }

    /// Keeps the item the user is working with; otherwise shows the most urgent one (the center sorts by urgency).
    static func pick(current: String?, items: [AgentAttention], sticky: Bool) -> String? {
        guard let first = items.first else { return nil }
        guard let current, let shown = items.first(where: { $0.id == current }) else { return first.id }
        if sticky || first.id == shown.id { return current }
        return AttentionCenter.urgency(first, shown) ? first.id : current
    }

    /// Finished turns and idle prompts are a pill; permission requests and questions show their content.
    nonisolated static func presentation(for item: AgentAttention, replying: Bool) -> AttentionPresentation {
        switch item.kind {
        case .permission, .question: return .full
        case .finished, .waiting: return replying ? .reply : .compact
        }
    }
    func presentation(for item: AgentAttention) -> AttentionPresentation { Self.presentation(for: item, replying: replyOpen.contains(item.id)) }

    /// A pill leaves the pop-up after five quiet seconds (it stays in the center, so the strip still lists it).
    static func shouldAutoHide(_ item: AgentAttention, lastActivity: Date, now: Date, hovered: Bool, draft: String, sending: Bool, replying: Bool = false) -> Bool {
        presentation(for: item, replying: replying) == .compact && !hovered && !sending
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && now.timeIntervalSince(lastActivity) >= autoHideDelay
    }

    /// The profile that owns a session: its terminal tab by TTY, then a separate Claude account by `CLAUDE_CONFIG_DIR`
    /// (or a Codex profile by `CODEX_HOME`), then the shared Claude or agent entry. Nil shows the agent's own icon.
    static func profile(for item: AgentAttention, profiles: [Profile], home: URL) -> Profile? {
        if let tty = item.tty, let profile = profiles.first(where: { $0.tracksTerminalWindow && $0.terminalTTY == tty }) { return profile }
        func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let directory = item.configDirectory.map(normalized)
        switch item.source {
        case "claude":
            if let directory, directory != normalized(home.appendingPathComponent(".claude").path) {
                return profiles.first { $0.claudeConfigPath(in: home).map(normalized) == directory }
            }
            return profiles.first { $0.kind == .claude && !$0.usesSeparateClaudeAccount } ?? profiles.first { $0.kind == .claudeCode }
                ?? profiles.first { $0.kind == .agent && $0.agentID == "claude" && !$0.usesIsolatedAgentHome }
        case "codex":
            if let directory, directory != normalized(home.appendingPathComponent(".codex").path) {
                return profiles.first { $0.kind == .codex && normalized($0.home(in: home).path) == directory }
            }
            return profiles.first { $0.kind == .codex && $0.id == "default" } ?? profiles.first { $0.kind == .agent && $0.agentID == "codex" && !$0.usesIsolatedAgentHome }
        default:
            return profiles.first { $0.kind == .agent && $0.agentID == item.source && !$0.usesIsolatedAgentHome }
        }
    }
    func profile(for item: AgentAttention) -> Profile? { Self.profile(for: item, profiles: model.preferences.profiles, home: model.home) }

    nonisolated static func agentName(_ item: AgentAttention) -> String { item.agentLabel }
    /// Pop-up headline: the profile's name, else the project folder, else the agent's name.
    nonisolated static func headline(_ item: AgentAttention, profile: Profile?) -> String {
        profile?.name ?? item.projectName ?? item.agentLabel
    }
    /// Line under the headline on the card: the agent, plus the project when the headline is the profile. Never repeats the headline.
    nonisolated static func subtitle(_ item: AgentAttention, profile: Profile?) -> String {
        let parts = [item.agentLabel] + (profile != nil ? [item.projectName].compactMap { $0 } : [])
        return parts.filter { $0 != headline(item, profile: profile) }.joined(separator: " · ")
    }
    /// Line under the headline on the pill: "Done · meridian-api", or the agent when no profile matched ("Waiting · Codex").
    nonisolated static func compactSubtitle(_ item: AgentAttention, profile: Profile?) -> String {
        let status = item.kind == .waiting ? "Waiting" : "Done"
        let detail = profile != nil ? item.projectName : item.agentLabel
        return ([status] + [detail].compactMap { $0 }.filter { $0 != headline(item, profile: profile) }).joined(separator: " · ")
    }
    nonisolated static func answerLabel(_ item: AgentAttention) -> String { "Answer in \(item.agentLabel)" }

    /// Time left before the agent's own dialog takes over. Plain digits (no locale grouping such as "3.586s").
    nonisolated static func countdown(_ left: TimeInterval) -> String {
        let seconds = Int(max(0, left).rounded(.up))
        return seconds < 100 ? "\(seconds)s" : "\((seconds + 59) / 60) min"
    }

    /// "now", "4 min", "2 h", "3 d".
    nonisolated static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    // MARK: Geometry

    /// Panel frame: centered on the island (or the screen) and hanging from the screen's top edge when it grows out of the
    /// island; below the menu bar when the strip floats. Snapped to half points so the center stays exact on Retina.
    nonisolated static func frame(screen: CGRect, visible: CGRect, notchHeight: CGFloat, contentHeight: CGFloat, islandMidX: CGFloat? = nil) -> CGRect {
        let width = cardWidth + margin * 2, height = ceil(contentHeight) + margin
        let top = notchHeight > 0 ? screen.maxY : visible.maxY - 6
        let midX = islandMidX ?? screen.midX
        return CGRect(x: ((midX - width / 2) * 2).rounded() / 2, y: top - height, width: width, height: height)
    }
    /// Width of the shape's body (shoulders excluded) for a presentation.
    nonisolated static func shapeWidth(_ presentation: AttentionPresentation) -> CGFloat { presentation == .full ? cardWidth : pillWidth }
    /// The shape inside the panel, in screen coordinates: horizontally centered, hanging from the panel's top edge.
    nonisolated static func shapeFrame(panel: CGRect, size: CGSize) -> CGRect {
        CGRect(x: panel.midX - size.width / 2, y: panel.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: Actions

    func allow(_ item: AgentAttention) { center.respond(item.id, .allow) }
    func deny(_ item: AgentAttention, note: String? = nil) {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        center.respond(item.id, .deny(message: text?.isEmpty == false ? text : nil))
    }
    func answer(_ item: AgentAttention, labels: [String]) { center.respond(item.id, .answer(labels)) }
    /// Answers, one entry per question (multi-select joined with ", "). Text typed under "Other…" replaces a single choice
    /// and joins a multiple choice. Nil until every question has an answer.
    static func labels(for item: AgentAttention, selection: [Int: Set<Int>], other: [Int: String] = [:]) -> [String]? {
        var labels: [String] = []
        for (index, question) in item.questions.enumerated() {
            let chosen = (selection[index] ?? []).sorted().filter { question.options.indices.contains($0) }.map { question.options[$0].label }
            let typed = (other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = typed.isEmpty ? chosen : question.multiSelect ? chosen + [typed] : [typed]
            guard !parts.isEmpty else { return nil }
            labels.append(parts.joined(separator: ", "))
        }
        return labels.isEmpty ? nil : labels
    }
    func toggle(_ item: AgentAttention, question: Int, option: Int) {
        var chosen = selections[item.id]?[question] ?? []
        if item.questions.indices.contains(question), item.questions[question].multiSelect {
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
        } else {
            chosen = [option]
            otherOpen[item.id]?.remove(question)
            otherText[item.id]?[question] = nil
        }
        selections[item.id, default: [:]][question] = chosen
        lastActivity = now()
    }
    /// Shows or hides the "Other…" field of a question. A single choice and typed text exclude each other.
    func toggleOther(_ item: AgentAttention, question: Int) {
        if otherOpen[item.id]?.contains(question) == true {
            otherOpen[item.id]?.remove(question); otherText[item.id]?[question] = nil
        } else {
            otherOpen[item.id, default: []].insert(question)
            if item.questions.indices.contains(question), !item.questions[question].multiSelect { selections[item.id]?[question] = nil }
            takeKeyboard()
        }
        lastActivity = now()
    }
    func setOther(_ text: String, for item: AgentAttention, question: Int) { otherText[item.id, default: [:]][question] = text; lastActivity = now() }
    /// Sends the typed "Other…" answer of a single question right away.
    func answerOther(_ item: AgentAttention, question: Int) {
        guard let labels = Self.labels(for: item, selection: selections[item.id] ?? [:], other: otherText[item.id] ?? [:]) else { return }
        relinquishFocus(); answer(item, labels: labels)
    }

    /// The agent's own dialog takes over (also what Esc and the close button do for a request).
    func dismiss(_ item: AgentAttention) { center.dismiss(item.id) }
    func answerInSession(_ item: AgentAttention) { center.dismiss(item.id); open(item, hide: false) }
    /// Open on the pill: a held hook is released first so the agent is free when the user arrives.
    func openFromPill(_ item: AgentAttention) { if item.awaitsDecision { answerInSession(item) } else { open(item) } }
    func page(_ delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == currentID }), !items.isEmpty else { return }
        pageDirection = delta > 0 ? 1 : -1
        currentID = items[(index + delta + items.count) % items.count].id
        pinned = true; lastActivity = now(); notice = nil
        scheduleAutoHide()
    }

    // MARK: Reply

    func openReply(_ item: AgentAttention) {
        guard presentation(for: item) == .compact else { return }
        takeKeyboard()
        replyOpen.insert(item.id); pinned = true
        if notice?.id == item.id { notice = nil }
        lastActivity = now(); scheduleAutoHide()
    }
    /// Esc or a second click on Reply: back to the pill, keeping the draft.
    func closeReply(_ item: AgentAttention) {
        replyOpen.remove(item.id)
        if focusedReply == item.id { focusedReply = nil }
        relinquishFocus()
        lastActivity = now(); scheduleAutoHide()
    }
    func toggleReply(_ item: AgentAttention) { replyOpen.contains(item.id) ? closeReply(item) : openReply(item) }
    func setDraft(_ text: String, for id: String) { drafts[id] = text; lastActivity = now(); keepHolding(id); scheduleAutoHide() }
    func replyFocusChanged(_ id: String, focused: Bool) {
        if focused { focusedReply = id } else if focusedReply == id { focusedReply = nil }
        lastActivity = now(); keepHolding(id); scheduleAutoHide()
    }

    nonisolated static func shouldExtendHold(lastExtended: Date?, now: Date) -> Bool {
        lastExtended.map { now.timeIntervalSince($0) >= extendThrottle } ?? true
    }
    /// While the reply field is focused or holds text, a held Stop hook keeps the agent waiting (throttled), and a quiet
    /// timer repeats this every minute so a slow typist never loses the session.
    func keepHolding(_ id: String) {
        holdWork?.cancel(); holdWork = nil
        guard let item = center.items.first(where: { $0.id == id }), item.awaitsDecision, item.kind == .finished || item.kind == .waiting,
              focusedReply == id || TerminalReply.normalized(drafts[id] ?? "") != nil else { return }
        let time = now()
        if Self.shouldExtendHold(lastExtended: lastExtended[id], now: time) {
            lastExtended[id] = time
            center.extendHold(id, until: time.addingTimeInterval(Self.holdExtension))
        }
        guard showsWindow else { return }
        let work = DispatchWorkItem { [weak self] in self?.keepHolding(id) }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Sends the draft by the best route for this item: the held hook, the session's terminal, or the pasteboard plus the
    /// open chat. Text is never dropped: on failure the draft and the reply card stay.
    @discardableResult
    func sendReply(_ item: AgentAttention) -> Task<Void, Never>? {
        guard sendingID == nil else { return nil }
        guard let text = TerminalReply.normalized(drafts[item.id] ?? "") else { notice = (item.id, .emptyText); return nil }
        // Re-check against the live queue: a reply goes only to an item that is still there.
        guard let live = center.items.first(where: { $0.id == item.id }) else { notice = (item.id, .notWaiting); return nil }
        notice = nil
        switch ReplyRoute.for(live) {
        case .decision:
            finishReply(item.id)
            center.respond(item.id, .reply(text))
            return nil
        case .pasteboard:
            copyToPasteboard(text)
            finishReply(item.id)
            notice = (item.id, .copiedForChat)
            if let openSession { openSession(live) } else { open(live, hide: false) }
            lastActivity = now(); scheduleAutoHide()
            return nil
        case .terminal:
            let working = isWorking(live), reply = reply
            sendingID = item.id
            return Task { [weak self] in
                do {
                    try await reply.send(text, to: live, working: working)
                    guard let self else { return }
                    self.sendingID = nil
                    self.finishReply(item.id)
                    self.center.dismiss(item.id)
                } catch {
                    guard let self else { return }
                    self.sendingID = nil
                    self.notice = (item.id, error as? TerminalReplyError ?? .failed(error.localizedDescription))
                    self.lastActivity = self.now(); self.scheduleAutoHide()
                }
            }
        }
    }
    private func finishReply(_ id: String) {
        drafts[id] = nil; replyOpen.remove(id)
        if focusedReply == id { focusedReply = nil }
        holdWork?.cancel(); holdWork = nil
        relinquishFocus()
    }

    /// Brings the agent's session forward: its terminal tab by TTY, otherwise its profile's app.
    func open(_ item: AgentAttention, hide: Bool = true) {
        let profile = profile(for: item)
        if let tty = item.tty, TerminalReply.validTTY(tty) {
            if let profile, profile.tracksTerminalWindow, profile.terminalTTY == tty { model.select(profile) }
            else if let window = model.companions.windows.first(where: { $0.tty == tty }) { focus { try await TerminalClient.shared.select(window) } }
            else if let hosted = model.companions.hostedWindows.first(where: { $0.tty == tty }) {
                if hosted.host == TerminalReply.iTermBundle { focus { try await TerminalClient.shared.selectInITerm(tty: tty) } }
                else if let pid = hosted.hostProcess { NSRunningApplication(processIdentifier: pid)?.activate() }
            }
        } else if item.source == "claude" || item.source == "codex" { openChat(item, profile: profile) }
        else if let profile { model.select(profile) }
        else if let tool = AgentRegistry.tool(id: item.source) {
            AgentBrand.bundleIdentifiers(for: tool).lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first?.activate()
        }
        if hide && !item.awaitsDecision { hiddenIDs.insert(item.id); update(center.items) }
    }

    /// Opens the exact chat in its desktop app (Claude Desktop's Code session or the Codex app's thread), in the running
    /// instance of that account. Falls back to bringing the profile's app forward when the chat cannot be found.
    private func openChat(_ item: AgentAttention, profile: Profile?) {
        let pid = profile.flatMap { model.running[$0.id]?.first?.processIdentifier }
        let root = SessionLinks.claudeSessionsRoot(for: profile, home: model.home)
        let session = item.sessionID, codex = item.source == "codex", desktop = item.entrypoint == "claude-desktop"
        Task { [weak self] in
            let url: URL? = codex ? SessionLinks.codexURL(thread: session)
                : await Task.detached(priority: .userInitiated) { SessionLinks.claudeLocalSession(forCLISession: session, root: root).flatMap(SessionLinks.claudeURL) }.value
            guard let self else { return }
            if let url { SessionLinks.open(url, processIdentifier: pid) }
            else if let profile { self.model.select(profile) }
            else if desktop { NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first?.activate() }
        }
    }
    private func focus(_ action: @escaping @Sendable () async throws -> Void) {
        let id = currentID ?? ""
        Task { [weak self] in
            do { try await action() } catch {
                self?.notice = (id, error as? TerminalClientError == .automationDenied ? .automationDenied(app: "Terminal") : .sessionGone)
            }
        }
    }
    func setNotice(_ error: TerminalReplyError?, for id: String) { notice = error.map { (id, $0) }; lastActivity = now() }
    func openAutomationSettings() { NSWorkspace.shared.open(DockModel.automationSettings) }
    func toggleExpanded(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    func togglePreview(_ id: String) { if previewOpen.contains(id) { previewOpen.remove(id) } else { previewOpen.insert(id) } }
    func openNote(_ item: AgentAttention) { noteOpen.insert(item.id); takeKeyboard() }

    /// Whether the pop-up currently shows a session of this profile, so the small activity cue can stay away.
    func isShowing(profileID: String) -> Bool {
        guard isPresenting, let item = current else { return false }
        return profile(for: item)?.id == profileID
    }

    // MARK: Panel

    private func present() {
        guard showsWindow else { isPresenting = enabled && current != nil; revealed = isPresenting; scheduleAutoHide(); return }
        if enabled, current != nil, !stripOpen { show() } else { hide() }
        scheduleAutoHide()
    }
    /// The display the user is looking at (where the pointer is), so the pop-up grows out of that display's island.
    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func panelFrame(on screen: NSScreen, height: CGFloat) -> CGRect {
        Self.frame(screen: screen.frame, visible: screen.visibleFrame, notchHeight: notchHeight, contentHeight: height, islandMidX: islandMidX)
    }

    private func show() {
        guard let screen = targetScreen() else { return }
        closeWork?.cancel(); closeWork = nil
        if model.placement == .topCenter {
            // Grow out of the collapsed island: the notch itself, or the black island in the menu bar.
            let island = IslandController.layout(screen: screen, model: model).collapsed
            notchHeight = island.height; origin = island.size; islandMidX = island.midX
        } else { notchHeight = 0; origin = .zero; islandMidX = nil }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(panelFrame(on: screen, height: contentHeight), display: true)
        guard !isPresenting else { return }
        isPresenting = true
        panel.orderFrontRegardless()
        if let item = current {
            let text = presentation(for: item) == .compact ? "\(Self.headline(item, profile: profile(for: item))): \(Self.compactSubtitle(item, profile: profile(for: item)))" : "\(item.title). \(item.message)"
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        // One run loop later, so SwiftUI draws the folded state first and springs out of the notch.
        DispatchQueue.main.async { [weak self] in if self?.isPresenting == true { self?.revealed = true } }
    }
    private func hide() {
        guard isPresenting, let panel else { return }
        isPresenting = false; revealed = false; hovered = false
        let work = DispatchWorkItem { [weak self, weak panel] in panel?.orderOut(nil); self?.closeWork = nil }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.reducedFade : Self.closeDuration), execute: work)
    }
    private func makePanel() -> AttentionWindow {
        let panel = AttentionWindow(contentRect: CGRect(x: 0, y: 0, width: Self.cardWidth + Self.margin * 2, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ProfileDock: an agent needs you"
        // Above the strip (+1) and the small activity cue (+2).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        // Becomes key only for views that need typing (the reply field), so buttons never take focus from other apps.
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = AttentionHostingView(rootView: AttentionPanelView(controller: self))
        return panel
    }
    /// Grows the window at once; shrinks it only after the shape's close spring, so the morph is never clipped.
    func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        let apply = { [weak self] in
            guard let self else { return }
            self.contentHeight = height
            if self.isPresenting, let panel = self.panel, let screen = self.targetScreen() { panel.setFrame(self.panelFrame(on: screen, height: height), display: true) }
        }
        guard height < contentHeight, isPresenting, showsWindow else { apply(); return }
        let work = DispatchWorkItem(block: apply)
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration + 0.05, execute: work)
    }
    /// Lets the panel take typing (Reply, Other…, a deny note) without activating ProfileDock.
    private func takeKeyboard() { if showsWindow, isPresenting { panel?.makeKey() } }
    /// Hands the keyboard back to the app the user was in after typing.
    private func relinquishFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil); if isPresenting { panel.orderFrontRegardless() }
    }

    private func scheduleAutoHide() {
        hideWork?.cancel(); hideWork = nil
        guard isPresenting, let item = current, presentation(for: item) == .compact, !hovered else { return }
        let delay = max(0.05, lastActivity.addingTimeInterval(Self.autoHideDelay).timeIntervalSince(now()))
        let work = DispatchWorkItem { [weak self] in self?.autoHideIfDue() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func autoHideIfDue() {
        guard let item = current, Self.shouldAutoHide(item, lastActivity: lastActivity, now: now(), hovered: hovered, draft: drafts[item.id] ?? "",
                                                         sending: sendingID != nil, replying: replyOpen.contains(item.id)) else { return }
        hiddenIDs.insert(item.id)
        update(center.items)
    }
}

final class AttentionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shift-Return (and Option-Return) add a line in a reply instead of sending it; plain Return still sends.
    override func sendEvent(_ event: NSEvent) {
        if Self.isNewlineChord(event), let editor = firstResponder as? NSTextView, editor.isEditable {
            editor.insertNewlineIgnoringFieldEditor(nil); return
        }
        super.sendEvent(event)
    }
    nonisolated static func isNewlineChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 else { return false }
        let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
        return flags == .shift || flags == .option
    }
}

/// Buttons answer on the first click even though the panel is not key and ProfileDock is not active.
final class AttentionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AttentionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
/// Natural content height per item, so the one shape grows to exactly the item it shows.
private struct ItemHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { max($0, $1) } }
}

/// How the card's surface is drawn. `automatic` is Liquid Glass on macOS 26 and later.
enum AttentionSurfaceStyle { case automatic, fallback, opaque }

/// The outline the pop-up morphs through. Changes animate together, so size, shoulders and radii move as one shape.
struct AttentionBlobGeometry: Equatable {
    var size: CGSize
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var shape: NotchShape { NotchShape(shoulder: shoulder, bottomRadius: bottomRadius, topRadius: topRadius) }

    /// Folded: the island's size and small bottom corners. Open: the presentation's width (plus shoulders where it meets
    /// the top edge) and the content's height; a pill's bottom is fully round, a card's matches the strip (27).
    static func target(presentation: AttentionPresentation, contentHeight: CGFloat?, band: CGFloat, origin: CGSize, fused: Bool, open: Bool) -> AttentionBlobGeometry {
        if fused && !open { return AttentionBlobGeometry(size: origin, shoulder: 0, bottomRadius: min(12, origin.height / 2), topRadius: 2) }
        let pill = band + AttentionPanelController.pillRow
        let height = max(contentHeight ?? (presentation == .compact ? pill : band + 120), pill)
        let shoulder = fused ? NotchShape.shoulderSize : 0
        let bottom = min(27, max(12, (height - band) / 2))
        return AttentionBlobGeometry(size: CGSize(width: AttentionPanelController.shapeWidth(presentation) + 2 * shoulder, height: height),
                                     shoulder: shoulder, bottomRadius: bottom, topRadius: fused ? 2 : bottom)
    }
}

struct AttentionPanelView: View {
    @ObservedObject var controller: AttentionPanelController
    var style: AttentionSurfaceStyle = .automatic
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [String: CGFloat] = [:]
    @State private var geometry: AttentionBlobGeometry?
    @State private var lastPresentation: AttentionPresentation = .compact

    private var band: CGFloat { controller.notchHeight }
    private var fused: Bool { band > 0 && controller.origin.width > 0 }
    private var surfaceStyle: AttentionSurfaceStyle { reduceTransparency ? .opaque : style }
    private var presentation: AttentionPresentation { controller.current.map(controller.presentation(for:)) ?? lastPresentation }
    private var target: AttentionBlobGeometry {
        AttentionBlobGeometry.target(presentation: presentation, contentHeight: controller.currentID.flatMap { heights[$0] }, band: band,
                                     origin: controller.origin, fused: fused, open: controller.revealed || reduceMotion)
    }
    private var fade: Animation { .easeOut(duration: reduceMotion ? AttentionPanelController.reducedFade : AttentionPanelController.contentFade) }

    var body: some View {
        let shown = geometry ?? target
        ZStack(alignment: .top) {
            AttentionSurface(geometry: shown, band: band, fused: fused, revealed: controller.revealed, style: surfaceStyle, reduceMotion: reduceMotion)
            // Content lives inside the shape: it is clipped by it while the shape grows, and slides within it between items.
            ZStack(alignment: .top) {
                if let item = controller.current {
                    AttentionContent(controller: controller, item: item, presentation: controller.presentation(for: item), style: surfaceStyle, reduceMotion: reduceMotion)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { Color.clear.preference(key: ItemHeightKey.self, value: [item.id: $0.size.height]) })
                        .id(item.id)
                        .transition(itemTransition)
                }
            }
            .frame(width: shown.size.width, height: shown.size.height, alignment: .top)
            .clipShape(shown.shape)
            // Text appears once the shape has mostly grown, and leaves first when it folds back.
            .opacity(controller.revealed ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: AttentionPanelController.reducedFade)
                       : controller.revealed ? .easeOut(duration: AttentionPanelController.contentFade).delay(fused ? 0.16 : 0.08) : .easeOut(duration: 0.1),
                       value: controller.revealed)
        }
        .frame(width: shown.size.width, height: shown.size.height, alignment: .top)
        .contentShape(shown.shape)
        .onHover { controller.hovered = $0 }
        .frame(width: AttentionPanelController.cardWidth + 2 * NotchShape.shoulderSize, alignment: .top)
        .background(GeometryReader { Color.clear.preference(key: AttentionHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(AttentionHeightKey.self) { height in MainActor.assumeIsolated { controller.contentHeightChanged(height) } }
        .onPreferenceChange(ItemHeightKey.self) { values in MainActor.assumeIsolated { heights.merge(values) { $1 } } }
        .onAppear { geometry = target }
        .onChange(of: target) { old, new in morph(from: old, to: new) }
        .onChange(of: presentation) { _, value in lastPresentation = value }
        .padding(.horizontal, AttentionPanelController.margin - NotchShape.shoulderSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // The panel is rarely key (it never takes focus on its own), but its buttons should not look disabled.
        .environment(\.controlActiveState, .key)
    }

    /// One shape from island to pill, pill to reply card, card to card: a spring with a little overshoot growing, none
    /// shrinking (the island timings in DESIGN.md). Reduce Motion: the size changes at once and only the content fades.
    private func morph(from old: AttentionBlobGeometry, to new: AttentionBlobGeometry) {
        guard !reduceMotion else { geometry = new; return }
        let grows = new.size.height >= old.size.height && new.size.width >= old.size.width
        withAnimation(grows ? .spring(duration: AttentionPanelController.openDuration, bounce: 0.22) : .spring(duration: AttentionPanelController.closeDuration, bounce: 0)) {
            geometry = new
        }
    }

    /// Paging slides the next item in from its side; a queue change by itself cross-fades. The old content fades out fast.
    private var itemTransition: AnyTransition {
        let fadeOut = AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        guard !reduceMotion, controller.pageDirection != 0 else { return .asymmetric(insertion: .opacity.animation(fade.delay(0.06)), removal: fadeOut) }
        let insertion = AnyTransition.offset(x: CGFloat(controller.pageDirection) * 36).combined(with: .opacity)
        return .asymmetric(insertion: insertion.animation(.spring(duration: 0.35, bounce: 0)), removal: fadeOut)
    }
}

// MARK: Surface

/// The pop-up's body. Fused with the island it starts as the island itself (black, island-sized) and springs into the pill
/// or card; a black veil over the glass lifts once it has grown, so the morph reads as one solid shape.
private struct AttentionSurface: View {
    let geometry: AttentionBlobGeometry
    let band: CGFloat
    let fused: Bool
    let revealed: Bool
    let style: AttentionSurfaceStyle
    let reduceMotion: Bool
    private var glass: Bool { if #available(macOS 26, *) { return style == .automatic }; return false }

    var body: some View {
        let size = geometry.size, shape = geometry.shape
        ZStack(alignment: .top) {
            fill(size, shape)
            if fused {
                shape.fill(Color.black).frame(width: size.width, height: size.height)
                    .opacity(revealed ? 0 : 1)
                    .animation(reduceMotion ? .easeOut(duration: AttentionPanelController.reducedFade) : revealed ? .easeOut(duration: 0.26).delay(AttentionPanelController.openDuration * 0.55) : .easeOut(duration: 0.14), value: revealed)
            }
            if band > 0 {
                VStack(spacing: 0) {
                    Color.black.frame(height: band)
                    // The surface below already carries the shade, so the band fades to clear: no step where it ends.
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: StripGlass.fade)
                    Spacer(minLength: 0)
                }
                .frame(width: size.width, height: size.height).clipShape(shape)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(fused || revealed ? 1 : 0)
        .scaleEffect(fused || revealed || reduceMotion ? 1 : 0.96, anchor: .top)
        .animation(reduceMotion ? .easeOut(duration: AttentionPanelController.reducedFade) : .spring(duration: AttentionPanelController.openDuration, bounce: 0.22), value: revealed)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func fill(_ size: CGSize, _ shape: NotchShape) -> some View {
        if glass, #available(macOS 26, *) {
            // Same recipe as the strip: dark-tinted glass under a black shade, so both surfaces read as one material.
            Color.clear.frame(width: size.width, height: size.height).glassEffect(.regular.tint(.black.opacity(0.3)), in: shape)
                .overlay(shape.fill(Color.black.opacity(StripGlass.shadeOpacity)))
        } else if style == .opaque {
            ZStack { Color.black; Color.white.opacity(0.06); Color.black.opacity(StripGlass.shadeOpacity) }.frame(width: size.width, height: size.height).clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.7))
        } else {
            ZStack { AttentionBlur(); Color.black.opacity(StripGlass.shadeOpacity) }.frame(width: size.width, height: size.height).clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.7))
                .shadow(color: .black.opacity(revealed ? 0.35 : 0), radius: 16, y: 8)
        }
    }
}

// MARK: Content

private struct AttentionContent: View {
    @ObservedObject var controller: AttentionPanelController
    let item: AgentAttention
    let presentation: AttentionPresentation
    let style: AttentionSurfaceStyle
    let reduceMotion: Bool

    private var inset: CGFloat { AttentionPanelController.inset }
    private var band: CGFloat { controller.notchHeight }
    private var glass: Bool { if #available(macOS 26, *) { return style == .automatic }; return false }
    private var profile: Profile? { controller.profile(for: item) }
    private var fade: Animation { .easeOut(duration: reduceMotion ? AttentionPanelController.reducedFade : AttentionPanelController.contentFade) }
    /// Wrapped height of the whole command preview, measured off screen.
    @State private var previewHeight: CGFloat = 0
    /// Line height of the 11 pt monospaced preview font.
    static let monospacedLine: CGFloat = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 11, weight: .regular))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: band)
            if presentation == .full { card } else { pill }
        }
        .frame(width: AttentionPanelController.shapeWidth(presentation), alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.kindLabel(item)) from \(item.agentLabel)")
    }

    static func kindLabel(_ item: AgentAttention) -> String {
        switch item.kind { case .permission: return "Permission request"; case .question: return "Question"; case .waiting: return "Waiting for you"; case .finished: return "Finished" }
    }

    // MARK: Pill and reply card

    private var replying: Bool { presentation == .reply }
    private var compactNotice: TerminalReplyError? { presentation == .compact && controller.notice?.id == item.id ? controller.notice?.error : nil }

    @ViewBuilder private var pill: some View {
        HStack(spacing: 10) {
            badge
                .overlay(alignment: .topLeading) { if controller.hovered && !replying { closeDot } }
            VStack(alignment: .leading, spacing: 1) {
                Text(AttentionPanelController.headline(item, profile: profile))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                if let notice = compactNotice {
                    Label { Text(notice.localizedDescription).lineLimit(1) } icon: {
                        Image(systemName: notice.isInformational ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(notice.isInformational ? .green : .orange)
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).labelStyle(TightLabel()).help(notice.localizedDescription)
                } else {
                    Text(AttentionPanelController.compactSubtitle(item, profile: profile))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if controller.position.count > 1 { pager }
            HStack(spacing: 6) {
                PillButton(symbol: "arrow.turn.up.left", active: replying, reduceMotion: reduceMotion) { controller.toggleReply(item) }
                    .accessibilityLabel(replying ? "Close reply" : "Reply")
                    .help(replying ? "Close reply (Esc)" : "Reply to \(item.agentLabel)")
                PillButton(symbol: "arrow.up.forward.app", active: false, reduceMotion: reduceMotion) { controller.openFromPill(item) }
                    .accessibilityLabel("Open").accessibilityHint("Brings the session forward")
                    .help("Open the session")
            }
        }
        .padding(.horizontal, inset)
        .frame(height: AttentionPanelController.pillRow)
        if replying {
            replyArea
                .transition(.opacity.animation(fade.delay(reduceMotion ? 0 : 0.12)))
        }
    }

    /// Small round close in the badge's corner, shown on hover like a macOS notification's. 28 pt hit area.
    private var closeDot: some View {
        Button { controller.dismiss(item) } label: {
            Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.85)))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(reduceMotion: reduceMotion))
        .offset(x: -14 + 2, y: -14 + 2)
        .transition(.opacity.animation(.easeOut(duration: 0.12)))
        .accessibilityLabel("Dismiss")
        .help(item.awaitsDecision ? "Dismiss (the agent continues on its own)" : "Dismiss")
    }

    @ViewBuilder private var replyArea: some View {
        let route = ReplyRoute.for(item)
        let sending = controller.sendingID == item.id
        let draft = controller.drafts[item.id] ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                AttentionField(placeholder: "Reply to \(item.agentLabel)…", text: Binding(get: { controller.drafts[item.id] ?? "" }, set: { controller.setDraft($0, for: item.id) }),
                               autoFocus: true, onFocus: { controller.replyFocusChanged(item.id, focused: $0) }) {
                    controller.sendReply(item)
                }
                .disabled(sending).accessibilityLabel("Reply")
                Button { controller.sendReply(item) } label: {
                    Image(systemName: sending ? "ellipsis" : route == .pasteboard ? "doc.on.clipboard" : "arrow.up")
                        .font(.system(size: 12, weight: .bold)).frame(width: 16, height: 16)
                }
                .modifier(AttentionButton(prominent: true, glass: glass)).buttonBorderShape(.circle)
                .disabled(sending || TerminalReply.normalized(draft) == nil)
                .accessibilityLabel(route == .pasteboard ? "Copy reply and open the chat" : "Send reply")
                .help(route == .pasteboard ? "Copies your reply and opens the chat" : "Send (Return). Shift-Return adds a line.")
            }
            if route == .pasteboard {
                Text("Send copies your reply and opens the chat.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = controller.notice, notice.id == item.id { noticeRow(notice.error) }
            // Esc collapses back to the pill while the reply field has the keyboard.
            Button("") { controller.closeReply(item) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .padding(.horizontal, inset).padding(.bottom, 14)
    }

    // MARK: Full card

    @ViewBuilder private var card: some View {
        header
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if showsMessage { message }
            }
            .accessibilityElement(children: .combine)
            if let preview = item.preview, !preview.isEmpty { previewBlock(preview) }
            actions
            if let notice = controller.notice, notice.id == item.id { noticeRow(notice.error) }
        }
        .padding(.horizontal, inset).padding(.bottom, 16)
    }

    /// Same row as the pill (52 pt, badge centered), so a pill turning into a card keeps its header in place.
    private var header: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                // Which instance first (profile, else project), then the agent: two Claude Code sessions stay apart at a glance.
                Text(AttentionPanelController.headline(item, profile: profile)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                Text(AttentionPanelController.subtitle(item, profile: profile))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            // A request that holds the agent shows its time left; anything else shows its age.
            if let deadline = item.deadline { CountdownRing(start: item.receivedAt, deadline: deadline, reduceMotion: reduceMotion) }
            else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AttentionPanelController.age(of: item.receivedAt, now: context.date)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                }
            }
            if controller.position.count > 1 { pager }
            Button { controller.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(reduceMotion: reduceMotion)).keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss")
            .accessibilityHint(item.awaitsDecision ? "The agent asks in its own window instead" : "Removes this notification")
            .help(item.awaitsDecision ? "Dismiss (the agent asks in its own window)" : "Dismiss")
        }
        // The xmark glyph (not its 28 pt hit area) lines up with the 16 pt inset.
        .padding(.leading, inset).padding(.trailing, inset - 8)
        .frame(height: AttentionPanelController.pillRow)
    }

    /// The profile's artwork, else the agent's real app icon, else its monogram. Same 26 pt badge in every presentation.
    private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: 26 * 0.26, style: .continuous)
        return Group {
            if let profile { Image(nsImage: controller.model.artwork(for: profile, margin: 0)).resizable() }
            else if let tool = AgentRegistry.tool(id: item.source) {
                Image(nsImage: AgentBrand.icon(for: tool) ?? controller.model.terminalAgentArtwork(TerminalAgent(rawValue: tool.id))).resizable()
            } else {
                Text(String(item.agentLabel.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
            }
        }
        .frame(width: 26, height: 26).clipShape(shape).overlay(shape.stroke(.white.opacity(0.15), lineWidth: 0.5)).accessibilityHidden(true)
    }
    private var pager: some View {
        HStack(spacing: 0) {
            Button { controller.page(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 28).contentShape(Rectangle()) }
                .buttonStyle(PressStyle(reduceMotion: reduceMotion)).accessibilityLabel("Previous")
            Text("\(controller.position.index)/\(controller.position.count)").monospacedDigit()
                .accessibilityLabel("Item \(controller.position.index) of \(controller.position.count)")
            Button { controller.page(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 28).contentShape(Rectangle()) }
                .buttonStyle(PressStyle(reduceMotion: reduceMotion)).accessibilityLabel("Next")
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Body

    private var showsMessage: Bool {
        !item.message.isEmpty && item.message != item.title && !(item.kind == .question && item.questions.count == 1 && item.questions[0].question == item.message)
    }
    private var isLong: Bool { item.message.count > 220 || item.message.filter { $0 == "\n" }.count >= 4 }
    @ViewBuilder private var message: some View {
        let open = controller.expanded.contains(item.id)
        Text(item.message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            .lineLimit(open ? 14 : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        if isLong { moreButton(open: open, label: "message") { controller.toggleExpanded(item.id) } }
    }
    private func moreButton(open: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(open ? "Less" : "More", action: action)
            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            .frame(minHeight: 20).contentShape(Rectangle())
            .accessibilityLabel(open ? "Show less of the \(label)" : "Show the full \(label)")
    }
    private func previewBlock(_ preview: String) -> some View {
        let open = controller.previewOpen.contains(item.id)
        let font = Font.system(size: 11, design: .monospaced)
        let hidesLines = previewHeight > Self.monospacedLine * 4 + 1
        return VStack(alignment: .leading, spacing: 4) {
            if item.toolName != nil || hidesLines {
                HStack(alignment: .firstTextBaseline) {
                    if let tool = item.toolName { Text(tool).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
                    Spacer(minLength: 8)
                    if hidesLines { moreButton(open: open, label: "command") { controller.togglePreview(item.id) } }
                }
            }
            Text(preview).font(font).foregroundStyle(.white.opacity(0.88))
                .lineLimit(open ? 14 : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Measures the fully wrapped command at this width, so the toggle shows only when lines are really hidden.
                .background(GeometryReader { box in
                    Text(preview).font(font).fixedSize(horizontal: false, vertical: true).frame(width: box.size.width, alignment: .leading).hidden()
                        .background(GeometryReader { full in
                            Color.clear.onAppear { previewHeight = full.size.height }.onChange(of: full.size.height) { _, value in previewHeight = value }
                        })
                })
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.5))
                .accessibilityLabel("Command: \(preview)")
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch item.kind {
        case .permission where item.awaitsDecision: permissionActions
        case .question where item.awaitsDecision: questionActions
        case .question: readOnlyQuestions
        default:
            HStack { Spacer(); Button("Open") { controller.open(item) }.modifier(AttentionButton(prominent: true, glass: glass)) }
        }
    }

    /// "Answer in <agent>", shortened for long agent names so the footer stays on one line.
    private var answerInSession: some View {
        Button { controller.answerInSession(item) } label: {
            ViewThatFits(in: .horizontal) {
                Text(AttentionPanelController.answerLabel(item)).fixedSize()
                Text("Answer there").fixedSize()
            }
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        .frame(minHeight: 28).contentShape(Rectangle())
        .help(AttentionPanelController.answerLabel(item))
        .accessibilityLabel(AttentionPanelController.answerLabel(item))
        .accessibilityHint("Lets the agent show its own dialog")
    }

    @ViewBuilder private var permissionActions: some View {
        if controller.noteOpen.contains(item.id) {
            HStack(spacing: 8) {
                AttentionField(placeholder: "Tell the agent what to do instead", text: Binding(get: { controller.notes[item.id] ?? "" }, set: { controller.notes[item.id] = $0 }), autoFocus: true) {
                    controller.deny(item, note: controller.notes[item.id])
                }
                .accessibilityLabel("Note for the agent")
                Button("Deny") { controller.deny(item, note: controller.notes[item.id]) }.modifier(AttentionButton(prominent: false, glass: glass))
                    .accessibilityHint("Denies and sends your note")
            }
            .transition(.opacity.animation(fade))
        }
        HStack(spacing: 8) {
            answerInSession
            Spacer(minLength: 4)
            if !controller.noteOpen.contains(item.id) {
                Button("Deny with Note…") { controller.openNote(item) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).fixedSize().frame(minHeight: 28).contentShape(Rectangle())
                Button("Deny") { controller.deny(item) }.modifier(AttentionButton(prominent: false, glass: glass))
            }
            Button("Allow") { controller.allow(item) }.modifier(AttentionButton(prominent: true, glass: glass))
                .keyboardShortcut(.return, modifiers: .command).accessibilityHint("Command Return")
        }
    }

    private var answersImmediately: Bool { item.questions.count == 1 && !item.questions[0].multiSelect }
    @ViewBuilder private var questionActions: some View {
        ForEach(Array(item.questions.enumerated()), id: \.offset) { index, question in
            VStack(alignment: .leading, spacing: 6) {
                if item.questions.count > 1 || question.question != item.title {
                    if let header = question.header, !header.isEmpty { Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)) }
                    if question.question != item.title, question.question != item.message || !showsMessage {
                        Text(question.question).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                    optionButton(option, question: index, offset: offset, multi: question.multiSelect)
                }
                otherRow(question: index, multi: question.multiSelect)
            }
        }
        HStack(spacing: 8) {
            answerInSession
            Spacer(minLength: 4)
            if !answersImmediately {
                let labels = AttentionPanelController.labels(for: item, selection: controller.selections[item.id] ?? [:], other: controller.otherText[item.id] ?? [:])
                Button("Send") { if let labels { controller.answer(item, labels: labels) } }
                    .modifier(AttentionButton(prominent: true, glass: glass)).disabled(labels == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
    private func optionButton(_ option: AttentionOption, question: Int, offset: Int, multi: Bool) -> some View {
        let selected = controller.selections[item.id]?[question]?.contains(offset) == true
        return Button {
            if answersImmediately { controller.answer(item, labels: [option.label]) } else { controller.toggle(item, question: question, option: offset) }
        } label: {
            optionLabel(selected: selected, multi: multi) {
                Text(option.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if let detail = option.detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
            }
        }
        .buttonStyle(PressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel([option.label, option.detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func optionLabel<Label: View>(selected: Bool, multi: Bool, symbol: String? = nil, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(width: 14)
            } else if !answersImmediately {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 13)).foregroundStyle(selected ? Color.accentColor : .white.opacity(0.6)).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) { label() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(selected ? 0.3 : 0.1), lineWidth: 0.7))
        .contentShape(Rectangle())
    }
    /// "Other…" reveals a field for an answer the agent did not offer.
    @ViewBuilder private func otherRow(question: Int, multi: Bool) -> some View {
        let open = controller.otherOpen[item.id]?.contains(question) == true
        if open {
            HStack(alignment: .bottom, spacing: 8) {
                AttentionField(placeholder: "Type your answer", text: Binding(get: { controller.otherText[item.id]?[question] ?? "" }, set: { controller.setOther($0, for: item, question: question) }),
                               autoFocus: true, onClose: { controller.toggleOther(item, question: question) }) {
                    if answersImmediately { controller.answerOther(item, question: question) }
                }
                .accessibilityLabel("Your own answer")
                if answersImmediately {
                    let typed = (controller.otherText[item.id]?[question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    Button { controller.answerOther(item, question: question) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 16, height: 16)
                    }
                    .modifier(AttentionButton(prominent: true, glass: glass)).buttonBorderShape(.circle)
                    .disabled(typed.isEmpty).accessibilityLabel("Send answer")
                }
            }
            .transition(.opacity.animation(fade))
        } else {
            Button { controller.toggleOther(item, question: question) } label: {
                optionLabel(selected: false, multi: multi, symbol: "square.and.pencil") {
                    Text("Other…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .buttonStyle(PressStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("Other answer").accessibilityHint("Type an answer the agent did not offer")
        }
    }
    @ViewBuilder private var readOnlyQuestions: some View {
        ForEach(Array(item.questions.enumerated()), id: \.offset) { _, question in
            VStack(alignment: .leading, spacing: 4) {
                if question.question != item.title, question.question != item.message || !showsMessage {
                    Text(question.question).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    Label(option.label, systemImage: question.multiSelect ? "square" : "circle")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
        }
        HStack {
            Text("Answer this in \(item.agentLabel)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button("Open") { controller.open(item) }.modifier(AttentionButton(prominent: true, glass: glass)).accessibilityHint("Brings the session forward")
        }
    }
    private func noticeRow(_ error: TerminalReplyError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: error.isInformational ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(error.isInformational ? .green : .orange).accessibilityHidden(true)
            Text(error.localizedDescription).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if error.opensAutomationSettings {
                Button("Open Settings") { controller.openAutomationSettings() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

/// Icon and text side by side with a 4 pt gap (the default label gap is wide at 11 pt).
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.icon; configuration.title } }
}

/// Round 28 pt icon button on the pill, like the strip header's: white 0.08 fill, brighter on hover, filled when active.
private struct PillButton: View {
    let symbol: String
    let active: Bool
    let reduceMotion: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(active ? 1 : 0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(active ? Color.accentColor.opacity(0.85) : .white.opacity(hovering ? 0.16 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(reduceMotion: reduceMotion))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.16), value: active)
    }
}

/// Press feedback: a 0.96 scale (Reduce Motion: a dim instead).
private struct PressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A plain text field on a darker inset, 1 to 4 lines. Return submits; Shift-Return adds a line (`AttentionWindow`).
private struct AttentionField: View {
    let placeholder: String
    @Binding var text: String
    var autoFocus = false
    var onFocus: (Bool) -> Void = { _ in }
    /// Shows a close button inside the field's trailing edge (used by "Other…").
    var onClose: (() -> Void)? = nil
    let submit: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.45)), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
                .focused($focused)
                .onSubmit(submit)
                .padding(.leading, 10).padding(.trailing, onClose == nil ? 10 : 2).padding(.vertical, 7)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                        .frame(width: 28, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close").help("Close")
            }
        }
            .frame(minHeight: 30)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(focused ? 0.3 : 0.12), lineWidth: focused ? 1 : 0.5))
            .animation(.easeOut(duration: 0.12), value: focused)
            .onChange(of: focused) { _, value in onFocus(value) }
            // Only an empty field takes focus by itself: AppKit selects all text in a field it focuses, and typing would replace a draft.
            .onAppear { if autoFocus, text.isEmpty { DispatchQueue.main.async { focused = true } } }
    }
}

/// Native Liquid Glass buttons on macOS 26 and later; bordered system buttons before that.
private struct AttentionButton: ViewModifier {
    let prominent: Bool
    let glass: Bool
    func body(content: Content) -> some View {
        if glass, #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent).tint(.blue) } else { content.buttonStyle(.glass) }
        } else if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

/// Time left before the agent's own dialog takes over. Tied to the real deadline (which moves while the user types a
/// reply); it sweeps smoothly second by second and stops when the item goes.
private struct CountdownRing: View {
    let start: Date
    let deadline: Date
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(1, deadline.timeIntervalSince(start)), left = max(0, deadline.timeIntervalSince(context.date))
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: left / total)
                        .stroke(left <= 10 ? Color.orange : .white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
                }
                .frame(width: 16, height: 16)
                Text(verbatim: AttentionPanelController.countdown(left)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(left.rounded(.up))) seconds left to answer here")
        }
    }
}

/// The macOS 14 to 25 surface: the system HUD material (a native blur of what is behind the window).
private struct AttentionBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The pop-up's outline: flat along the top edge of the screen with concave shoulders that flare into it (as the
/// hardware notch does), straight sides and round bottom corners. Every value animates, so the island can morph into it.
struct NotchShape: Shape {
    /// Width of the concave curve on each side where the open pop-up meets the top edge of the screen.
    nonisolated static let shoulderSize: CGFloat = 10
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(shoulder, AnimatablePair(bottomRadius, topRadius)) }
        set { shoulder = newValue.first; bottomRadius = newValue.second.first; topRadius = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 4))
        let body = rect.insetBy(dx: s, dy: 0)
        let r = max(0, min(bottomRadius, body.width / 2, body.height / 2))
        if s > 0 { return shoulderPath(rect: rect, s: s, r: r) }
        return roundedPath(rect: rect, t: max(0, min(topRadius, body.width / 2, body.height / 2)), r: r)
    }

    private func shoulderPath(rect: CGRect, s: CGFloat, r: CGFloat) -> Path {
        let left = rect.minX + s, right = rect.maxX - s, top = rect.minY, bottom = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + s), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - r), radius: r)
        path.addLine(to: CGPoint(x: left, y: top + s))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }

    private func roundedPath(rect: CGRect, t: CGFloat, r: CGFloat) -> Path {
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: left + t, y: top))
        path.addLine(to: CGPoint(x: right - t, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + t), radius: t)
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - r), radius: r)
        path.addLine(to: CGPoint(x: left, y: top + t))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + t, y: top), radius: t)
        path.closeSubpath()
        return path
    }
}
