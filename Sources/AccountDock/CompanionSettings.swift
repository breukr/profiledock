import AppKit
import SwiftUI
import DockCore

struct ClaudeConnectionView: View {
    @ObservedObject var model: DockModel
    @State private var enabled = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude Code activity", systemImage: "waveform.path").font(.headline)
                Spacer()
                Button(enabled ? "Disconnect" : "Connect Claude Code") { connect(!enabled) }.disabled(busy)
            }
            Text("Show working, needs-input and completed states for local Code sessions in Claude Desktop and Terminal. Start a new Claude Code session after connecting.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Connection adds local hooks to Claude settings and keeps a backup. Prompts, responses and credentials are not collected. Claude Chat and Cowork status are unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            if model.claudeBridge.hasCustomStatusline {
                Text("Your existing status line keeps its output. ProfileDock passes its input through while collecting usage counters.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.onAppear { enabled = model.claudeBridge.enabled }
    }
    private func connect(_ value: Bool) {
        busy = true; message = nil
        let bridge = model.claudeBridge
        let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ProfileDockClaude")
        Task {
            defer { busy = false; enabled = bridge.enabled }
            do {
                try await Task.detached { try bridge.setEnabled(value, bundledHelper: helper) }.value
                message = value ? "Connected. New Claude Code sessions will report activity here." : "Disconnected. Your other Claude settings are kept."
                model.companions.refresh()
            } catch { message = error.localizedDescription }
        }
    }
}

struct CompanionDetails: View {
    @ObservedObject var model: DockModel
    let profile: Profile
    var body: some View {
        GroupBox(profile.kind.label) {
            VStack(alignment: .leading, spacing: 12) {
                if profile.kind == .claude {
                    Text("Uses your existing Claude Desktop installation and sign-in. Claude manages its own updates.")
                } else {
                    Text("Opens this project in its own Terminal tab. If the tab closes, Open starts a new one in the same folder.")
                    if let error = model.companions.terminalError { Text(error).foregroundStyle(.orange) }
                    Text(profile.projectPath ?? model.home.path).font(.caption).textSelection(.enabled)
                    Button("Choose project folder…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                var changed = profile; changed.projectPath = url.path; model.update(changed)
                            }
                        }
                    }
                }
                if profile.kind != .terminal {
                    Text("Local Claude Code history is available in Search chats. Context access controls which other profiles can retrieve it.").font(.caption)
                }
                if let latest = model.companions.sessions(for: profile).max(by: { $0.updatedAt < $1.updatedAt }) {
                    Divider()
                    Text("Latest Claude Code session").font(.subheadline.weight(.medium))
                    if let input = latest.inputTokens, let output = latest.outputTokens {
                        Text("\(input.formatted()) input · \(output.formatted()) output tokens").font(.caption)
                    }
                    if let cost = latest.costUSD { Text("Session API-equivalent cost: \(cost, format: .currency(code: "USD"))").font(.caption) }
                    Text("Reported \(latest.updatedAt.formatted(date: .abbreviated, time: .shortened)). This is not your subscription bill.").font(.caption).foregroundStyle(.secondary)
                }
            }.font(.callout).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
