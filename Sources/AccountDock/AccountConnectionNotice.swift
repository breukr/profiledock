import AppKit
import SwiftUI
import DockCore

/// Inline sign-in notice inside the strip. It never takes keyboard focus or opens a window.
struct SignInNoticeBanner: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var model: DockModel

    var body: some View {
        let profiles = usage.signInNotices
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(profiles.count == 1 ? "Sign-in needed" : "\(profiles.count) accounts need sign-in").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("Later") { usage.dismissNotices() }.help("Hide this notice. Tiles keep their Reconnect button.")
                }
                ForEach(profiles) { profile in
                    let key = usage.connectionKey(profile)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(profile.usesClaudeAccountUsage ? "Claude account" : profile.name).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 4)
                            if usage.isReconnecting(profile) {
                                ProgressView().controlSize(.mini)
                                Button("Cancel") { usage.cancelReconnect(profile) }
                            } else {
                                Button("Reconnect") { usage.reconnect(profile, home: model.home) }
                                    .buttonStyle(.borderedProminent).controlSize(.small).accessibilityLabel("Reconnect \(profile.name)")
                            }
                            Menu {
                                Button("Don’t remind me about this account") { model.muteSignInReminders(for: key) }
                            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel("More options for \(profile.name)")
                        }
                        if usage.isReconnecting(profile) {
                            Text("Finish sign-in in your browser. Limits refresh automatically.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                        } else if let message = usage.reconnectionMessages[key] {
                            Text(message).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5))
            .accessibilityElement(children: .contain).accessibilityLabel("Sign-in needed")
        }
    }
}
