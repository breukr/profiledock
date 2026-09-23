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
                    StatusDot(isOpen: true, size: 10).padding(3).background(.black, in: Circle()).offset(x: 4, y: 4)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let agent = model.terminalAgent(for: profile) {
                Image(nsImage: model.terminalAgentArtwork(agent)).resizable()
                    .frame(width: max(16, size * 0.36), height: max(16, size * 0.36))
                    .clipShape(Circle()).overlay(Circle().stroke(.black, lineWidth: 2))
                    .offset(x: 4, y: -4)
                    .accessibilityLabel("\(agent.label) terminal")
                    .help("\(agent.label) is running in this Terminal tab")
            }
        }
        .overlay(alignment: .topLeading) {
            if let activity, let badge = activity.badge {
                Text(badge).font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 5).frame(minWidth: 19, minHeight: 19)
                    .background(Color(red: 0.93, green: 0.24, blue: 0.24), in: Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 2)).offset(x: -7, y: -5)
                    .accessibilityLabel("\(activity.unread ?? 0) completed tasks with unread results")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let activity, activity.waiting > 0 {
                Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 20, height: 20).background(.orange, in: Circle())
                    .overlay(Circle().stroke(.black, lineWidth: 2)).offset(x: -6, y: 4)
                    .accessibilityLabel("\(activity.waiting) tasks waiting for you")
            }
        }
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
        HStack(spacing: 7) {
            if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22).help("Drag to move ProfileDock") }
            BrandMark(size: 11).foregroundStyle(.white.opacity(0.85))
            Text("Apps").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9))
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
        .accessibilityLabel("ProfileDock, hover here to open. " + statusDescription)
        .help(statusDescription)
        }
    }
    private var statusDescription: String {
        model.displayedProfiles.map { "\($0.name): \(ProfileActivityState(summary: activity.entries[$0.id], isOpen: model.running[$0.id]?.isEmpty == false).label)" }.joined(separator: ". ")
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
        let columns = presentation.profileColumns
        let capacity = max(1, columns * presentation.profileRows)
        let desktopProfiles = Array(model.displayedProfiles.enumerated()).filter { !$0.element.kind.usesTerminal }
        let terminalProfiles = Array(model.displayedProfiles.enumerated()).filter { $0.element.kind.usesTerminal }
        let terminalPageCount = max(1, (terminalProfiles.count + capacity - 1) / capacity)
        let terminalsPage = min(terminalPage, terminalPageCount - 1)
        let pageCount = max(1, (desktopProfiles.count + capacity - 1) / capacity)
        let page = min(profilePage, pageCount - 1)
        let tileWidth = WidgetSizing.tile(count: columns, available: geometry.size.width - 32, scale: model.preferences.scale)
        ScrollView(.vertical) {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22, height: 20).help("Drag to move ProfileDock") }
                Text("ProfileDock").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(usage.isRefreshing ? "Refreshing…" : "Remaining").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Button { usage.refreshAll(force: true); model.companions.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }.accessibilityLabel("Refresh apps, terminals and usage").help("Find open coding terminals and refresh usage")
                ProfileGridMenu(model: model, columns: columns, rows: presentation.profileRows)
                Button(action: settings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 20)
                }.accessibilityLabel("Settings").help("Profiles, apps, and settings")
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
            profileGrid(profiles: Array(desktopProfiles.dropFirst(page * capacity).prefix(capacity)), columns: columns, tileWidth: tileWidth)
            ProfileGridPagination(model: model, page: $profilePage, count: desktopProfiles.count, capacity: capacity, terminals: false)
            if model.preferences.showTerminalsSection != false {
            VStack(spacing: 10) {
                HStack {
                    Button { model.setTerminalsExpanded(model.preferences.terminalsExpanded == false) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.preferences.terminalsExpanded == false ? "chevron.right" : "chevron.down")
                            Image(systemName: "terminal")
                            Text("Terminals")
                            Text("\(model.liveTerminalProfiles.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }.accessibilityLabel(model.preferences.terminalsExpanded == false ? "Expand terminals" : "Collapse terminals")
                    Spacer()
                    Button { model.companions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Find coding terminals")
                }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                if model.preferences.terminalsExpanded != false {
                    profileGrid(profiles: Array(terminalProfiles.dropFirst(terminalsPage * capacity).prefix(capacity)), columns: columns, tileWidth: tileWidth)
                    ProfileGridPagination(model: model, page: $terminalPage, count: terminalProfiles.count, capacity: capacity, terminals: true)
                    if let error = model.companions.terminalError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.liveTerminalProfiles.isEmpty {
                        Text(model.preferences.discoverTerminals == false ? "Automatic discovery is off in Settings." : "Open Claude Code or Codex in Terminal to see it here.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            }
            if model.displayedProfiles.isEmpty { Button("Add your first profile", action: settings).buttonStyle(.borderedProminent) }
            if model.preferences.showInsightsSection != false { InsightsDrawer(model: model, store: insights, presentation: presentation) }
            ProfileMessageNotice(model: model, compact: true)
        }
        }
        .scrollIndicators(.automatic)
        .padding(.top, notchHeight + 13)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.displayedProfiles.count) { _, _ in
            profilePage = min(profilePage, pageCount - 1); terminalPage = min(terminalPage, terminalPageCount - 1)
        }
        .onChange(of: capacity) { _, _ in profilePage = 0; terminalPage = 0 }
        }
    }

    private func profileGrid(profiles: [(offset: Int, element: Profile)], columns: Int, tileWidth: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 10 * model.preferences.scale, alignment: .top), count: columns), alignment: .center, spacing: 10) {
            ForEach(profiles, id: \.element.id) { index, profile in
                accountCard(profile, index: index, tileWidth: tileWidth).frame(width: tileWidth)
                    .modifier(ReorderableProfile(model: model, profile: profile, displayedOnly: true))
                    .contextMenu {
                        Button("Move earlier") { model.moveDisplayed(profile.id, by: -1) }.disabled(index == 0)
                        Button("Move later") { model.moveDisplayed(profile.id, by: 1) }.disabled(index == model.displayedProfiles.count - 1)
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: profiles.map { $0.element.id })
    }

    private func accountCard(_ profile: Profile, index: Int, tileWidth: CGFloat) -> some View {
        let active = model.activeProfile == profile.id
        let isOpen = model.running[profile.id]?.isEmpty == false
        let entry = usage.entries[profile.id]
        let taskState = activity.entries[profile.id]
        let snapshot = entry?.validatingIdentity == false ? entry?.snapshot : nil
        return VStack(spacing: 10) {
            Button { model.select(profile) } label: {
                VStack(spacing: 7) {
                    ProfileBadge(model: model, profile: profile, size: min(52 * model.preferences.scale, tileWidth * 0.42), activity: taskState, activityVisible: presentation.expanded)
                    Text(profile.name).font(.system(size: 11, weight: active ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(active ? 1 : 0.8)).lineLimit(1)
                    Text(activityText(taskState) ?? (active ? "Active" : (isOpen ? "Open" : (index < 9 ? "⌥⌘\(index + 1)" : "Open"))))
                        .font(.system(size: 10, weight: (taskState?.working ?? 0) > 0 ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle((taskState?.working ?? 0) > 0 ? Color(red: 0.4, green: 0.72, blue: 1) : .white.opacity(active ? 1 : 0.65))
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(profile.name) · \(model.state(profile)) · ⌥⌘\(index + 1)\n" + activityHelp(taskState, profile: profile))
            .accessibilityLabel("\(profile.name), \(model.state(profile)). " + activityHelp(taskState, profile: profile))
            .overlay(alignment: .topTrailing) {
                if isOpen {
                    Button { model.requestQuit(profile) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20).background(Color(white: 0.22), in: Circle())
                            .overlay(Circle().stroke(.black, lineWidth: 2))
                    }.buttonStyle(.plain).disabled(model.closing.contains(profile.id))
                        .accessibilityLabel("Close \(profile.name)").help("Close \(profile.name)")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot, !snapshot.windows.isEmpty {
                    ForEach(snapshot.windows) { window in UsageWindowView(window: window, now: usage.now) }
                } else if let error = entry?.error {
                    Text("Unavailable").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    Button("Try again") { usage.refresh(profile, force: true) }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.75)).help(error.message)
                } else {
                    Text((profile.kind == .codex || profile.usesClaudeAccountUsage) ? (snapshot == nil ? "Loading usage…" : "No usage data") : (profile.kind == .terminal ? "Terminal window" : "Usage not reported yet"))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, minHeight: IslandLayout.usageHeight(rows: snapshot?.windows.count ?? 1), maxHeight: IslandLayout.usageHeight(rows: snapshot?.windows.count ?? 1), alignment: .topLeading)
            .help((profile.usesClaudeAccountUsage ? "Claude Code account usage, shared by Claude tiles. " : "") + (snapshot.map { "Updated at \(Self.absoluteDate($0.fetchedAt))." } ?? "Usage for this account."))
            if profile.usesClaudeAccountUsage && snapshot?.bankedResets == nil {
                Button("Connect saved resets…") { ClaudeResetConnection.shared.connect() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).frame(height: 20)
                    .help("Sign in to Claude once to refresh saved resets automatically. No reset is consumed.")
            } else if profile.kind == .codex || profile.usesClaudeAccountUsage {
            ResetInventoryView(snapshot: snapshot, now: usage.now, expanded: presentation.resetDetails.contains(profile.id)) {
                presentation.toggleResetDetails(profile.id)
            }
            .help(resetHelp(snapshot))
            } else { Text(profile.kind == .claudeCode ? "Claude Code" : profile.kind.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).frame(height: 20) }
            if let snapshot, entry?.error != nil || usage.now.timeIntervalSince(snapshot.fetchedAt) > (profile.usesClaudeAccountUsage ? 360 : 90) {
                Text("Updated \(Self.age(snapshot.fetchedAt, now: usage.now)) ago")
                    .font(.system(size: 8)).foregroundStyle(.orange.opacity(0.9))
                    .help(entry?.error?.message ?? "Refreshing usage data.")
            } else { Text(" ").font(.system(size: 8)).accessibilityHidden(true) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(active ? .white.opacity(0.075) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(active ? .white.opacity(0.2) : .clear, lineWidth: 1))
    }

    private func activityText(_ state: ActivitySummary?) -> String? {
        guard let state else { return nil }
        if state.working > 0 { return "\(state.working) working" + (state.waiting > 0 ? " · \(state.waiting) waiting" : "") }
        if state.waiting > 0 { return "\(state.waiting) needs you" }
        if let unread = state.unread, unread > 0 { return "\(unread) unread" }
        if state.appOpen && !state.liveAvailable { return state.connectionIssue?.label ?? "Activity unavailable" }
        if state.unread == nil { return "Results unknown" }
        return nil
    }

    private func activityHelp(_ state: ActivitySummary?, profile: Profile) -> String {
        if profile.kind != .codex {
            if model.terminalAgent(for: profile) == .codex { return "Codex is running in this Terminal tab. Per-tab Codex CLI task activity and usage are not reported by this integration." }
            if profile.kind == .terminal, state?.working == 0, state?.waiting == 0 { return "This Terminal tab. Claude Code activity appears when connected." }
            return "Tracks connected local Claude Code sessions. Claude Chat and Cowork activity are not available. " + (state?.liveAvailable == true ? "" : "Connect Claude Code in Profiles to enable activity.")
        }
        guard let state else { return "Loading task status…" }
        let unread = state.unread.map { "\($0) completed tasks with unread results." } ?? "Unread results unknown."
        let live = state.liveAvailable ? "\(state.working) working, \(state.waiting) waiting for you." : (state.appOpen ? state.connectionIssue?.explanation ?? "Live task status unavailable." : "Desktop profile closed.")
        return "\(unread) \(live)\nTracks local Work/Codex tasks. Ordinary ChatGPT chats are not counted."
    }

    private func resetHelp(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot, let count = snapshot.bankedResets else { return "The number of saved resets is unavailable." }
        var lines = ["\(count) saved \(count == 1 ? "reset" : "resets")."]
        if let applicable = snapshot.applicableResets { lines.append("Available now: \(applicable).") }
        if let dates = snapshot.resetExpiries, !dates.isEmpty {
            lines += dates.map { "Expires: \(Self.absoluteDate($0))." }
        }
        lines.append("Updated at \(Self.absoluteDate(snapshot.fetchedAt)).")
        return lines.joined(separator: "\n")
    }

    static func absoluteDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US")))
    }
    static func age(_ date: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}

struct ResetInventoryView: View {
    let snapshot: UsageSnapshot?
    let now: Date
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                    if let count = snapshot?.bankedResets {
                        ViewThatFits(in: .horizontal) {
                            Text("\(count) \(count == 1 ? "reset" : "resets") saved").fixedSize()
                            Text("Resets: \(count)").fixedSize()
                        }
                    } else { Text("Resets unknown") }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .frame(minHeight: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 10)).foregroundStyle(.white.opacity(snapshot?.bankedResets == nil ? 0.55 : 0.85))
            .accessibilityLabel(snapshot?.bankedResets.map { "\($0) saved resets, expiry times" } ?? "Saved resets, expiry unknown")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Click to \(expanded ? "hide expiry times" : "show expiry times").")
            if expanded {
                let details = ResetExpiryDetails(count: snapshot?.bankedResets, expiries: snapshot?.resetExpiries)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(details.dates.enumerated()), id: \.offset) { index, expiry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reset \(index + 1)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                                let countdown = ResetExpiryDetails.countdown(until: expiry, now: now)
                                ViewThatFits(in: .horizontal) {
                                    Text(countdown).fixedSize()
                                    Text(countdown.replacingOccurrences(of: "Expires in", with: "In")
                                        .replacingOccurrences(of: "Expires within", with: "Within"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(expiry.timeIntervalSince(now) <= 86400 ? .orange : .white.opacity(0.9))
                                .accessibilityLabel(countdown)
                            }
                            .accessibilityElement(children: .combine)
                            .help("Expires at \(IslandView.absoluteDate(expiry)).")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let message = details.message {
                            Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: IslandLayout.resetDetailsHeight - 8)
                .scrollIndicators(.never)
            }
        }
    }
}

struct UsageWindowView: View {
    let window: UsageWindow
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { UsageTint.remaining(window.remainingPercent).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 3)
                Text("\(Int(window.remainingPercent.rounded()))%").monospacedDigit().foregroundStyle(tint)
            }.font(.system(size: 11, weight: .medium))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: window.remainingPercent)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }.frame(height: 4)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: window.remainingPercent)
            ViewThatFits(in: .horizontal) {
                Text(resetText).fixedSize()
                Text(resetText.replacingOccurrences(of: "Reset in", with: "Reset in")
                    .replacingOccurrences(of: "Reset time unknown", with: "Reset unknown")
                    .replacingOccurrences(of: "Reset refreshing", with: "Reset refreshing")).fixedSize()
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(Int(window.remainingPercent.rounded())) percent remaining. \(resetText)")
        .help(window.resetsAt.map { "\(Int(window.usedPercent.rounded()))% used.\nResets at \(IslandView.absoluteDate($0))." } ?? "Reset time unknown.")
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
