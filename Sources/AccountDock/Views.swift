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
            Group {
                if let image = model.image(for: profile) {
                    RoundedRectangle(cornerRadius: size * 0.26).fill(.white)
                        .overlay { Image(nsImage: image).resizable().scaledToFit().padding(profile.iconIsTile == true ? 0 : size * 0.09) }
                } else {
                    RoundedRectangle(cornerRadius: size * 0.26).fill(Color(nsColor: NSColor(hex: profile.color)).gradient)
                        .overlay { Text(profile.initials).font(.system(size: size * 0.41, weight: .semibold, design: .rounded)).foregroundStyle(.white).shadow(color: .black.opacity(0.25), radius: 2, y: 1) }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).stroke(.white.opacity(0.15), lineWidth: 1))
            .background {
                IconPulse(working: (activity?.working ?? 0) > 0, visible: activityVisible, reduceMotion: reduceMotion, cornerRadius: size * 0.26)
                    .frame(width: size + 20, height: size + 20)
            }
            if showStatus {
                if model.opening.contains(profile.id) {
                    ProgressView().controlSize(.mini).padding(4).background(.black, in: Circle()).offset(x: 4, y: 4)
                } else if model.running[profile.id]?.isEmpty == false {
                    StatusDot(isOpen: true, size: 10).padding(3).background(.black, in: Circle()).offset(x: 4, y: 4)
                }
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
        HStack(spacing: 7) {
            if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22).help("Drag to move ProfileDock") }
            BrandMark(size: 11).foregroundStyle(.white.opacity(0.85))
            Text("Accounts").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 5) {
                ForEach(Array(model.preferences.profiles.prefix(5))) { profile in
                    ActivityDot(state: ProfileActivityState(summary: activity.entries[profile.id], isOpen: model.running[profile.id]?.isEmpty == false), visible: !presentation.expanded)
                }
                if model.preferences.profiles.count > 5 { Text("+\(model.preferences.profiles.count - 5)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)) }
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
    private var statusDescription: String {
        model.preferences.profiles.map { "\($0.name): \(ProfileActivityState(summary: activity.entries[$0.id], isOpen: model.running[$0.id]?.isEmpty == false).label)" }.joined(separator: ". ")
    }
}

struct IslandView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var usage: UsageStore
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var presentation: IslandPresentation
    let notchHeight: CGFloat
    let settings: () -> Void
    let drag: (DockDragPhase, CGPoint) -> Void

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                if model.placement == .free { DockDragHandle(drag: drag).frame(width: 22, height: 20).help("Drag to move ProfileDock") }
                Text("ProfileDock").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(usage.isRefreshing ? "Refreshing…" : "Remaining").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Button { usage.refreshAll(force: true) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }.disabled(usage.isRefreshing).accessibilityLabel("Refresh usage for all accounts").help("Refresh usage and saved resets")
                Button(action: settings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 20)
                }.accessibilityLabel("Settings").help("Profiles, apps, and settings")
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
            ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10 * model.preferences.scale) {
                ForEach(Array(model.preferences.profiles.enumerated()), id: \.element.id) { index, profile in
                    accountCard(profile, index: index).frame(width: 132 * model.preferences.scale)
                }
            }
            }.scrollIndicators(.hidden)
            if model.preferences.profiles.isEmpty { Button("Add your first profile", action: settings).buttonStyle(.borderedProminent) }
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    Button { model.message = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.foregroundStyle(.orange)
            }
        }
        .padding(.top, notchHeight + 13)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func accountCard(_ profile: Profile, index: Int) -> some View {
        let active = model.activeProfile == profile.id
        let isOpen = model.running[profile.id]?.isEmpty == false
        let entry = usage.entries[profile.id]
        let taskState = activity.entries[profile.id]
        let snapshot = entry?.validatingIdentity == false ? entry?.snapshot : nil
        return VStack(spacing: 10) {
            Button { model.select(profile) } label: {
                VStack(spacing: 7) {
                    ProfileBadge(model: model, profile: profile, size: 52 * model.preferences.scale, activity: taskState, activityVisible: presentation.expanded)
                    Text(profile.name).font(.system(size: 11, weight: active ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(active ? 1 : 0.8)).lineLimit(1)
                    Text(activityText(taskState) ?? (active ? "Active" : (isOpen ? "Open" : (index < 9 ? "⌥⌘\(index + 1)" : "Open"))))
                        .font(.system(size: 10, weight: (taskState?.working ?? 0) > 0 ? .semibold : .regular))
                        .foregroundStyle((taskState?.working ?? 0) > 0 ? Color(red: 0.4, green: 0.72, blue: 1) : .white.opacity(active ? 1 : 0.65))
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(profile.name) · \(model.state(profile)) · ⌥⌘\(index + 1)\n" + activityHelp(taskState))
            .accessibilityLabel("\(profile.name), \(model.state(profile)). " + activityHelp(taskState))
            .overlay(alignment: .topTrailing) {
                if isOpen {
                    Button { model.requestQuit(profile) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20).background(Color(white: 0.22), in: Circle())
                            .overlay(Circle().stroke(.black, lineWidth: 2))
                    }.buttonStyle(.plain).disabled(model.closing.contains(profile.id))
                        .accessibilityLabel("Close \(profile.name)").help("Close the ChatGPT profile \(profile.name)")
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
                    Text(snapshot == nil ? "Loading usage…" : "No usage data")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, minHeight: IslandLayout.usageHeight(rows: snapshot?.windows.count ?? 1), maxHeight: IslandLayout.usageHeight(rows: snapshot?.windows.count ?? 1), alignment: .topLeading)
            .help(snapshot.map { "Updated at \(Self.absoluteDate($0.fetchedAt))." } ?? "Usage for this account.")
            ResetInventoryView(snapshot: snapshot, now: usage.now, expanded: presentation.resetDetails.contains(profile.id)) {
                presentation.toggleResetDetails(profile.id)
            }
            .help(resetHelp(snapshot))
            if let snapshot, entry?.error != nil || usage.now.timeIntervalSince(snapshot.fetchedAt) > 90 {
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
        if state.appOpen && !state.liveAvailable { return "Task status unknown" }
        if state.unread == nil { return "Results unknown" }
        return nil
    }

    private func activityHelp(_ state: ActivitySummary?) -> String {
        guard let state else { return "Loading task status…" }
        let unread = state.unread.map { "\($0) completed tasks with unread results." } ?? "Unread results unknown."
        let live = state.liveAvailable ? "\(state.working) working, \(state.waiting) waiting for you." : (state.appOpen ? "Live task status unavailable." : "Desktop profile closed.")
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
            }
        }
    }
}

private struct UsageWindowView: View {
    let window: UsageWindow
    let now: Date
    private var tint: Color {
        if window.remainingPercent <= 10 { return Color(red: 0.96, green: 0.36, blue: 0.32) }
        if window.remainingPercent <= 25 { return Color(red: 0.98, green: 0.71, blue: 0.29) }
        return Color(red: 0.29, green: 0.85, blue: 0.52)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 3)
                Text("\(Int(window.remainingPercent.rounded()))%").monospacedDigit().foregroundStyle(tint)
            }.font(.system(size: 11, weight: .medium))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }.frame(height: 4)
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
