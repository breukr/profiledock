import AppKit
import SwiftUI
import Combine
import DockCore

/// The interactive notch pop-up: shows the most urgent `AttentionCenter` item and answers it (allow, deny, pick an option)
/// or types a reply into the session's terminal. It never takes keyboard focus unless the user clicks into a text field.
@MainActor
final class AttentionPanelController: ObservableObject {
    nonisolated static let cardWidth: CGFloat = 440
    /// Transparent room around the card for its shadow and the spring's small overshoot.
    nonisolated static let margin: CGFloat = 24
    static let autoHideDelay: TimeInterval = 6
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
    /// Chosen option indexes per item, then per question.
    @Published var selections: [String: [Int: Set<Int>]] = [:]
    @Published var hovered = false {
        didSet { if oldValue != hovered { lastActivity = now(); scheduleAutoHide() } }
    }
    /// Height of the black band that continues the hardware notch (0 on screens without one).
    @Published var notchHeight: CGFloat = 0
    /// False in tests and renders: state updates as usual, but no window is put on screen.
    var showsWindow = true

    let center: AttentionCenter
    let model: DockModel
    var reply = TerminalReply()
    var isWorking: (AgentAttention) -> Bool
    var now: () -> Date
    private var hiddenIDs: Set<String> = []
    private var pinned = false
    private(set) var lastActivity = Date()
    private var panel: AttentionWindow?
    private var contentHeight: CGFloat = 180
    private var subscriptions = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private(set) var isPresenting = false

    init(center: AttentionCenter, model: DockModel, now: @escaping () -> Date = Date.init) {
        self.center = center; self.model = model; self.now = now
        isWorking = { [weak model] item in model?.companions.sessions.first { $0.id == item.sessionID }?.state == .working }
    }

    var current: AgentAttention? { items.first { $0.id == currentID } }
    var position: (index: Int, count: Int) { (items.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? 0, items.count) }
    var enabled: Bool { model.preferences.attentionPopups != false }

    func start() {
        center.$items.sink { [weak self] items in self?.update(items) }.store(in: &subscriptions)
        model.$preferences.map(\.attentionPopups).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.present() }
        }.store(in: &subscriptions)
    }
    func stop() { subscriptions.removeAll(); hideWork?.cancel(); closeWork?.cancel(); panel?.orderOut(nil); panel = nil; isPresenting = false }

    /// Applies a new queue from the center. Items the pop-up already auto-hid stay out of it; the strip still lists them.
    func update(_ all: [AgentAttention]) {
        let ids = Set(all.map(\.id))
        hiddenIDs.formIntersection(ids)
        for key in drafts.keys where !ids.contains(key) { drafts[key] = nil }
        for key in notes.keys where !ids.contains(key) { notes[key] = nil }
        selections = selections.filter { ids.contains($0.key) }
        noteOpen.formIntersection(ids); expanded.formIntersection(ids)
        let previous = currentID
        items = all.filter { !hiddenIDs.contains($0.id) }
        currentID = Self.pick(current: previous, items: items, sticky: pinned || hovered || !(drafts[previous ?? ""] ?? "").isEmpty || !(notes[previous ?? ""] ?? "").isEmpty)
        if currentID != previous {
            pinned = false; lastActivity = now()
            if notice?.id != currentID { notice = nil }
        }
        present()
    }

    /// Keeps the item the user is working with; otherwise shows the most urgent one (the center sorts by urgency).
    static func pick(current: String?, items: [AgentAttention], sticky: Bool) -> String? {
        guard let first = items.first else { return nil }
        guard let current, let shown = items.first(where: { $0.id == current }) else { return first.id }
        if sticky || first.id == shown.id { return current }
        return AttentionCenter.urgency(first, shown) ? first.id : current
    }

    static func shouldAutoHide(_ item: AgentAttention, lastActivity: Date, now: Date, hovered: Bool, draft: String, sending: Bool) -> Bool {
        item.kind == .finished && !hovered && !sending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && now.timeIntervalSince(lastActivity) >= autoHideDelay
    }

    /// The profile that owns a session: its terminal tab by TTY, then a separate Claude account by `CLAUDE_CONFIG_DIR`
    /// (or a Codex profile by `CODEX_HOME`), then the shared Claude or agent entry. Nil shows the agent's own glyph.
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

    nonisolated static func agentName(_ item: AgentAttention) -> String {
        if item.source == "claude", item.entrypoint == "claude-desktop" { return "Claude" }
        return AgentRegistry.tool(id: item.source)?.name ?? item.source.capitalized
    }
    /// "now", "4 min", "2 h", "3 d".
    nonisolated static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }
    /// Panel frame: centered on the screen, hanging from the top edge on a notch screen, below the menu bar elsewhere.
    nonisolated static func frame(screen: CGRect, visible: CGRect, notchHeight: CGFloat, contentHeight: CGFloat) -> CGRect {
        let width = cardWidth + margin * 2, height = ceil(contentHeight) + margin
        let top = notchHeight > 0 ? screen.maxY : visible.maxY - 6
        return CGRect(x: (screen.midX - width / 2).rounded(), y: top - height, width: width, height: height)
    }

    // MARK: Actions

    func allow(_ item: AgentAttention) { center.respond(item.id, .allow) }
    func deny(_ item: AgentAttention, note: String? = nil) {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        center.respond(item.id, .deny(message: text?.isEmpty == false ? text : nil))
    }
    func answer(_ item: AgentAttention, labels: [String]) { center.respond(item.id, .answer(labels)) }
    /// Labels for the chosen options, one entry per question (multi-select joined with ", "). Nil until every question has a choice.
    static func labels(for item: AgentAttention, selection: [Int: Set<Int>]) -> [String]? {
        var labels: [String] = []
        for (index, question) in item.questions.enumerated() {
            let chosen = (selection[index] ?? []).sorted().filter { question.options.indices.contains($0) }
            guard !chosen.isEmpty else { return nil }
            labels.append(chosen.map { question.options[$0].label }.joined(separator: ", "))
        }
        return labels.isEmpty ? nil : labels
    }
    func toggle(_ item: AgentAttention, question: Int, option: Int) {
        var chosen = selections[item.id]?[question] ?? []
        if item.questions.indices.contains(question), item.questions[question].multiSelect {
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
        } else { chosen = [option] }
        selections[item.id, default: [:]][question] = chosen
        lastActivity = now()
    }
    /// The agent's own dialog takes over (also what Esc and the close button do for a request).
    func dismiss(_ item: AgentAttention) { center.dismiss(item.id) }
    func answerInSession(_ item: AgentAttention) { center.dismiss(item.id); open(item, hide: false) }
    func page(_ delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == currentID }), !items.isEmpty else { return }
        currentID = items[(index + delta + items.count) % items.count].id
        pinned = true; lastActivity = now(); notice = nil
        scheduleAutoHide()
    }
    func setDraft(_ text: String, for id: String) { drafts[id] = text; lastActivity = now(); scheduleAutoHide() }

    func sendReply(_ item: AgentAttention) {
        guard sendingID == nil else { return }
        let text = drafts[item.id] ?? ""
        let working = isWorking(item)
        // Re-check against the live queue: a reply goes only to an item that is still waiting.
        guard center.items.contains(where: { $0.id == item.id }) else { notice = (item.id, .notWaiting); return }
        sendingID = item.id; notice = nil
        let reply = reply
        Task { [weak self] in
            do {
                try await reply.send(text, to: item, working: working)
                guard let self else { return }
                self.sendingID = nil; self.drafts[item.id] = nil
                self.relinquishFocus()
                self.center.dismiss(item.id)
            } catch {
                guard let self else { return }
                self.sendingID = nil
                self.notice = (item.id, error as? TerminalReplyError ?? .failed(error.localizedDescription))
                self.lastActivity = self.now(); self.scheduleAutoHide()
            }
        }
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
        } else if let profile { model.select(profile) }
        else if item.entrypoint == "claude-desktop" { NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first?.activate() }
        if hide && !item.awaitsDecision { hiddenIDs.insert(item.id); update(center.items) }
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

    /// Whether the pop-up currently shows a session of this profile, so the small activity cue can stay away.
    func isShowing(profileID: String) -> Bool {
        guard isPresenting, let item = current else { return false }
        return profile(for: item)?.id == profileID
    }

    // MARK: Panel

    private func present() {
        guard showsWindow else { isPresenting = enabled && current != nil; revealed = isPresenting; scheduleAutoHide(); return }
        if enabled, current != nil { show() } else { hide() }
        scheduleAutoHide()
    }
    private func targetScreen() -> NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first }

    private func show() {
        guard let screen = targetScreen() else { return }
        closeWork?.cancel(); closeWork = nil
        notchHeight = model.placement == .topCenter ? screen.safeAreaInsets.top : 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(Self.frame(screen: screen.frame, visible: screen.visibleFrame, notchHeight: notchHeight, contentHeight: contentHeight), display: true)
        guard !isPresenting else { return }
        isPresenting = true
        panel.orderFrontRegardless()
        if let item = current {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(item.title). \(item.message)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
    func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        if isPresenting, let panel, let screen = targetScreen() {
            panel.setFrame(Self.frame(screen: screen.frame, visible: screen.visibleFrame, notchHeight: notchHeight, contentHeight: height), display: true)
        }
    }
    /// Hands the keyboard back to the app the user was in after typing a reply.
    private func relinquishFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil); if isPresenting { panel.orderFrontRegardless() }
    }

    private func scheduleAutoHide() {
        hideWork?.cancel(); hideWork = nil
        guard isPresenting, let item = current, item.kind == .finished, !hovered else { return }
        let delay = max(0.05, lastActivity.addingTimeInterval(Self.autoHideDelay).timeIntervalSince(now()))
        let work = DispatchWorkItem { [weak self] in self?.autoHideIfDue() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func autoHideIfDue() {
        guard let item = current, Self.shouldAutoHide(item, lastActivity: lastActivity, now: now(), hovered: hovered, draft: drafts[item.id] ?? "", sending: sendingID != nil) else { return }
        hiddenIDs.insert(item.id)
        update(center.items)
    }
}

final class AttentionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons answer on the first click even though the panel is not key and ProfileDock is not active.
final class AttentionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AttentionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// How the card's surface is drawn. `automatic` is Liquid Glass on macOS 26 and later.
enum AttentionSurfaceStyle { case automatic, fallback, opaque }

struct AttentionPanelView: View {
    @ObservedObject var controller: AttentionPanelController
    var style: AttentionSurfaceStyle = .automatic
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let item = controller.current {
                AttentionCard(controller: controller, item: item, style: reduceTransparency ? .opaque : style, reduceMotion: reduceMotion)
                    .id(item.id)
                    .transition(.opacity.animation(.easeOut(duration: reduceMotion ? AttentionPanelController.reducedFade : AttentionPanelController.contentFade)))
            }
        }
        .frame(width: AttentionPanelController.cardWidth)
        .background(GeometryReader { Color.clear.preference(key: AttentionHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(AttentionHeightKey.self) { height in MainActor.assumeIsolated { controller.contentHeightChanged(height) } }
        .padding(.horizontal, AttentionPanelController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // The panel is rarely key (it never takes focus on its own), but its buttons should not look disabled.
        .environment(\.controlActiveState, .key)
    }
}

private struct AttentionCard: View {
    @ObservedObject var controller: AttentionPanelController
    let item: AgentAttention
    let style: AttentionSurfaceStyle
    let reduceMotion: Bool

    private var band: CGFloat { controller.notchHeight }
    private var glass: Bool { if #available(macOS 26, *) { return style == .automatic }; return false }
    private var shape: UnevenRoundedRectangle {
        let top: CGFloat = band > 0 ? 8 : 22
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 22, bottomTrailingRadius: 22, topTrailingRadius: top, style: .continuous)
    }
    private var profile: Profile? { controller.profile(for: item) }
    private var revealed: Bool { controller.revealed }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if showsMessage { message }
            }
            .accessibilityElement(children: .combine)
            if let preview = item.preview, !preview.isEmpty { previewBlock(preview) }
            actions
            if let notice = controller.notice, notice.id == item.id { noticeRow(notice.error) }
        }
        .padding(.top, band + 10).padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: AttentionPanelController.cardWidth, alignment: .leading)
        .opacity(revealed ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: AttentionPanelController.reducedFade) : revealed ? .easeOut(duration: AttentionPanelController.contentFade).delay(0.1) : .easeOut(duration: 0.12), value: revealed)
        .background { surface }
        .onHover { controller.hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.kindLabel(item)) from \(AttentionPanelController.agentName(item))")
        if glass, #available(macOS 26, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }

    static func kindLabel(_ item: AgentAttention) -> String {
        switch item.kind { case .permission: return "Permission request"; case .question: return "Question"; case .waiting: return "Waiting for you"; case .finished: return "Finished" }
    }

    // MARK: Surface

    /// Springs out of the notch: the surface grows from notch size; Reduce Motion fades it in place.
    private var surface: some View {
        ZStack(alignment: .top) {
            surfaceFill
            if band > 0 {
                VStack(spacing: 0) {
                    Color.black.frame(height: band)
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 14)
                }
                .clipShape(shape).accessibilityHidden(true)
            }
        }
        .scaleEffect(x: revealed || reduceMotion ? 1 : 0.42, y: revealed || reduceMotion ? 1 : 0.12, anchor: .top)
        .opacity(revealed ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: AttentionPanelController.reducedFade)
                   : revealed ? .spring(duration: AttentionPanelController.openDuration, bounce: 0.18) : .spring(duration: AttentionPanelController.closeDuration, bounce: 0), value: revealed)
    }
    @ViewBuilder private var surfaceFill: some View {
        if glass, #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.5)), in: shape)
        } else if style == .opaque {
            ZStack { Color.black; Color.white.opacity(0.06) }.clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.7))
        } else {
            ZStack { AttentionBlur(); Color.black.opacity(0.35) }.clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.name ?? AttentionPanelController.agentName(item)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text(([AttentionPanelController.agentName(item)] + [item.projectName].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AttentionPanelController.age(of: item.receivedAt, now: context.date)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
            if controller.position.count > 1 { pager }
            Button { controller.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss")
            .accessibilityHint(item.awaitsDecision ? "The agent asks in its own window instead" : "Removes this notification")
            .help(item.awaitsDecision ? "Dismiss (the agent asks in its own window)" : "Dismiss")
        }
    }
    @ViewBuilder private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: 28 * 0.26, style: .continuous)
        Group {
            if let profile { Image(nsImage: controller.model.artwork(for: profile, margin: 0)).resizable() }
            else if AgentRegistry.tool(id: item.source) != nil { Image(nsImage: controller.model.terminalAgentArtwork(TerminalAgent(rawValue: item.source))).resizable() }
            else { Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12)) }
        }
        .frame(width: 28, height: 28).clipShape(shape).overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1)).accessibilityHidden(true)
    }
    private var pager: some View {
        HStack(spacing: 0) {
            Button { controller.page(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Previous")
            Text("\(controller.position.index) of \(controller.position.count)").monospacedDigit()
                .accessibilityLabel("Item \(controller.position.index) of \(controller.position.count)")
            Button { controller.page(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Next")
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
        if isLong {
            Button(open ? "Less" : "More") { controller.toggleExpanded(item.id) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel(open ? "Show less" : "Show the full message")
        }
    }
    private func previewBlock(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tool = item.toolName { Text(tool).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
            Text(preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.88))
                .lineLimit(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        default: replyActions
        }
    }
    /// Where the agent's own dialog shows: its terminal, or the app (short name so the label stays on one line).
    private var sessionPlace: String { item.tty != nil ? "Terminal" : item.source == "claude" ? "Claude" : AttentionPanelController.agentName(item) }

    @ViewBuilder private var permissionActions: some View {
        if controller.noteOpen.contains(item.id) {
            HStack(spacing: 8) {
                AttentionField(placeholder: "Tell the agent what to do instead", text: Binding(get: { controller.notes[item.id] ?? "" }, set: { controller.notes[item.id] = $0 })) {
                    controller.deny(item, note: controller.notes[item.id])
                }
                .accessibilityLabel("Note for the agent")
                Button("Deny") { controller.deny(item, note: controller.notes[item.id]) }.modifier(AttentionButton(prominent: false, glass: glass))
                    .accessibilityHint("Denies and sends your note")
            }
        }
        HStack(spacing: 8) {
            if let deadline = item.deadline { CountdownRing(start: item.receivedAt, deadline: deadline, reduceMotion: reduceMotion) }
            Button("Answer in \(sessionPlace)") { controller.answerInSession(item) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                .accessibilityHint("Lets the agent show its own dialog")
            Spacer(minLength: 4)
            if !controller.noteOpen.contains(item.id) {
                Button("Deny with Note…") { controller.noteOpen.insert(item.id) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
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
            }
        }
        HStack(spacing: 8) {
            if let deadline = item.deadline { CountdownRing(start: item.receivedAt, deadline: deadline, reduceMotion: reduceMotion) }
            Button("Answer in \(sessionPlace)") { controller.answerInSession(item) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                .accessibilityHint("Lets the agent show its own dialog")
            Spacer(minLength: 4)
            if !answersImmediately {
                let labels = AttentionPanelController.labels(for: item, selection: controller.selections[item.id] ?? [:])
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
            HStack(spacing: 8) {
                if !answersImmediately {
                    Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 13)).foregroundStyle(selected ? Color.accentColor : .white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    if let detail = option.detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(selected ? 0.3 : 0.1), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([option.label, option.detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            Text("Answer this in the session").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button("Open") { controller.open(item) }.modifier(AttentionButton(prominent: true, glass: glass)).accessibilityHint("Brings the session forward")
        }
    }
    @ViewBuilder private var replyActions: some View {
        let canReply = TerminalReply.canReply(to: item)
        let sending = controller.sendingID == item.id
        let draft = controller.drafts[item.id] ?? ""
        HStack(spacing: 8) {
            if canReply {
                AttentionField(placeholder: "Reply to \(AttentionPanelController.agentName(item))…", text: Binding(get: { controller.drafts[item.id] ?? "" }, set: { controller.setDraft($0, for: item.id) })) {
                    controller.sendReply(item)
                }
                .disabled(sending).accessibilityLabel("Reply")
                Button { controller.sendReply(item) } label: {
                    Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 16, height: 16)
                }
                .modifier(AttentionButton(prominent: true, glass: glass))
                .disabled(sending || TerminalReply.normalized(draft) == nil)
                .accessibilityLabel("Send reply")
            } else {
                Spacer()
            }
            Button("Open") { controller.open(item) }.modifier(AttentionButton(prominent: !canReply, glass: glass))
                .accessibilityHint("Brings the session forward")
        }
    }
    private func noticeRow(_ error: TerminalReplyError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
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

/// A plain text field on a darker inset. Return submits.
private struct AttentionField: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.45)), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
            .onSubmit(submit)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Native Liquid Glass buttons on macOS 26 and later; bordered system buttons before that.
private struct AttentionButton: ViewModifier {
    let prominent: Bool
    let glass: Bool
    func body(content: Content) -> some View {
        if glass, #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

/// Time left before the agent's own dialog takes over. Tied to the real deadline; it stops when the item goes.
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
                Text("\(Int(left.rounded(.up)))s").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
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
