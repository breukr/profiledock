import AppKit
import SwiftUI
import DockCore

/// Installed tools that are not in ProfileDock yet, each one click away.
struct FoundAgentsCard: View {
    @ObservedObject var model: DockModel
    var compact = false
    let review: () -> Void
    private var offers: [InstalledAgent] {
        AgentAutoAdd.offers(installed: model.installedAgents ?? [], profiles: model.preferences.profiles,
                            dismissed: Set((model.preferences.dismissedAgentTools ?? []) + (model.preferences.hiddenAgentOffers ?? [])))
    }
    var body: some View {
        let offers = self.offers
        if !offers.isEmpty {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Found on this Mac", systemImage: "sparkle.magnifyingglass").font(.headline)
                        Spacer()
                        if !compact {
                            Button("Not Now") { dismiss(offers) }.buttonStyle(.borderless)
                                .help("Stop suggesting these tools here. You can still add them from Coding Agents.")
                        }
                    }
                    Text(offers.count == 1 ? "\(offers[0].tool.name) is installed but not in ProfileDock yet." : "\(offers.count) coding tools are installed but not in ProfileDock yet.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    WrappingStack(spacing: 8) {
                        buttons(offers.prefix(compact ? 4 : 8))
                        review(offers.count > (compact ? 4 : 8))
                    }
                    Text("Added with the sign-in already on this Mac. Choose a separate account in Add Profile.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
        }
    }
    @ViewBuilder private func buttons(_ offers: ArraySlice<InstalledAgent>) -> some View {
        ForEach(Array(offers)) { offer in
            Button { model.addDetectedAgent(offer.id) } label: {
                HStack(spacing: 6) {
                    AgentIcon(model: model, tool: offer.tool, size: 16)
                    Text(offer.tool.name).lineLimit(1)
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                }
            }.help("Add \(offer.tool.name) with the sign-in already on this Mac.").accessibilityLabel("Add \(offer.tool.name)")
        }
    }
    @ViewBuilder private func review(_ more: Bool) -> some View {
        Button(more ? "See All in Coding Agents…" : "Coding Agents…", action: review).buttonStyle(.borderless)
    }
    private func dismiss(_ offers: [InstalledAgent]) {
        // Only suggestions: automatic adding of running apps keeps its own setting and removals.
        model.preferences.hiddenAgentOffers = Array(Set((model.preferences.hiddenAgentOffers ?? []) + offers.map(\.id))).sorted()
        model.save()
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct WrappingStack: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                var size = subviews[index].sizeThatFits(.unspecified)
                // An item wider than the row is offered the row's width, so it truncates instead of overflowing.
                if size.width > bounds.width { size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)); size.width = min(size.width, bounds.width) }
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else { rows.append(([index], size.width, size.height)) }
        }
        return rows
    }
}

/// The dot before a profile's state in lists: open, busy, or a problem with its fix in the tooltip.
struct ProfileStateMark: View {
    @ObservedObject var model: DockModel
    let profile: Profile
    var body: some View {
        Group {
            if model.opening.contains(profile.id) || model.closing.contains(profile.id) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else if model.agentAvailability(profile) == .missing, model.running[profile.id]?.isEmpty != false {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    .help(profile.agentTool.map(model.missingToolMessage) ?? "")
            } else if model.agentsNeedingSignIn.contains(profile.id), model.running[profile.id]?.isEmpty != false {
                Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 10)).foregroundStyle(.orange)
                    .help("Open this profile and sign in with the account you want it to use.")
            } else {
                Circle().fill(model.running[profile.id]?.isEmpty == false ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            }
        }.accessibilityHidden(true)
    }
}

struct RemoveProfileSheet: View {
    @ObservedObject var model: DockModel
    let profile: Profile
    @Binding var trashData: Bool
    let done: () -> Void
    /// A shared desktop agent entry owns no data, so it can go while its app stays open.
    private var ownsNothing: Bool { profile.kind == .agent && !profile.usesIsolatedAgentHome && profile.agentTool?.launchesInTerminal == false }
    private var isOpen: Bool {
        model.opening.contains(profile.id) || model.nativeDockOperations.contains(profile.id) || (!ownsNothing && model.running[profile.id]?.isEmpty == false)
    }
    /// When Terminal or a process cannot be read, an account folder may still be in use, so it is not offered for the Trash.
    private var uncertain: Bool { model.companions.terminalError != nil || model.unreadableProcesses }
    /// Only folders ProfileDock created for this profile can go to the Trash.
    private var ownsData: Bool {
        guard profile.id.hasPrefix("profile-") else { return false }
        return profile.kind == .codex || profile.usesIsolatedAgentHome || profile.usesSeparateClaudeAccount
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove \(profile.name)?").font(.title2.weight(.semibold))
            Text(summary).fixedSize(horizontal: false, vertical: true)
            if ownsData {
                Toggle(profile.kind == .codex ? "Also move this profile’s data and managed app copy to the Trash" : "Also move this account’s folder to the Trash", isOn: $trashData)
                    .disabled(uncertain)
                if uncertain {
                    Text("ProfileDock can’t check right now whether this account is still in use, so its folder stays where it is.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if trashData, profile.kind != .codex {
                    Text("Its sign-in, settings and history for this profile go to the Trash. You can restore them from there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isOpen {
                SettingsNotice(text: "\(profile.name) is open. Close it first so nothing it is using is removed.", symbol: "exclamationmark.triangle.fill", isWarning: true,
                               actionTitle: model.closing.contains(profile.id) ? nil : "Close \(profile.name)", action: { model.requestQuit(profile) })
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    do { try model.removeProfile(profile, trashData: trashData && ownsData && !uncertain); done() }
                    catch { model.message = error.localizedDescription; done() }
                }.disabled(isOpen)
            }
        }.padding(28).frame(width: 480)
    }
    private var summary: String {
        if profile.kind == .agent, let tool = profile.agentTool, !profile.usesIsolatedAgentHome {
            let again = profile.addedAutomatically == true ? " ProfileDock won’t add it automatically again; add it from Coding Agents any time." : ""
            return "The profile will disappear from ProfileDock. \(tool.name) and its sign-in stay as they are." + again
        }
        return "The profile will disappear from ProfileDock. Its chats and sign-in data stay on this Mac unless you choose to move them to the Trash."
    }
}
