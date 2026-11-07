import AppKit
import SwiftUI
import DockCore

struct StatusDot: View {
    let isOpen: Bool
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(isOpen ? Color(red: 0.23, green: 0.9, blue: 0.42) : Color.white.opacity(0.22))
            .frame(width: size, height: size)
            .accessibilityLabel(isOpen ? "Open" : "Closed")
    }
}

extension ProfileActivityState {
    var color: Color {
        switch self {
        case .working: return Color(red: 0.3, green: 0.65, blue: 1)
        case .waiting: return .orange
        case .unread: return Color(red: 0.98, green: 0.35, blue: 0.35)
        case .idle: return Color(red: 0.23, green: 0.9, blue: 0.42)
        case .unknown: return .white.opacity(0.5)
        case .closed: return .white.opacity(0.22)
        }
    }
}

struct ActivityDot: View {
    let state: ProfileActivityState
    var size: CGFloat = 6
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(state.color).frame(width: size, height: size)
            .background {
                if state == .working {
                    WorkingDotGlow(visible: visible, reduceMotion: reduceMotion).frame(width: size + 12, height: size + 12)
                }
            }
            .overlay { if state == .unknown { Circle().stroke(.white.opacity(0.6), lineWidth: 1).padding(-2) } }
            .accessibilityLabel(state.label)
    }
}

struct ProfileBadge: View {
    @ObservedObject var model: DockModel
    let profile: Profile
    var size: CGFloat = 54
    var showStatus = true
    var activity: ActivitySummary?
    var activityVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Badges are outlined in the color behind them: black in the strip, the window color in Settings.
    private var ring: Color { showStatus ? .black : Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: model.artwork(for: profile, margin: 0)).resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).stroke(.white.opacity(0.15), lineWidth: 1))
            .background {
                IconPulse(working: (activity?.working ?? 0) > 0, visible: activityVisible, reduceMotion: reduceMotion, cornerRadius: size * 0.26)
                    .frame(width: size + 20, height: size + 20)
            }
            if showStatus {
                if model.opening.contains(profile.id) || model.nativeDockOperations.contains(profile.id) {
                    ProgressView().controlSize(.mini).padding(4).background(.black, in: Circle()).offset(x: 4, y: 4)
                } else if model.running[profile.id]?.isEmpty == false {
                    StatusDot(isOpen: true, size: size < 44 ? 8 : 10).padding(size < 44 ? 2 : 3).background(.black, in: Circle()).offset(x: 4, y: 4)
                }
            }
        }
        .opacity(showStatus && model.agentAvailability(profile) == .missing ? 0.55 : 1)
        .overlay(alignment: .bottomLeading) {
            if showStatus, let warning = model.tileWarning(profile) {
                Image(systemName: warning.symbol).font(.system(size: max(9, size * 0.17), weight: .bold)).foregroundStyle(.black)
                    .frame(width: max(16, size * 0.34), height: max(16, size * 0.34)).background(.orange, in: Circle())
                    .overlay(Circle().stroke(ring, lineWidth: 2)).offset(x: -4, y: 4)
                    .accessibilityLabel(warning.text)
            }
        }
        .overlay(alignment: .topTrailing) {
            // An agent profile that already shows its app's real logo does not repeat it as a corner badge.
            if AgentBrand.defaultIcon(for: profile) == nil, let agent = model.terminalAgent(for: profile) ?? model.savedTerminalTool(profile) {
                Image(nsImage: model.terminalAgentArtwork(agent)).resizable()
                    .frame(width: max(16, size * 0.36), height: max(16, size * 0.36))
                    .clipShape(Circle()).overlay(Circle().stroke(ring, lineWidth: 2))
                    .offset(x: 4, y: -4)
                    .accessibilityLabel("\(agent.label) terminal")
                    .help("\(agent.label) is running in this Terminal tab")
            }
        }
        .overlay(alignment: .topLeading) {
            if let activity, let badge = activity.badge {
                Text(badge).font(.system(size: size < 44 ? 9 : 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, size < 44 ? 4 : 5).frame(minWidth: size < 44 ? 16 : 19, minHeight: size < 44 ? 16 : 19)
                    .background(Color(red: 0.93, green: 0.24, blue: 0.24), in: Capsule())
                    .overlay(Capsule().stroke(ring, lineWidth: 2)).offset(x: -7, y: -5)
                    .accessibilityLabel("\(activity.unread ?? 0) completed tasks with unread results")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let activity, activity.waiting > 0 {
                Image(systemName: "pause.fill").font(.system(size: size < 44 ? 7 : 8, weight: .bold)).foregroundStyle(.black)
                    .frame(width: size < 44 ? 16 : 20, height: size < 44 ? 16 : 20).background(.orange, in: Circle())
                    .overlay(Circle().stroke(ring, lineWidth: 2)).offset(x: -6, y: 4)
                    .accessibilityLabel("\(activity.waiting) tasks waiting for you")
            }
        }
    }
}

/// How many displayed profiles need the user, are working, or finished with unread results (each profile once).
struct StripAttention: Equatable {
    var needsYou = 0
    var working = 0
    var done = 0
    init(states: [ProfileActivityState]) {
        for state in states {
            switch state {
            case .waiting: needsYou += 1
            case .working: working += 1
            case .unread: done += 1
            default: break
            }
        }
    }
    @MainActor init(model: DockModel, activity: ActivityMonitor) {
        self.init(states: model.displayedProfiles.map { ProfileActivityState(summary: activity.entries[$0.id], isOpen: model.running[$0.id]?.isEmpty == false) })
    }
    var isEmpty: Bool { needsYou == 0 && working == 0 && done == 0 }
    /// Chips in priority order; zero counts are left out.
    var chips: [(count: Int, label: String, state: ProfileActivityState)] {
        [(needsYou, needsYou == 1 ? "needs you" : "need you", .waiting), (working, "working", .working), (done, "done", .unread)].filter { $0.0 > 0 }
    }
}

/// Frames reported by the strip for geometry tests (cards, header and section edges), in window coordinates.
struct StripFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func reportsStripFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: StripFramesKey.self, value: [key: proxy.frame(in: .global)]) })
    }
}

struct CompactIslandView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var presentation: IslandPresentation
    let drag: (DockDragPhase, CGPoint) -> Void
    var body: some View {
        GeometryReader { geometry in
        let visible = WidgetSizing.visibleDots(count: model.displayedProfiles.count, width: geometry.size.width, floating: model.placement == .free)
        let needsYou = StripAttention(model: model, activity: activity).needsYou
        HStack(spacing: 7) {
            if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22).help("Drag to move ProfileDock") }
            BrandMark(size: 11).foregroundStyle(.white.opacity(0.85))
            Text(needsYou > 0 ? "\(needsYou) \(needsYou == 1 ? "needs" : "need") you" : "Agents").font(.system(size: 10, weight: needsYou > 0 ? .semibold : .medium)).monospacedDigit()
                .foregroundStyle(needsYou > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.white.opacity(0.9))).lineLimit(1).fixedSize()
            HStack(spacing: 5) {
                ForEach(Array(model.displayedProfiles.prefix(visible))) { profile in
                    ActivityDot(state: ProfileActivityState(summary: activity.entries[profile.id], isOpen: model.running[profile.id]?.isEmpty == false), visible: !presentation.expanded)
                }
                if model.displayedProfiles.count > visible { Text("+\(model.displayedProfiles.count - visible)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)) }
            }
            Image(systemName: presentation.opensUpward ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.placement == .free ? .leading : .center)
        .padding(.horizontal, model.placement == .free ? 8 : 0)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: model.placement == .topCenter ? 2 : 12, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: model.placement == .topCenter ? 2 : 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ProfileDock, hover here to open. " + (needsYou > 0 ? "\(needsYou) \(needsYou == 1 ? "needs" : "need") you. " : "") + statusDescription)
        .help(statusDescription)
        }
    }
    private var statusDescription: String {
        model.displayedProfiles.map { "\($0.name): \(ProfileActivityState(summary: activity.entries[$0.id], isOpen: model.running[$0.id]?.isEmpty == false).label)" }.joined(separator: ". ")
    }
}

/// A 28 pt round icon button for the strip header.
private struct StripIconLabel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
    }
}

struct AttentionChips: View {
    let attention: StripAttention
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(attention.chips, id: \.label) { chip in
                HStack(spacing: 5) {
                    Circle().fill(chip.state.color).frame(width: 6, height: 6)
                    Text(compact ? "\(chip.count)" : "\(chip.count) \(chip.label)").monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(chip.state.color)
                .padding(.horizontal, 8).frame(height: 22)
                .background(chip.state.color.opacity(0.16), in: Capsule())
                .fixedSize()
                .accessibilityElement(children: .ignore).accessibilityLabel("\(chip.count) \(chip.label)")
                .help("\(chip.count) \(chip.count == 1 ? "agent" : "agents") \(chip.label == "done" ? "finished with unread results" : chip.label)")
            }
        }
    }
}

struct IslandView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var usage: UsageStore
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var insights: InsightsStore
    @ObservedObject var presentation: IslandPresentation
    let notchHeight: CGFloat
    let settings: () -> Void
    let drag: (DockDragPhase, CGPoint) -> Void
    @State private var profilePage = 0
    @State private var terminalPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
        let scale = model.preferences.scale
        let available = max(0, geometry.size.width - 2 * WidgetSizing.stripPadding)
        // The layout chooses columns for the screen; never show more than fit this width.
        let columns = max(1, min(presentation.profileColumns, WidgetSizing.columns(count: 12, available: available, scale: scale)))
        let capacity = max(1, columns * presentation.profileRows)
        let cardWidth = WidgetSizing.cardWidth(columns: columns, available: available, scale: scale)
        let desktopProfiles = Array(model.displayedProfiles.enumerated()).filter { !$0.element.kind.usesTerminal }
        let terminalProfiles = Array(model.displayedProfiles.enumerated()).filter { $0.element.kind.usesTerminal }
        let terminalPageCount = max(1, (terminalProfiles.count + capacity - 1) / capacity)
        let terminalsPage = min(terminalPage, terminalPageCount - 1)
        let pageCount = max(1, (desktopProfiles.count + capacity - 1) / capacity)
        let page = min(profilePage, pageCount - 1)
        let shownDesktops = Array(desktopProfiles.dropFirst(page * capacity).prefix(capacity))
        let shownTerminals = Array(terminalProfiles.dropFirst(terminalsPage * capacity).prefix(capacity))
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: IslandLayout.sectionGap) {
            header
            SignInNoticeBanner(usage: usage, model: model)
            if !shownDesktops.isEmpty { profileGrid(profiles: shownDesktops, columns: columns, cardWidth: cardWidth) }
            ProfileGridPagination(model: model, page: $profilePage, count: desktopProfiles.count, capacity: capacity, terminals: false)
                .frame(maxWidth: .infinity)
            if model.preferences.showTerminalsSection != false {
                terminalsHeader
                if model.preferences.terminalsExpanded != false {
                    if !shownTerminals.isEmpty { profileGrid(profiles: shownTerminals, columns: columns, cardWidth: cardWidth) }
                    ProfileGridPagination(model: model, page: $terminalPage, count: terminalProfiles.count, capacity: capacity, terminals: true)
                        .frame(maxWidth: .infinity)
                }
            }
            if model.displayedProfiles.isEmpty { emptyState }
            if model.preferences.showInsightsSection != false { InsightsDrawer(model: model, store: insights, presentation: presentation) }
            ProfileMessageNotice(model: model, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportsStripFrame("content")
        }
        .scrollIndicators(.automatic)
        .padding(.top, notchHeight + IslandLayout.topInset)
        .padding(.horizontal, WidgetSizing.stripPadding)
        .padding(.bottom, IslandLayout.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.displayedProfiles.count) { _, _ in
            profilePage = min(profilePage, pageCount - 1); terminalPage = min(terminalPage, terminalPageCount - 1)
        }
        .onChange(of: capacity) { _, _ in profilePage = 0; terminalPage = 0 }
        }
    }

    private var header: some View {
        let attention = StripAttention(model: model, activity: activity)
        return HStack(spacing: 8) {
            if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22, height: 20).help("Drag to move ProfileDock") }
            BrandMark(size: 14).foregroundStyle(.white.opacity(0.9))
            Text("ProfileDock").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).fixedSize()
            ViewThatFits(in: .horizontal) {
                AttentionChips(attention: attention)
                AttentionChips(attention: attention, compact: true)
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.leading, attention.isEmpty ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button { usage.refreshAll(force: true); model.companions.refresh() } label: {
                    StripIconLabel {
                        if usage.isRefreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                }
                .accessibilityLabel(usage.isRefreshing ? "Refreshing…" : "Refresh apps, terminals and usage")
                .help(usage.isRefreshing ? "Refreshing…" : "Find open coding terminals and refresh usage")
                ProfileGridMenu(model: model, columns: presentation.profileColumns, rows: presentation.profileRows)
                    .frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle())
                Button(action: settings) { StripIconLabel { Image(systemName: "slider.horizontal.3") } }
                    .accessibilityLabel("Settings").help("Profiles, apps, and settings")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
        .frame(height: IslandLayout.headerHeight)
        .reportsStripFrame("header")
    }

    private var terminalsHeader: some View {
        let expanded = model.preferences.terminalsExpanded != false
        let hint = model.preferences.discoverTerminals == false ? "Automatic discovery is off in Settings." : "Start a coding agent in Terminal to see it here."
        return HStack(spacing: 8) {
            Button { model.setTerminalsExpanded(!expanded) } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: "terminal")
                    Text("Terminals")
                    Text("\(model.liveTerminalProfiles.count)").monospacedDigit().foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.accessibilityLabel(expanded ? "Collapse terminals" : "Expand terminals").fixedSize()
            // Hints and errors share the header row, so the section height does not depend on them.
            if expanded, let error = model.companions.terminalError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(error)
            } else if expanded, model.liveTerminalProfiles.isEmpty {
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(hint)
            }
            Spacer(minLength: 8)
            Button { model.companions.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .accessibilityLabel("Find coding terminals").help("Find coding terminals")
        }
        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
        .frame(height: IslandLayout.sectionHeaderHeight)
        .reportsStripFrame("terminals")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.preferences.profiles.contains(where: { !$0.kind.usesTerminal }) {
                Button("All profiles are hidden · Show some", action: settings).buttonStyle(.bordered)
            } else {
                let found = AgentAutoAdd.offers(installed: model.installedAgents ?? [], profiles: model.preferences.profiles, dismissed: Set(model.preferences.dismissedAgentTools ?? [])).count
                if found > 0 {
                    Text(found == 1 ? "1 coding tool found on this Mac" : "\(found) coding tools found on this Mac")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
                Button(found > 0 ? "Add your tools" : "Add your first profile", action: settings).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity).frame(height: IslandLayout.emptyStateHeight)
    }

    private func profileGrid(profiles: [(offset: Int, element: Profile)], columns: Int, cardWidth: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: WidgetSizing.gridGap, alignment: .topLeading), count: columns), alignment: .leading, spacing: WidgetSizing.gridGap) {
            ForEach(profiles, id: \.element.id) { index, profile in
                ProfileCard(model: model, usage: usage, activity: activity, presentation: presentation, profile: profile, index: index, width: cardWidth)
                    .modifier(ReorderableProfile(model: model, profile: profile, displayedOnly: true, cornerRadius: CardMetrics.cornerRadius))
                    .contextMenu { contextMenu(profile, index: index) }
                    .reportsStripFrame("card:\(profile.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: profiles.map { $0.element.id })
    }

    @ViewBuilder private func contextMenu(_ profile: Profile, index: Int) -> some View {
        let entry = usage.entries[profile.id]
        Button("Move earlier") { model.moveDisplayed(profile.id, by: -1) }.disabled(index == 0)
        Button("Move later") { model.moveDisplayed(profile.id, by: 1) }.disabled(index == model.displayedProfiles.count - 1)
        Divider()
        if model.running[profile.id]?.isEmpty == false && profile.terminalHost == nil {
            Button("Close \(profile.name)") { model.requestQuit(profile) }.disabled(model.closing.contains(profile.id))
        }
        Button("Hide from strip") { model.setShownInStrip(profile.id, false) }
        if entry?.error?.offersReconnect == true {
            Button("Reconnect usage…") { usage.reconnect(profile, home: model.home) }.disabled(usage.isReconnecting(profile))
        }
        let reading = entry?.validatingIdentity == false ? entry?.snapshot : nil
        let snapshot = reading ?? (reading == nil && entry?.error != nil ? usage.statusLineReadings[profile.id] : nil)
        if profile.usesClaudeAccountUsage, snapshot?.bankedResets == nil, entry?.error != .claudeConnectionNeeded, entry?.error != .claudeOtherAccount {
            Button("Connect saved resets…") { ClaudeResetConnection.connection(configDirectory: usage.claudeConfigPath(profile)).connect() }
                .help("Sign in to Claude once to refresh saved resets automatically. No reset is consumed.")
        }
        if profile.usesSeparateClaudeAccount, ClaudeResetConnection.connection(configDirectory: usage.claudeConfigPath(profile)).enabled {
            Button("Disconnect saved resets") { ClaudeResetConnection.connection(configDirectory: usage.claudeConfigPath(profile)).disconnect() }
        }
    }

    static func absoluteDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))
    }
    static func age(_ date: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}

/// One profile in the strip: badge, name and status on top, one usage row per limit window, then saved resets.
/// Every part has a fixed height from `CardMetrics`, so all cards share a height and `IslandLayout` sizes the strip exactly.
struct ProfileCard: View {
    @ObservedObject var model: DockModel
    @ObservedObject var usage: UsageStore
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var presentation: IslandPresentation
    let profile: Profile
    let index: Int
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let scale = model.preferences.scale
        let active = model.activeProfile == profile.id
        let isOpen = model.running[profile.id]?.isEmpty == false
        let entry = usage.entries[profile.id]
        let taskState = activity.entries[profile.id]
        let reading = entry?.validatingIdentity == false ? entry?.snapshot : nil
        // A separate account's status-line report fills in only while its account endpoint has no reading.
        let statusLine = reading == nil && entry?.error != nil ? usage.statusLineReadings[profile.id] : nil
        let snapshot = reading ?? statusLine
        let closable = isOpen && profile.terminalHost == nil
        let showsResets = (profile.kind == .codex && snapshot != nil) || (profile.usesClaudeAccountUsage && snapshot?.bankedResets != nil)
        let detailsOpen = showsResets && presentation.resetDetails.contains(profile.id)
        VStack(alignment: .leading, spacing: 0) {
            header(scale: scale, active: active, isOpen: isOpen, taskState: taskState, closable: closable)
            usageBlock(entry: entry, snapshot: snapshot, statusLine: statusLine != nil)
                .padding(.top, CardMetrics.usageGap)
            footer(entry: entry, snapshot: snapshot, statusLine: statusLine != nil, showsResets: showsResets, detailsOpen: detailsOpen)
                .padding(.top, CardMetrics.footerGap)
            if detailsOpen {
                ResetExpiryList(snapshot: snapshot, now: usage.now)
                    .frame(height: IslandLayout.resetDetailsHeight - 8).padding(.top, 8)
            }
        }
        .padding(CardMetrics.padding)
        .frame(width: width, height: CardMetrics.height(usageRows: usage.cardUsageRows, scale: scale) + (detailsOpen ? IslandLayout.resetDetailsHeight : 0), alignment: .topLeading)
        .background(.white.opacity(active ? 0.10 : hovering ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous).strokeBorder(.white.opacity(active ? 0.18 : 0), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // ProfileDock closes only Terminal.app windows; other terminal apps keep control of their sessions.
            if closable {
                Button { model.requestQuit(profile) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 20, height: 20).background(.white.opacity(0.16), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(model.closing.contains(profile.id))
                .padding(8)
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering).accessibilityHidden(!hovering)
                .accessibilityLabel("Close \(profile.name)").help("Close \(profile.name)")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private func header(scale: Double, active: Bool, isOpen: Bool, taskState: ActivitySummary?, closable: Bool) -> some View {
        let status = statusText(taskState, active: active, isOpen: isOpen)
        return Button { model.select(profile) } label: {
            HStack(spacing: 10) {
                ProfileBadge(model: model, profile: profile, size: CardMetrics.badge(scale: scale), activity: taskState, activityVisible: presentation.expanded)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(profile.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1).truncationMode(.middle).help(profile.name)
                        Spacer(minLength: 4)
                        if index < 9 {
                            Text("⌥⌘\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                                .fixedSize().opacity(closable && hovering ? 0 : 1).accessibilityHidden(true)
                        }
                    }.frame(height: 16)
                    Text(status.text).font(.system(size: 11, weight: status.emphasized ? .medium : .regular)).foregroundStyle(status.color)
                        .lineLimit(1).truncationMode(.tail).frame(height: 14).help(status.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CardMetrics.headerHeight(scale: scale))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(profile.name) · \(model.state(profile)) · ⌥⌘\(index + 1)\n" + (model.tileWarning(profile).map { $0.fix + "\n" } ?? "") + activityHelp(taskState))
        .accessibilityLabel("\(profile.name), \(model.state(profile)). \(status.text). " + activityHelp(taskState))
        .accessibilityAction(named: "Close \(profile.name)") { if closable { model.requestQuit(profile) } }
    }

    /// Activity first (it needs the user), then opening, warnings, connection problems, and the app with its sign-in mode.
    private func statusText(_ state: ActivitySummary?, active: Bool, isOpen: Bool) -> (text: String, color: Color, emphasized: Bool) {
        let quiet = Color.white.opacity(0.6)
        if let state {
            if state.waiting > 0 { return (state.waiting > 1 ? "Needs you · \(state.waiting) tasks" : "Needs you", ProfileActivityState.waiting.color, true) }
            if state.working > 0 { return ("Working · \(state.working) \(state.working == 1 ? "task" : "tasks")", ProfileActivityState.working.color, true) }
            if let unread = state.unread, unread > 0 { return (unread > 1 ? "Done · \(unread) unread" : "Done · unread", ProfileActivityState.unread.color, true) }
        }
        if model.opening.contains(profile.id) { return ("Opening…", quiet, false) }
        if let warning = model.tileWarning(profile) { return (warning.text, .orange, true) }
        if let state, state.appOpen, !state.liveAvailable { return (state.connectionIssue?.label ?? "Activity unavailable", quiet, false) }
        if profile.terminalHost != nil, let host = model.companions.window(for: profile)?.title { return ("In \(host)", quiet, false) }
        let app: String, mode: String?
        switch profile.kind {
        case .agent: app = profile.agentTool?.name ?? profile.tileCaption; mode = profile.usesIsolatedAgentHome ? "separate account" : "shared sign-in"
        case .codex: app = "ChatGPT"; mode = nil
        case .claude: app = "Claude"; mode = profile.usesSeparateClaudeAccount ? "separate account" : "shared sign-in"
        case .claudeCode: app = "Claude Code"; mode = nil
        case .terminal: app = model.terminalAgent(for: profile).map { "\($0.label) in Terminal" } ?? (profile.tileCaption == profile.name ? "Terminal window" : profile.tileCaption); mode = nil
        }
        if active { return ("Active · \(app)", .white.opacity(0.75), false) }
        if isOpen { return ("Open · \(app)", quiet, false) }
        return (mode.map { "\(app) · \($0)" } ?? app, quiet, false)
    }

    private func usageBlock(entry: UsageEntry?, snapshot: UsageSnapshot?, statusLine: Bool) -> some View {
        Group {
            if let snapshot, !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: CardMetrics.rowGap) {
                    ForEach(snapshot.windows) { window in UsageWindowView(window: window, now: usage.now).frame(height: CardMetrics.rowHeight) }
                }
            } else if let error = entry?.error {
                errorLine(error).frame(height: CardMetrics.rowHeight)
            } else {
                Text((profile.kind == .codex || profile.usesClaudeAccountUsage) ? (snapshot == nil ? "Loading usage…" : "No usage data")
                     : profile.kind == .agent ? "\(profile.agentTool?.name ?? "This tool") does not share usage limits" : "Usage not reported yet")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).frame(height: CardMetrics.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CardMetrics.usageHeight(rows: usage.cardUsageRows), alignment: .top)
        .help(usageSource(statusLine: statusLine) + (snapshot.map { "Updated at \(IslandView.absoluteDate($0.fetchedAt))." } ?? "Usage for this account."))
    }

    /// Errors and their actions on one line: the reason on the left, the actions on the right.
    private func errorLine(_ error: UsageLoadError) -> some View {
        HStack(spacing: 10) {
            Text(error.statusLabel).font(.system(size: 10)).foregroundStyle(error.needsSignIn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.white.opacity(0.5)))
                .lineLimit(1).truncationMode(.tail).help(error.message)
            Spacer(minLength: 4)
            Group {
                if error.needsSignIn {
                    Button(usage.isReconnecting(profile) ? "Finish in browser…" : "Reconnect") { usage.reconnect(profile, home: model.home) }
                        .foregroundStyle(.orange)
                        .disabled(usage.isReconnecting(profile)).accessibilityLabel("Reconnect \(profile.name)")
                        .help(usage.reconnectionMessages[usage.connectionKey(profile)] ?? "Open sign-in for this account. Usage refreshes automatically when you finish.")
                } else if error == .claudeConnectionNeeded || error == .claudeOtherAccount {
                    Button(usage.isReconnecting(profile) ? "Finish in browser…" : error == .claudeOtherAccount ? "Reconnect" : "Connect…") { usage.reconnect(profile, home: model.home) }
                        .foregroundStyle(.white.opacity(0.8))
                        .disabled(usage.isReconnecting(profile)).accessibilityLabel("Connect usage for \(profile.name)")
                        .help(usage.reconnectionMessages[usage.connectionKey(profile)] ?? error.message)
                } else if error.offersReconnect {
                    // A stale token is not a sign-in failure: refresh first, Reconnect only as the secondary action.
                    Button("Refresh") { usage.refresh(profile, force: true) }
                        .foregroundStyle(.white.opacity(0.8)).help(error.message)
                    Button(usage.isReconnecting(profile) ? "Finish in browser…" : "Reconnect") { usage.reconnect(profile, home: model.home) }
                        .foregroundStyle(.white.opacity(0.5))
                        .disabled(usage.isReconnecting(profile)).accessibilityLabel("Reconnect \(profile.name)")
                        .help(usage.reconnectionMessages[usage.connectionKey(profile)] ?? "Sign in again now instead of waiting for Claude Code.")
                } else {
                    Button("Try again") { usage.refresh(profile, force: true) }
                        .foregroundStyle(.white.opacity(0.8)).help(error.message)
                }
            }
            .buttonStyle(StripTextButtonStyle())
        }
    }

    @ViewBuilder private func footer(entry: UsageEntry?, snapshot: UsageSnapshot?, statusLine: Bool, showsResets: Bool, detailsOpen: Bool) -> some View {
        // Grok Bot rewrites its own reading only now and then, so an hour-old reading is normal there.
        let stale = snapshot.flatMap { snapshot -> Date? in
            (entry?.error != nil && !statusLine) || usage.now.timeIntervalSince(snapshot.fetchedAt) > (profile.kind == .agent ? 3600 : profile.usesClaudeAccountUsage && !statusLine ? 360 : 90) ? snapshot.fetchedAt : nil
        }
        HStack(spacing: 8) {
            if profile.usesClaudeAccountUsage && statusLine && (entry?.error == .claudeConnectionNeeded || entry?.error == .claudeOtherAccount) {
                Button("Connect usage…") { usage.reconnect(profile, home: model.home) }
                    .buttonStyle(StripTextButtonStyle()).foregroundStyle(.white.opacity(0.75))
                    .disabled(usage.isReconnecting(profile)).help(entry?.error?.message ?? "")
            } else if showsResets {
                ResetInventoryView(snapshot: snapshot, now: usage.now, expanded: detailsOpen) { presentation.toggleResetDetails(profile.id) }
                    .help(resetHelp(snapshot))
            }
            Spacer(minLength: 0)
            if let stale {
                Text("Updated \(IslandView.age(stale, now: usage.now)) ago")
                    .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9)).lineLimit(1).fixedSize()
                    .help(profile.kind == .agent ? "Last reading saved by \(profile.agentTool?.name ?? profile.name). It updates while the app is open." : statusLine ? "Last status-line report from this account's Claude Code." : entry?.error?.message ?? "Refreshing usage data.")
            }
        }
        .frame(height: CardMetrics.footerHeight)
    }

    private func activityHelp(_ state: ActivitySummary?) -> String {
        if profile.kind == .agent, profile.agentTool != nil { return profile.accountCaption }
        if profile.kind != .codex {
            if model.terminalAgent(for: profile) == .codex { return "Codex is running in this Terminal tab. Per-tab Codex CLI task activity and usage are not reported by this integration." }
            if let tool = model.terminalAgent(for: profile)?.tool, !tool.legacy { return tool.runningHelp }
            if profile.kind == .terminal, state?.working == 0, state?.waiting == 0 { return "This Terminal tab. Claude Code activity appears when connected." }
            return "Tracks connected local Claude Code sessions. Claude Chat and Cowork activity are not available. " + (state?.liveAvailable == true ? "" : "Connect Claude Code in Profiles to enable activity.")
        }
        guard let state else { return "Loading task status…" }
        let unread = state.unread.map { "\($0) completed tasks with unread results." } ?? "Unread results unknown."
        let live = state.liveAvailable ? "\(state.working) working, \(state.waiting) waiting for you." : (state.appOpen ? state.connectionIssue?.explanation ?? "Live task status unavailable." : "Desktop profile closed.")
        return "\(unread) \(live)\nTracks local Work/Codex tasks. Ordinary ChatGPT chats are not counted."
    }

    private func usageSource(statusLine: Bool) -> String {
        if profile.kind == .agent { return GrokBotUsage.dataDirectory(for: profile, home: model.home) != nil ? "Weekly usage as last read by Grok Bot. " : "" }
        guard profile.usesClaudeAccountUsage else { return "" }
        if statusLine { return "Reported by this account's Claude Code status line until account usage is connected. " }
        return profile.usesSeparateClaudeAccount ? "Claude Code account usage for this separate account. " : "Claude Code account usage, shared by Claude tiles. "
    }

    private func resetHelp(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot, let count = snapshot.bankedResets else { return "The number of saved resets is unavailable." }
        var lines = ["\(count) saved \(count == 1 ? "reset" : "resets")."]
        if let applicable = snapshot.applicableResets { lines.append("Available now: \(applicable).") }
        if let dates = snapshot.resetExpiries, !dates.isEmpty {
            lines += dates.map { "Expires: \(IslandView.absoluteDate($0))." }
        }
        lines.append("Updated at \(IslandView.absoluteDate(snapshot.fetchedAt)).")
        return lines.joined(separator: "\n")
    }
}

/// Plain 10 pt text action with a 20 pt tall hit target that does not change the row height.
struct StripTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.vertical, 5).contentShape(Rectangle()).padding(.vertical, -5)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Compact saved-resets line ("2 saved resets · next expires 3d"); a click shows the expiry times below the card.
struct ResetInventoryView: View {
    let snapshot: UsageSnapshot?
    let now: Date
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .medium))
                if let count = snapshot?.bankedResets {
                    let saved = "\(count) saved \(count == 1 ? "reset" : "resets")"
                    if let next = nextExpiry {
                        ViewThatFits(in: .horizontal) {
                            Text("\(saved) · next expires \(next)").fixedSize()
                            Text("\(saved) · \(next)").fixedSize()
                            Text(saved).fixedSize()
                        }
                    } else { Text(saved).fixedSize() }
                } else { Text("Saved resets unknown").fixedSize() }
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .monospacedDigit()
            .frame(height: CardMetrics.footerHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10)).foregroundStyle(.white.opacity(snapshot?.bankedResets == nil ? 0.5 : 0.7))
        .accessibilityLabel(snapshot?.bankedResets.map { "\($0) saved resets, expiry times" } ?? "Saved resets, expiry unknown")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Click to \(expanded ? "hide expiry times" : "show expiry times").")
    }

    /// The soonest expiry as a short countdown: "3d", "5h", "12m".
    private var nextExpiry: String? {
        guard let first = ResetExpiryDetails(count: snapshot?.bankedResets, expiries: snapshot?.resetExpiries).dates.first(where: { $0 > now }) else { return nil }
        let seconds = first.timeIntervalSince(now), hours = Int(seconds / 3600)
        if hours >= 24 { return "\(hours / 24)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(max(1, Int(seconds / 60)))m"
    }
}

/// Expiry time per saved reset, one row each, inside the card while the resets line is open.
struct ResetExpiryList: View {
    let snapshot: UsageSnapshot?
    let now: Date
    var body: some View {
        let details = ResetExpiryDetails(count: snapshot?.bankedResets, expiries: snapshot?.resetExpiries)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: CardMetrics.rowGap) {
                ForEach(Array(details.dates.enumerated()), id: \.offset) { index, expiry in
                    let countdown = ResetExpiryDetails.countdown(until: expiry, now: now)
                    HStack(spacing: 8) {
                        Text("Reset \(index + 1)").foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 4)
                        ViewThatFits(in: .horizontal) {
                            Text(countdown).fixedSize()
                            Text(countdown.replacingOccurrences(of: "Expires in", with: "In").replacingOccurrences(of: "Expires within", with: "Within")).fixedSize()
                        }
                        .fontWeight(.medium).monospacedDigit()
                        .foregroundStyle(expiry.timeIntervalSince(now) <= 86400 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.white.opacity(0.85)))
                    }
                    .frame(height: CardMetrics.rowHeight)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Reset \(index + 1), \(countdown)")
                    .help("Expires at \(IslandView.absoluteDate(expiry)).")
                }
                if let message = details.message {
                    Text(message).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

/// One usage window as a table row: label, bar, percent left and reset countdown. The fixed columns line up
/// across every card because all cards in a strip share one width.
struct UsageWindowView: View {
    let window: UsageWindow
    let now: Date
    static let labelWidth: CGFloat = 38
    static let percentWidth: CGFloat = 36
    static let resetWidth: CGFloat = 52
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's reset time passed since this reading: it is full again, shown dimmed until the next reading.
    private var reset: Bool { window.isPastReset(now: now) }
    private var remaining: Double { reset ? 100 : window.remainingPercent }
    private var tint: Color { UsageTint.remaining(remaining).color }

    var body: some View {
        HStack(spacing: 8) {
            Text(shortTitle).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: proxy.size.width * remaining / 100)
                }
            }
            .frame(height: 4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: remaining)
            Text(verbatim: "\(Int(remaining.rounded()))%").monospacedDigit().foregroundStyle(tint)
                .frame(width: Self.percentWidth, alignment: .trailing)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: remaining)
            Text(shortReset).monospacedDigit().foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                .frame(width: Self.resetWidth, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .opacity(reset ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(Int(remaining.rounded())) percent remaining. \(resetText)")
        .help(window.resetsAt.map { "\(window.title): \(Int(window.usedPercent.rounded()))% used.\nResets at \(IslandView.absoluteDate($0))." } ?? "\(window.title): reset time unknown.")
    }

    var shortTitle: String {
        let duration = window.duration
        if duration == 604800 { return "Week" }
        if duration >= 86400, duration.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(duration / 86400))d" }
        if duration >= 3600, duration.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(duration / 3600))h" }
        return "\(Int(duration / 60))m"
    }

    var shortReset: String {
        guard let reset = window.resetsAt else { return "—" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "reset" }
        let hours = Int(seconds / 3600), days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(Int(seconds / 60) % 60)m" }
        return "\(max(1, Int(seconds / 60)))m"
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "Reset time unknown" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset refreshing" }
        let hours = Int(seconds / 3600), days = hours / 24
        if days > 0 { return "Reset in \(days)d \(hours % 24)h" }
        if hours > 0 { return "Reset in \(hours)h \(Int(seconds / 60) % 60)m" }
        return "Reset in \(max(1, Int(seconds / 60))) min"
    }
}
