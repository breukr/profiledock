import AppKit
import SwiftUI
import DockCore

/// A single quiet nudge per disconnected account, without taking keyboard focus.
@MainActor
final class AccountConnectionNotice {
    private var panel: NSPanel?

    func show(usage: UsageStore, home: URL) {
        guard !usage.disconnectedProfiles.isEmpty else { dismiss(); return }
        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
            let width = min(440, visible.width - 32)
            let frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - 300, width: width, height: 280)
            let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "ProfileDock: reconnect account"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: AccountConnectionNoticeView(usage: usage, home: home, dismiss: { [weak self] in self?.dismiss() }).frame(width: width, height: 280))
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func dismiss() { panel?.close(); panel = nil }
}

struct AccountConnectionNoticeView: View {
    @ObservedObject var usage: UsageStore
    let home: URL
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign-in needed", systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
            Text("Reconnect to restore subscription limits. Finish signing in with the account belonging to this profile.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(usage.disconnectedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(profile.usesClaudeAccountUsage ? "Claude account (shared by Claude tiles)" : profile.name).fontWeight(.medium)
                                Spacer()
                                if usage.isReconnecting(profile) {
                                    ProgressView().controlSize(.small)
                                    Button("Cancel") { usage.cancelReconnect(profile) }
                                } else {
                                    Button("Reconnect") { usage.reconnect(profile, home: home) }
                                        .accessibilityLabel("Reconnect \(profile.name)")
                                }
                            }
                            if usage.isReconnecting(profile) {
                                Text("Finish sign-in in your browser. Limits refresh automatically afterwards.").font(.caption).foregroundStyle(.secondary)
                            }
                            if let message = usage.reconnectionMessages[usage.connectionKey(profile)] {
                                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.padding(.trailing, 4)
            }
            HStack { Spacer(); Button("Later", action: dismiss) }
        }
        .padding(18)
        .onChange(of: usage.disconnectedProfiles.count) { _, count in if count == 0 { dismiss() } }
    }
}
