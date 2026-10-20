import AppKit
import SwiftUI
import DockCore

struct AddChoice: Hashable {
    var provider: ProfileProvider
    var toolID: String?
    static let codex = AddChoice(provider: .codex, toolID: nil)
    init(provider: ProfileProvider, toolID: String?) {
        self.provider = provider
        self.toolID = toolID
    }
    /// A registry id, or one of the built-in entries.
    init(id: String) {
        switch id {
        case "codex": self = .codex
        case "claude-desktop": self.init(provider: .claude, toolID: nil)
        case "claude": self.init(provider: .claudeCode, toolID: nil)
        case "terminal": self.init(provider: .terminal, toolID: nil)
        default: self.init(provider: .agent, toolID: id)
        }
    }
    var key: String {
        switch provider {
        case .codex: return "codex"
        case .claude: return "claude-desktop"
        case .claudeCode: return "claude"
        case .terminal: return "terminal"
        case .agent: return toolID ?? "agent"
        }
    }
}

/// One line in the Add Profile list.
private struct AddItem: Identifiable {
    var id: String { choice.key }
    let choice: AddChoice
    let title: String
    let detail: String
    let installed: Bool
    let tool: AgentTool?
    let bundleIdentifier: String?
    let keywords: [String]
}

struct AddProfileSheet: View {
    @ObservedObject var model: DockModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var nameEdited = false
    @FocusState private var focus: Field?
    private enum Field { case search, name }
    @State private var query = ""
    @State private var selection: String?
    init(model: DockModel) { self.model = model }
    /// Starts on one registry tool or built-in entry, for Settings → Coding Agents and visual checks.
    init(model: DockModel, start: String, separate: Bool = false) {
        self.model = model
        _selection = State(initialValue: AddChoice(id: start).key)
        _separateAgent = State(initialValue: separate)
        _separateClaude = State(initialValue: separate)
    }
    init(model: DockModel, toolID: String, separate: Bool) { self.init(model: model, start: toolID, separate: separate) }
    private var choice: AddChoice? { selection.map(AddChoice.init(id:)) }
    private var kind: ProfileProvider { choice?.provider ?? .codex }
    private var selectedTool: AgentTool? { choice?.toolID.flatMap { AgentRegistry.tool(id: $0) } }
    @State private var project: URL?
    @State private var terminalWindows: [TerminalWindow] = []
    @State private var terminalSelection = ""
    @State private var loadingWindows = false
    @State private var separate = false
    @State private var separateClaude = false
    @State private var separateAgent = false
    @State private var source: URL?
    @State private var creating = false
    @State private var error: String?
    /// The tab list's own message, kept apart so polling never hides an error from Create.
    @State private var listError: String?

    private var items: [AddItem] {
        let claudeCLI = model.installedAgent("claude")?.executablePath != nil
        let claudeApp = model.cachedApplicationPath([ProfileProvider.claude.bundleIdentifier]) != nil
        var result = [
            AddItem(choice: .codex, title: "ChatGPT / Codex", detail: model.defaultApplication.map { "Separate sign-in · " + $0.lastPathComponent } ?? "Not installed",
                    installed: model.defaultApplication != nil, tool: AgentRegistry.tool(id: "codex"), bundleIdentifier: "com.openai.codex", keywords: ["chatgpt", "codex", "openai"]),
            AddItem(choice: AddChoice(id: "claude-desktop"), title: "Claude Desktop", detail: claudeApp ? "Existing sign-in or a separate account" : "Not installed",
                    installed: claudeApp, tool: AgentRegistry.tool(id: "claude-desktop"), bundleIdentifier: ProfileProvider.claude.bundleIdentifier, keywords: ["claude", "anthropic"]),
            AddItem(choice: AddChoice(id: "claude"), title: "Claude Code project", detail: claudeCLI ? "Runs claude in a project folder" : "Runs claude in a project folder · not found",
                    installed: claudeCLI, tool: AgentRegistry.tool(id: "claude"), bundleIdentifier: "com.apple.Terminal", keywords: ["claude", "code", "terminal", "project"]),
            AddItem(choice: AddChoice(id: "terminal"), title: "Open Terminal tab", detail: "A tab where a coding agent is running now",
                    installed: true, tool: nil, bundleIdentifier: "com.apple.Terminal", keywords: ["terminal", "tab", "running", "session"])
        ]
        for tool in AgentRegistry.addable {
            let found = model.installedAgent(tool.id)
            let added = model.profiles(for: tool).count
            let running = model.isRunning(tool)
            var parts: [String] = []
            if running { parts.append("Running") }
            if let path = found?.executablePath ?? found?.applicationPath { parts.append(model.displayPath(path)) }
            else if !running { parts.append(found == nil ? "Not installed" : "Not installed · used before") }
            if added > 0 { parts.append(added == 1 ? "1 profile" : "\(added) profiles") }
            result.append(AddItem(choice: AddChoice(provider: .agent, toolID: tool.id), title: tool.name, detail: parts.joined(separator: " · "),
                                  installed: found?.isInstalled == true || running, tool: tool, bundleIdentifier: nil, keywords: [tool.id] + tool.executables))
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return result.filter { item in words.allSatisfy { word in ([item.title.lowercased()] + item.keywords).contains { $0.contains(word) } } }
    }

    var body: some View {
        let all = items
        let detected = all.filter(\.installed)
        let others = all.filter { !$0.installed }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Profile").font(.title2.weight(.semibold))
                Text("Tools found on this Mac come first. Search to find any supported tool.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search apps and coding tools", text: $query).textFieldStyle(.plain).focused($focus, equals: .search)
                    .accessibilityLabel("Search apps and coding tools")
                    .onSubmit { if let first = (detected + others).first { select(first.id); focus = .name } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.padding(7).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            ScrollViewReader { reader in
            List(selection: Binding(get: { selection }, set: { if let value = $0 { select(value) } })) {
                // Plain heading rows rather than sticky section headers, which cover the first row while scrolling.
                if !detected.isEmpty {
                    header("On this Mac")
                    ForEach(detected) { row($0) }
                }
                if !others.isEmpty {
                    header("Not installed")
                    ForEach(others) { row($0) }
                }
                if detected.isEmpty && others.isEmpty {
                    Text("No supported tool matches “\(query)”.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false)).frame(height: 236)
            .accessibilityLabel("Apps and coding tools")
            .task {
                // After the first layouts, so the chosen tool is visible even far down the list.
                for delay in [30, 120] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    if let selection { reader.scrollTo(selection, anchor: .center) }
                }
            }
            }
            if choice != nil { form } else {
                Text("Choose an app or coding tool above.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = error ?? listError {
                // The color is only the icon, so the message keeps full contrast in light mode.
                Label { Text(error).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.callout)
            }
            if creating { ProgressView("Creating your profile…").controlSize(.small) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                // Return in the search field picks a tool; it never creates a profile by accident.
                Button("Create Profile") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(focus == .search ? nil : .defaultAction)
                    .disabled(createHint != nil).help(createHint ?? "Create this profile")
            }
        }
        .padding(24).frame(width: 640).disabled(creating).interactiveDismissDisabled(creating)
        .onAppear {
            model.scanAgents()
            if let selection { select(selection, force: true); focus = .name } else { focus = .search }
        }
        .task(id: selection) {
            guard kind.usesTerminal, choice != nil else { return }
            while !Task.isCancelled {
                await refreshTerminals()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 4).selectionDisabled().accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: AddItem) -> some View {
        HStack(spacing: 10) {
            itemIcon(item).opacity(item.installed ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(item.installed ? .primary : .secondary)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let tool = item.tool, item.choice.provider == .agent {
                if !tool.accountSummary.isEmpty { Text(tool.accountSummary).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3).tag(item.id).id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.detail)")
    }

    @ViewBuilder private func itemIcon(_ item: AddItem) -> some View {
        if let bundle = item.bundleIdentifier, let path = model.cachedApplicationPath([bundle]) {
            Image(nsImage: model.cachedIcon(path)).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
        } else if let tool = item.tool {
            AgentIcon(model: model, tool: tool, size: 26)
        } else {
            Image(systemName: "terminal").frame(width: 26, height: 26).accessibilityHidden(true)
        }
    }

    private func select(_ id: String, force: Bool = false) {
        guard force || id != selection else { return }
        selection = id
        let value = AddChoice(id: id)
        terminalSelection = ""; terminalWindows = []; error = nil; listError = nil
        if value.provider == .claude, !force { separateClaude = hasSharedClaude }
        // Start from the sign-in already on this Mac; a desktop app that already has that entry offers a separate account.
        if let tool = value.toolID.flatMap(AgentRegistry.tool(id:)), !force { separateAgent = !tool.launchesInTerminal && hasSharedAgent(tool) }
        if !nameEdited { name = defaultName(value) }
    }

    private func defaultName(_ value: AddChoice) -> String {
        switch value.provider {
        case .codex: return model.preferences.profiles.contains { $0.kind == .codex } ? "" : "Personal"
        case .claude: return "Claude"
        case .claudeCode: return project?.lastPathComponent ?? "Claude Code"
        case .terminal: return ""
        case .agent: return value.toolID.flatMap { AgentRegistry.tool(id: $0)?.name } ?? ""
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(choiceDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let tool = selectedTool, model.installedAgent(tool.id)?.isInstalled != true, model.installedAgents != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("\(tool.name) isn’t installed. You can add it now; it shows Not installed until it is.").fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.caption)
                    if let hint = tool.installHint { InstallCommand(tool: tool, command: hint) }
                }
            }
            LabeledContent("Profile name") {
                // Only a real change counts as editing; an emptied field follows the chosen tool again.
                TextField("For example, Personal or Work", text: Binding(get: { name }, set: { if $0 != name { name = $0; nameEdited = !$0.isEmpty } }))
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .name).accessibilityLabel("Profile name")
            }
            if kind == .codex {
                Picker("Application", selection: $separate) {
                    Text("Shared installation · recommended").tag(false)
                    Text("Separate installation").tag(true)
                }.pickerStyle(.radioGroup)
                Text(separate ? "Copies the ChatGPT app so you can update this profile independently. Uses more disk space. It does not create another account or subscription." : "Uses your existing ChatGPT installation. Your sign-in, chats and settings are still separate; only the app files and update schedule are shared.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Menu {
                        ForEach(model.installedApplications, id: \.path) { application in
                            Button { source = application } label: {
                                Label(application.lastPathComponent, systemImage: source == application || (source == nil && model.defaultApplication == application) ? "checkmark" : "app")
                            }
                        }
                        Divider()
                        Button("Browse Applications…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.canChooseDirectories = false
                            panel.begin { response in if response == .OK { source = panel.url } }
                        }
                    } label: {
                        Label((source ?? model.defaultApplication)?.lastPathComponent ?? "Choose App…", systemImage: "app")
                    }.accessibilityLabel("Choose App").fixedSize()
                    Spacer()
                }
            } else if kind == .claude {
                Picker("Account", selection: $separateClaude) {
                    Text("Existing Claude sign-in").tag(false).disabled(hasSharedClaude)
                    Text("Separate Claude account").tag(true)
                }.pickerStyle(.radioGroup)
                Text(separateClaude ? "Opens its own Claude window with a separate sign-in, chats and Claude Code settings. Both accounts can stay open at the same time. Sign in with the other account the first time it opens." : "Uses the Claude Desktop sign-in you already have.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if kind == .agent, let tool = selectedTool {
                if tool.supportsIsolatedProfiles {
                    Picker("Account", selection: $separateAgent) {
                        Text("Existing \(tool.name) sign-in").tag(false).disabled(!tool.launchesInTerminal && hasSharedAgent(tool))
                        Text("Separate \(tool.name) account").tag(true)
                    }.pickerStyle(.radioGroup)
                }
                Text(separateAgent && tool.supportsIsolatedProfiles ? tool.accountNotice : tool.sharedNotice)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if tool.launchesInTerminal { folderPicker }
            } else if kind.usesTerminal {
                folderPicker
                if kind == .terminal || !terminalWindows.isEmpty {
                    Picker("Tab", selection: $terminalSelection) {
                        Text(kind == .terminal ? "Choose a coding terminal" : "New Claude Code window when opened").tag("")
                        ForEach(terminalWindows) { window in Text(window.suggestionLabel).tag(window.id) }
                    }.disabled(terminalWindows.isEmpty)
                }
                if loadingWindows && terminalWindows.isEmpty { ProgressView().controlSize(.small) }
            }
        }
    }

    private var folderPicker: some View {
        LabeledContent("Project folder") {
            HStack {
                Text(model.displayPath(project?.path ?? model.home.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.begin { if $0 == .OK { project = panel.url; if kind == .claudeCode, !nameEdited, let url = panel.url { name = url.lastPathComponent } } }
                }.accessibilityLabel("Choose project folder")
            }
        }
    }

    private func create() {
        guard let choice else { return }
        creating = true; error = nil
        Task {
            do {
                if kind == .codex { try await model.createProfile(name: name, separateApp: separate, source: source) }
                else if kind == .agent, let toolID = choice.toolID { try model.createAgentProfile(toolID: toolID, name: name, project: project, separate: separateAgent) }
                else {
                    var window: TerminalWindow?
                    if kind.usesTerminal, !terminalSelection.isEmpty {
                        window = try await TerminalClient.shared.windows().first { $0.id == terminalSelection && $0.agent != nil }
                        guard window != nil else { throw CompanionError.message("That coding session has closed. Choose another tab.") }
                    }
                    if kind == .terminal, window == nil { throw CompanionError.message("Choose an open coding terminal first.") }
                    try model.createCompanion(kind: kind, name: name, project: project, window: window, separateAccount: separateClaude)
                }
                model.companions.refresh(); dismiss()
            }
            catch { self.error = error.localizedDescription }
            creating = false
        }
    }

    /// Why Create is unavailable, for its tooltip.
    private var createHint: String? {
        if choice == nil { return "Choose an app or coding tool first." }
        if ProfileLaunch.newProfile(name: name) == nil { return "Enter a name of 1 to 32 characters." }
        if kind == .terminal && terminalSelection.isEmpty { return "Choose an open coding terminal first." }
        return nil
    }
    private var hasSharedClaude: Bool { model.preferences.profiles.contains { $0.kind == .claude && !$0.usesSeparateClaudeAccount } }
    private func hasSharedAgent(_ tool: AgentTool) -> Bool {
        model.preferences.profiles.contains { $0.kind == .agent && $0.agentID == tool.id && !$0.usesIsolatedAgentHome }
    }
    private var choiceDescription: String {
        if let selectedTool {
            return selectedTool.launchesInTerminal
                ? "Opens \(selectedTool.name) in a new Terminal tab, in the project folder you choose."
                : "Adds \(selectedTool.name) to the strip. ProfileDock opens the app you already installed."
        }
        switch kind {
        case .codex: return "Create a separate Codex sign-in, history and settings."
        case .claude: return "Add Claude Desktop to the strip, with your existing sign-in or a separate account."
        case .terminal: return "Choose an open Terminal tab running a coding agent. It appears in the strip only while that session is open."
        case .claudeCode: return "Save a Claude Code project. It appears in the strip while Claude runs in its Terminal tab."
        case .agent: return ""
        }
    }
    private func refreshTerminals() async {
        guard kind.usesTerminal else { return }
        let requestedKind = kind
        loadingWindows = true
        defer { if requestedKind == kind { loadingWindows = false } }
        do {
            let windows = try await TerminalClient.shared.windows().filter { $0.agent != nil && (requestedKind != .claudeCode || $0.agent == .claude) }
            guard requestedKind == kind, !Task.isCancelled else { return }
            terminalWindows = windows
            if !windows.contains(where: { $0.id == terminalSelection }) { terminalSelection = "" }
            listError = windows.isEmpty && requestedKind == .terminal ? "No open coding terminals. Start a coding agent in Terminal; this list updates by itself." : nil
        } catch { if requestedKind == kind { listError = error.localizedDescription; terminalWindows = []; terminalSelection = "" } }
    }
}
