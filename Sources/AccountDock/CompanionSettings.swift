import AppKit
import SwiftUI
import DockCore

struct ActivityConnectionsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var activity: ActivityMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Codex activity connector", systemImage: "waveform.path").font(.headline)
                Spacer()
                Button(model.preferences.codexActivityEnabled != false ? "Disconnect" : "Connect Codex") {
                    model.preferences.codexActivityEnabled = model.preferences.codexActivityEnabled == false
                    model.save(); model.refresh()
                }
            }
            let connected = model.preferences.profiles.filter { $0.kind == .codex && activity.entries[$0.id]?.liveAvailable == true }.count
            Text(model.preferences.codexActivityEnabled == false ? "Disconnected. Your profiles remain available." : "Connected automatically to saved Codex / ChatGPT profiles. \(connected) live now.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Tracks local Work and Codex tasks. Ordinary ChatGPT conversations and Codex terminal activity are not reported by this connector.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ClaudeConnectionView(model: model)
            Divider()
            HStack {
                Label("Terminal connector", systemImage: "terminal").font(.headline)
                Spacer()
                Button("Refresh") { model.companions.refresh() }
            }
            Toggle("Automatically find coding terminals", isOn: Binding(get: { model.preferences.discoverTerminals != false }, set: {
                model.preferences.discoverTerminals = $0; model.save(); model.companions.refresh()
            }))
            Toggle("Expand terminals in the strip", isOn: Binding(get: { model.preferences.terminalsExpanded != false }, set: model.setTerminalsExpanded))
            Text("\(model.liveTerminalProfiles.count) coding terminals found. Open Terminal.app tabs appear automatically while Claude Code or Codex is running. Closed sessions disappear.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Allow Terminal access if macOS asks. Other terminal apps, SSH and background sessions are not included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.companions.terminalError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct ClaudeConnectionView: View {
    @ObservedObject var model: DockModel
    @State private var enabled = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude Code activity connector", systemImage: "waveform.path").font(.headline)
                Spacer()
                Button(enabled ? "Disconnect" : "Connect Claude Code") { connect(!enabled) }.disabled(busy)
            }
            Text("Show working, needs-input and completed states for local Code sessions in Claude Desktop and Terminal. Start a new Claude Code session after connecting.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Connection adds local hooks to Claude settings and keeps a backup. Prompts, responses and credentials are not collected. Claude Chat and Cowork status are unavailable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.claudeBridge.hasCustomStatusline {
                Text("Your existing status line keeps its output. ProfileDock passes its input through while collecting usage counters.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
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
                if value {
                    let application = NSRunningApplication.runningApplications(withBundleIdentifier: ProfileProvider.claude.bundleIdentifier).first?.bundleURL
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ProfileProvider.claude.bundleIdentifier)
                    let recognized = try model.recognizeClaudeDesktop(application: application)
                    model.preferences.discoverTerminals = true; model.preferences.terminalsExpanded = true; model.save()
                    message = (recognized ? "Claude Desktop recognized and added. " : "Claude Code connected. ") + "Open coding terminals appear automatically. Start a new Claude Code session to receive activity updates."
                } else { message = "Disconnected. Your other Claude settings are kept." }
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
                    Text("Reported \(latest.updatedAt.formatted(date: .abbreviated, time: .shortened)). This is not your subscription bill.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
