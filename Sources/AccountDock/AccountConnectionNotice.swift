import AppKit
import SwiftUI
import DockCore

/// Inline sign-in notice inside the strip. It never takes keyboard focus or opens a window.
/// One aligned row per account: badge, name and reason on the left, a fixed action column on the right
/// (Reconnect, then a ⋯ menu with "Later" and "Don't remind me"), so every row shares the same edges.
struct SignInNoticeBanner: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var model: DockModel
    /// Width of the trailing ⋯ column; the header's dismiss button uses the same column so right edges line up.
    static let menuColumn: CGFloat = 24
    static let badgeColumn: CGFloat = 26

    var body: some View {
        let profiles = usage.signInNotices
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if profiles.count > 1 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange).frame(width: Self.badgeColumn).accessibilityHidden(true)
                        Text("\(profiles.count) accounts need sign-in").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer(minLength: 8)
                        dismissButton(help: "Hide this notice. Tiles keep their Reconnect button.") { usage.dismissNotices() }
                    }
                }
                ForEach(profiles) { profile in row(profile) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: CGFloat(CardMetrics.cornerRadius), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CGFloat(CardMetrics.cornerRadius), style: .continuous).strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.5))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel(profiles.count == 1 ? "Sign-in needed" : "\(profiles.count) accounts need sign-in")
        }
    }

    private func row(_ profile: Profile) -> some View {
        let key = usage.connectionKey(profile)
        let reconnecting = usage.isReconnecting(profile)
        let name = profile.usesClaudeAccountUsage && !profile.usesSeparateClaudeAccount ? "Claude account" : profile.name
        return HStack(alignment: .center, spacing: 10) {
            ProfileBadge(model: model, profile: profile, size: 22, showStatus: false)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(.orange).frame(width: 8, height: 8).overlay(Circle().stroke(.black, lineWidth: 1.5)).offset(x: 3, y: 3)
                }
                .frame(width: Self.badgeColumn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(1).truncationMode(.middle).help(name)
                if reconnecting || usage.reconnectionMessages[key] != nil {
                    Text(reconnecting ? "Finish sign-in in your browser. Usage refreshes automatically." : usage.reconnectionMessages[key] ?? "")
                        .font(.system(size: 10)).foregroundStyle(reconnecting ? .white.opacity(0.6) : .orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    // Provider plus reason where it fits; the reason alone on a narrow strip.
                    let reason = usage.entries[profile.id]?.error?.statusLabel ?? "Sign-in needed"
                    ViewThatFits(in: .horizontal) {
                        Text("\(provider(profile)) · \(reason)")
                        Text(reason)
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .help("\(provider(profile)) · \(reason)")
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if reconnecting {
                ProgressView().controlSize(.small).accessibilityLabel("Waiting for sign-in")
                Button("Cancel") { usage.cancelReconnect(profile) }.controlSize(.small).buttonStyle(.bordered).fixedSize()
            } else {
                // Fixed size: the name truncates before the action ever shrinks.
                Button("Reconnect") { usage.reconnect(profile, home: model.home) }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange).fixedSize()
                    .accessibilityLabel("Reconnect \(profile.name)")
            }
            Menu {
                Button("Remind me later") { usage.dismissNotices() }
                Button("Don’t remind me about this account") { model.muteSignInReminders(for: key) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: Self.menuColumn, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options for \(profile.name)").help("Remind me later, or stop reminders for this account")
        }
        .frame(minHeight: 28)
    }

    private func provider(_ profile: Profile) -> String {
        profile.usesClaudeAccountUsage ? "Claude" : profile.kind == .codex ? "ChatGPT" : (profile.agentTool?.name ?? profile.tileCaption)
    }

    private func dismissButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.menuColumn, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel("Remind me later")
    }
}
