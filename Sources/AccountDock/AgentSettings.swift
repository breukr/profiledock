import AppKit
import SwiftUI
import DockCore

/// The app icon for a desktop tool, otherwise a monogram tile in the tool's color, so every CLI looks alike.
struct AgentIcon: View {
    @ObservedObject var model: DockModel
    let tool: AgentTool
    var size: CGFloat = 28
    /// Desktop tools show their app icon. Terminal tools show the Terminal mark in the tool's color with the tool's
    /// badge, exactly as their tiles do; the badge is left out where it would be too small to read.
    var body: some View {
        Group {
            if let path = model.installedAgent(tool.id)?.applicationPath ?? (tool.launchesInTerminal ? nil : model.cachedApplicationPath(tool.bundleIdentifiers)) {
                Image(nsImage: model.cachedIcon(path)).resizable().interpolation(.high)
            } else {
                Image(nsImage: model.toolArtwork(tool)).resizable().interpolation(.high)
                    .overlay(alignment: .topTrailing) {
                        if size >= 24, tool.launchesInTerminal {
                            Image(nsImage: model.terminalAgentArtwork(TerminalAgent(rawValue: tool.id))).resizable()
                                .frame(width: size * 0.46, height: size * 0.46).clipShape(Circle())
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)).offset(x: size * 0.12, y: -size * 0.12)
                        }
                    }
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
    static func monogram(_ tool: AgentTool) -> String {
        let words = tool.name.split(whereSeparator: { $0 == " " || $0 == "/" }).filter { $0.first?.isLetter == true }
        if words.count > 1, tool.name.count > 8 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(tool.name.prefix(2))
    }

}

enum AgentFilter: String, CaseIterable, Identifiable {
    case all = "All", terminal = "Terminal", apps = "Apps", separate = "Separate accounts"
    var id: String { rawValue }
    var title: String { self == .separate ? "Separate" : rawValue }
    func includes(_ tool: AgentTool) -> Bool {
        switch self {
        case .all: return true
        case .terminal: return tool.launchesInTerminal
        case .apps: return !tool.launchesInTerminal
        case .separate: return tool.supportsIsolatedProfiles || tool.legacy
        }
    }
}

extension AgentTool {
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return ([name, id] + executables + applicationNames).contains { $0.lowercased().contains(query) }
    }
    /// Only the exception is spelled out in lists; the notes say why either way.
    var accountSummary: String { legacy || supportsIsolatedProfiles ? "" : "Existing sign-in only" }
}

@MainActor extension DockModel {
    func profiles(for tool: AgentTool) -> [Profile] {
        preferences.profiles.filter { profile in
            switch tool.id {
            case "codex": return profile.kind == .codex
            case "claude-desktop": return profile.kind == .claude
            case "claude": return profile.kind == .claudeCode
            default: return profile.kind == .agent && profile.agentID == tool.id
            }
        }
    }
    /// From the last refresh, so list rows never query running apps themselves.
    func isRunning(_ tool: AgentTool) -> Bool {
        if tool.bundleIdentifiers.contains(where: runningBundles.contains) { return true }
        return companions.windows.contains { $0.agent?.rawValue == tool.id }
    }
    /// Home folder paths read as `~/…` in the interface.
    func displayPath(_ path: String) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}

struct AgentsSettingsView: View {
    @ObservedObject var model: DockModel
    /// Opens Add Profile on one tool, for Claude, Codex and separate accounts.
    let addProfile: (String?) -> Void
    @State private var query = ""
    @State private var filter = AgentFilter.all
    @State private var showOthers = false

    private var tools: [AgentTool] { AgentRegistry.tools.filter { $0.id != "claude" && filter.includes($0) && $0.matches(query) } }
    private var installed: [AgentTool] { tools.filter { model.installedAgent($0.id)?.isInstalled == true || !model.profiles(for: $0).isEmpty } }
    private var usedBefore: [AgentTool] { tools.filter { tool in !installed.contains(tool) && model.installedAgent(tool.id) != nil } }
    private var others: [AgentTool] { tools.filter { tool in !installed.contains(tool) && !usedBefore.contains(tool) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Automatic") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Add running agent apps", detail: "Apps such as Grok Bot or T3 Code get a tile with the sign-in already on this Mac while they run. A tile you remove stays removed.") {
                        Toggle("Add running agent apps automatically", isOn: Binding(get: { model.preferences.autoAddAgents != false }, set: model.setAutoAddAgents))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Find coding terminals", detail: "Terminal tabs running a coding agent appear in the strip while the agent runs.") {
                        Toggle("Automatically find coding terminals", isOn: Binding(get: { model.preferences.discoverTerminals != false }, set: {
                            model.preferences.discoverTerminals = $0; model.save(); model.companions.refresh()
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            if let error = model.companions.terminalError {
                SettingsNotice(text: error, symbol: "lock.trianglebadge.exclamationmark", isWarning: true,
                               actionTitle: "Open Privacy Settings", action: { NSWorkspace.shared.open(DockModel.automationSettings) })
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { searchField.frame(minWidth: 150, maxWidth: 240); filterPicker.fixedSize(); Spacer(minLength: 0); scanButton }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { searchField; scanButton }
                    filterPicker
                }
            }
            if model.installedAgents == nil {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking for coding tools on this Mac…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                section("On this Mac", tools: installed, empty: query.isEmpty ? "No supported coding tools are installed yet. Install one from the list below, then scan again." : "No installed tool matches “\(query)”.")
                if !usedBefore.isEmpty {
                    section("Used before, not installed", tools: usedBefore, empty: nil,
                            footnote: "These tools left a settings folder on this Mac, but their command or app is gone.")
                }
                DisclosureGroup(isExpanded: Binding(get: { showOthers || !query.isEmpty }, set: { showOthers = $0 })) {
                    section(nil, tools: others, empty: "No other tool matches.").padding(.top, 8)
                } label: {
                    Text("Other supported tools · \(others.count)").font(.headline)
                }
            }
            Text("ProfileDock checks where a tool is installed and which apps are running. It never opens sign-in files, tokens or the Keychain. [How each tool is recognized](https://github.com/breukr/profiledock/blob/main/docs/AGENT-COVERAGE.md)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.scanAgents() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find a tool", text: $query).textFieldStyle(.plain).accessibilityLabel("Find a coding tool")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.padding(6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
    private var filterPicker: some View {
        Picker("Show", selection: $filter) { ForEach(AgentFilter.allCases) { Text($0.title).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Show tools")
    }
    private var scanButton: some View {
        HStack(spacing: 8) {
            if model.agentScanTask != nil, model.installedAgents != nil { ProgressView().controlSize(.small).accessibilityLabel("Looking for coding tools") }
            Button { model.scanAgents(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.agentScanTask != nil).help("Look for coding tools again. ProfileDock checks only file and app locations.")
                .accessibilityLabel("Scan for coding tools again")
        }
    }

    @ViewBuilder private func section(_ title: String?, tools: [AgentTool], empty: String?, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            if tools.isEmpty {
                if let empty { Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6) }
            } else {
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            AgentToolRow(model: model, tool: tool, addProfile: addProfile)
                            if index < tools.count - 1 { Divider().padding(.leading, 60) }
                        }
                    }
                }
            }
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct AgentToolRow: View {
    @ObservedObject var model: DockModel
    let tool: AgentTool
    let addProfile: (String?) -> Void
    @State private var showingNotes = false

    var body: some View {
        let found = model.installedAgent(tool.id)
        let entries = model.profiles(for: tool)
        let running = model.isRunning(tool)
        HStack(spacing: 12) {
            AgentIcon(model: model, tool: tool, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if running { StatusCapsule(text: "Running", color: .green) }
                    else if found?.isInstalled != true, !entries.isEmpty { StatusCapsule(text: "Not installed", color: .orange) }
                    if (found?.applications.count ?? 0) > 1 { StatusCapsule(text: "\(found!.applications.count) copies", color: .secondary) }
                }
                Text(detail(found)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(detail(found))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !tool.accountSummary.isEmpty {
                Text(tool.accountSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(tool.accountNotice)
            }
            Button { showingNotes = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("Notes about \(tool.name)").accessibilityLabel("Notes about \(tool.name)")
                .popover(isPresented: $showingNotes, arrowEdge: .trailing) { notes(found) }
            action(found: found, entries: entries).frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func action(found: InstalledAgent?, entries: [Profile]) -> some View {
        if !entries.isEmpty, found?.isInstalled != true, !model.isRunning(tool), let url = URL(string: tool.documentation) {
            // In ProfileDock, but its command or app is gone: the fix comes first.
            Link("Get…", destination: url).font(.callout).help(model.missingToolMessage(tool)).accessibilityLabel("Get \(tool.name)")
        } else if !entries.isEmpty {
            Label(entries.count == 1 ? "Added" : "\(entries.count) added", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .accessibilityLabel("\(tool.name) is in ProfileDock")
        } else if found?.isInstalled == true || model.isRunning(tool) {
            if tool.legacy {
                Button("Add…") { addProfile(tool.id) }.accessibilityLabel("Add \(tool.name)")
            } else {
                Button("Add") { model.addDetectedAgent(tool.id) }.buttonStyle(.borderedProminent)
                    .help("Add \(tool.name) with the sign-in already on this Mac.").accessibilityLabel("Add \(tool.name)")
            }
        } else if let url = URL(string: tool.documentation) {
            Link("Get…", destination: url).font(.callout).help("Open the \(tool.name) website to install it.")
                .accessibilityLabel("Get \(tool.name)")
        }
    }

    private func detail(_ found: InstalledAgent?) -> String {
        if let path = found?.executablePath { return model.displayPath(path) }
        if let path = found?.applicationPath { return model.displayPath(path) }
        if let path = found?.configPath { return "Not installed · settings in " + model.displayPath(path) }
        if tool.launchesInTerminal { return "Not installed · command " + tool.executables.joined(separator: ", ") }
        return "Not installed · " + (tool.applicationNames.first ?? tool.name)
    }

    private func notes(_ found: InstalledAgent?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentIcon(model: model, tool: tool, size: 28)
                Text(tool.name).font(.headline)
            }
            LabeledContent("Separate accounts") { Text(tool.legacy ? "Yes" : tool.supportsIsolatedProfiles ? "Yes" : "No") }
            Text(tool.legacy ? "Claude and ChatGPT / Codex keep their own account handling in ProfileDock." : tool.accountNotice)
                .fixedSize(horizontal: false, vertical: true)
            Text("Where the sign-in lives: " + tool.authNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let copies = found?.applications, copies.count > 1 {
                Text("Copies found, the first one opens:\n" + copies.map { "• " + model.displayPath($0.path) + ($0.version.map { " (\($0))" } ?? "") }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if found?.isInstalled != true, let hint = tool.installHint { InstallCommand(tool: tool, command: hint) }
            if let url = URL(string: tool.documentation) { Link("\(tool.name) documentation", destination: url).font(.callout) }
        }.padding(16).frame(width: 340, alignment: .leading)
    }
}

/// A copyable install command in a monospaced box.
struct InstallCommand: View {
    let tool: AgentTool
    let command: String
    var body: some View {
        HStack {
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy the install command").accessibilityLabel("Copy the install command for \(tool.name)")
        }.padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct StatusCapsule: View {
    let text: String
    let color: Color
    /// The color is only the dot; the text keeps system contrast in both appearances.
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color == .secondary ? Color.secondary : color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }.fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
