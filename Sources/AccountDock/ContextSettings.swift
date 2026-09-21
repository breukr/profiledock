import AppKit
import SwiftUI
import ContextCore

@MainActor final class ContextSettingsStore: ObservableObject {
    let registry: ContextRegistry
    @Published var profiles: [ContextProfile] = []
    @Published var access = ContextAccess()
    @Published var callerID = ""
    @Published var sources = Set<String>()
    @Published var query = ""
    @Published var matchMode: ContextSearchMode = .allWords
    @Published var newestFirst = false
    @Published var days = 0
    @Published var includeArchived = true
    @Published var searching = false
    @Published var connecting = false
    @Published var connected = false
    @Published var connectionChecked = false
    @Published var status: String?
    @Published var error: String?
    @Published var result: ContextSearchResult?
    @Published var selectedHit: ContextHit?
    @Published var conversation: ContextSessionResult?
    @Published var messages: [ContextMessage] = []
    @Published var readError: String?
    @Published var reading = false
    private var initialized = false
    private var searchWork: Task<ContextSearchResult, Error>?
    private var requestID = UUID()
    private var readID = UUID()

    init(home: URL) {
        registry = ContextRegistry(home: home)
        refresh()
    }
    var caller: ContextProfile? { profiles.first { $0.id == callerID } }
    var allowed: [ContextProfile] { profiles.filter { access.allows(caller: callerID, source: $0.id) } }
    var searchable: [ContextProfile] { profiles.filter { $0.id == callerID } + allowed.filter { $0.id != callerID } }
    func refresh() {
        do {
            profiles = try registry.profiles()
            let latestAccess = try registry.access()
            if initialized, latestAccess != access { invalidate() }
            access = latestAccess
            let changed = !profiles.contains(where: { $0.id == callerID })
            if changed { callerID = profiles.first?.id ?? "" }
            let available = Set(searchable.map(\.id))
            sources = !initialized || changed ? Set(searchable.prefix(8).map(\.id)) : sources.intersection(available)
            initialized = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func selectCaller(_ id: String, check: Bool = true) {
        callerID = id; invalidate(); sources = Set(searchable.prefix(8).map(\.id)); status = nil; connected = false; connectionChecked = false
        if check { checkConnection() }
    }
    func setAllowed(_ source: ContextProfile, _ allowed: Bool) {
        do {
            // Reload before mutation so changes from another settings window are preserved.
            var latest = try registry.access(); latest.set(caller: callerID, source: source.id, allowed: allowed)
            try registry.save(latest); access = latest
            if allowed, sources.count < 8 { sources.insert(source.id) } else if !allowed { sources.remove(source.id) }
            invalidate(); error = nil
            if connected, let caller { try ContextMentions(registry: registry).synchronize(caller) }
        } catch { self.error = error.localizedDescription }
    }
    func invalidate() {
        searchWork?.cancel(); searchWork = nil
        requestID = UUID(); readID = UUID(); result = nil; searching = false; reading = false
        selectedHit = nil; conversation = nil; messages = []; readError = nil
    }
    private func codexURL() throws -> URL {
        // Use the binary shipped with an installed OpenAI app, without a shell or PATH lookup.
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ContextError.message("Install the ChatGPT desktop app or Codex CLI to connect this profile.") }
        return URL(fileURLWithPath: path)
    }
    func checkConnection() {
        guard let caller, !connecting else { return }
        do {
            let connection = ContextConnection(registry: registry, codex: try codexURL())
            let callerID = self.callerID
            Task {
                do {
                    let connected = try await Task.detached(priority: .utility) {
                        let connected = try connection.isConnected(caller)
                        if connected { try ContextMentions(registry: connection.registry).synchronize(caller) }
                        return connected
                    }.value
                    guard self.callerID == callerID else { return }
                    self.connected = connected; self.connectionChecked = true
                } catch {
                    guard self.callerID == callerID else { return }
                    self.connectionChecked = true; self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func connect() {
        guard let caller else { return }
        do {
            let connection = ContextConnection(registry: registry, codex: try codexURL())
            guard let executable = Bundle.main.executableURL, let resources = Bundle.main.resourceURL else { throw ContextError.message("Open the packaged ProfileDock app to connect a profile.") }
            let helper = executable.deletingLastPathComponent().appendingPathComponent("ProfileDockContext")
            let skill = try String(contentsOf: resources.appendingPathComponent("ContextPlugin/skills/profiledock-context/SKILL.md"), encoding: .utf8)
            connecting = true; error = nil
            Task {
                defer { connecting = false }
                do {
                    try await Task.detached(priority: .utility) { try connection.connect(caller, helper: helper, skill: skill) }.value
                    connected = true; connectionChecked = true
                    status = "Connected. In a new task in \(caller.name), type @ and choose a profile mention."
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        guard let caller else { return }
        do {
            let connection = ContextConnection(registry: registry, codex: try codexURL())
            connecting = true; invalidate(); error = nil
            Task {
                defer { connecting = false }
                do {
                    try await Task.detached(priority: .utility) { try connection.disconnect(caller) }.value
                    refresh()
                    connected = false; status = "Disconnected. Context sharing for this profile is off."
                } catch { let message = error.localizedDescription; refresh(); self.error = message }
            }
        } catch { self.error = error.localizedDescription }
    }
    func search(limit: Int = 12) {
        guard !sources.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let service = ContextService(registry: registry, caller: callerID), query = self.query, sources = Array(self.sources).sorted()
        let since = days == 0 ? nil : Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let archived = includeArchived, mode = matchMode
        invalidate(); let id = requestID; searching = true; error = nil
        let work = Task.detached(priority: .userInitiated) { try service.search(query: query, sources: sources, since: since, includeArchived: archived, limit: limit, mode: mode) }
        searchWork = work
        Task {
            do {
                let result = try await work.value
                guard id == requestID else { return }
                self.result = result; searching = false
            } catch { guard id == requestID else { return }; searching = false; self.error = error.localizedDescription }
        }
    }
    func read(_ hit: ContextHit, next: Bool = false) {
        selectedHit = hit
        let service = ContextService(registry: registry, caller: callerID)
        let cursor = next ? conversation?.nextCursor : nil
        let id = UUID(); readID = id; reading = true; readError = nil
        if !next { messages = []; conversation = nil }
        Task {
            do {
                let page = try await Task.detached(priority: .userInitiated) { try service.read(source: hit.profile.id, threadID: hit.thread.id, cursor: cursor, messageID: next ? nil : hit.message.id) }.value
                guard id == readID else { return }
                conversation = page; messages += page.messages; reading = false
            } catch { guard id == readID else { return }; reading = false; self.readError = error.localizedDescription }
        }
    }
    var example: String { "Check our earlier conversations about [topic] in " + allowed.map(\.alias).prefix(3).joined(separator: " and ") + "." }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

enum ContextViewMode { case access, search }

struct ContextSettingsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject private var store: ContextSettingsStore
    let mode: ContextViewMode
    let initialCallerID: String?
    let manageAccess: () -> Void
    @FocusState private var queryFocused: Bool

    init(model: DockModel, mode: ContextViewMode = .access, initialCallerID: String? = nil, manageAccess: @escaping () -> Void = {}) {
        self.model = model; self.mode = mode; self.initialCallerID = initialCallerID
        self.manageAccess = manageAccess; self.store = model.contextSettings
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if mode == .access {
                Text("Choose which profiles can tag each other.").font(.headline)
                Text("Permissions go in one direction. Pick the profile doing the asking, then choose whose earlier tasks it can retrieve.").foregroundStyle(.secondary)
            } else {
                Text("Find a conversation without switching accounts.").font(.headline)
                Text("Search your own profile and sources it may access. Local Work/Codex history only; web and mobile chats are not included.").foregroundStyle(.secondary)
            }
            if store.profiles.isEmpty {
                ContentUnavailableView("Add a profile first", systemImage: "person.crop.rectangle.stack", description: Text("Your profiles will appear here when they are available in ProfileDock."))
            } else {
                HStack {
                    Picker(mode == .access ? "Profile that can tag" : "Search as", selection: Binding(get: { store.callerID }, set: { store.selectCaller($0, check: mode == .access) })) {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }.disabled(store.connecting).frame(maxWidth: 360)
                    Spacer()
                    if mode == .search { Button("Manage access…", action: manageAccess) }
                }
                if mode == .access { accessControls } else { search }
                if let error = store.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            store.refresh()
            if let initialCallerID, initialCallerID != store.callerID { store.selectCaller(initialCallerID, check: mode == .access) }
            if mode == .access, model.home == FileManager.default.homeDirectoryForCurrentUser { store.checkConnection() }
        }
        .onChange(of: model.preferences.profiles) { _, _ in store.invalidate(); store.refresh() }
        .onChange(of: store.query) { _, _ in store.invalidate() }
        .onChange(of: store.days) { _, _ in store.invalidate() }
        .onChange(of: store.includeArchived) { _, _ in store.invalidate() }
        .onChange(of: store.matchMode) { _, _ in store.invalidate() }
        .sheet(item: $store.selectedHit) { hit in conversation(hit) }
    }
    private var accessControls: some View {
        VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(store.caller?.name ?? "This profile") can tag").font(.headline)
                        ForEach(store.profiles.filter { $0.id != store.callerID }) { profile in
                            Toggle(isOn: Binding(get: { store.access.allows(caller: store.callerID, source: profile.id) }, set: { store.setAllowed(profile, $0) })) {
                                HStack { Text(profile.name); Spacer(); Text(profile.alias).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }.toggleStyle(.switch).accessibilityLabel("\(store.caller?.name ?? "This profile") can tag \(profile.name)")
                        }
                        if store.profiles.count == 1 { Text("Add another profile to share conversation context.").foregroundStyle(.secondary) }
                        Text("Access goes in one direction. Allowing Work to tag Personal does not allow Personal to tag Work. Only enable the directions you want. Search stays local; excerpts used in a task become context in that task's account.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(10)
                }.disabled(store.connecting)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Use in \(store.caller?.name ?? "this profile")").font(.headline)
                                Text(store.connected ? "Connected · available in new tasks" : "Connect once to ask for context in your tasks.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if store.connecting { ProgressView().controlSize(.small) }
                            else if store.connected {
                                Menu("Connected") {
                                    Button("Refresh connection") { store.connect() }
                                    Button("Disconnect & turn off sharing", role: .destructive) { store.disconnect() }
                                }.fixedSize()
                            } else { Button("Connect") { store.connect() }.buttonStyle(.borderedProminent) }
                        }
                        if !store.allowed.isEmpty {
                            Text(store.example).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Button("Copy example") { store.copy(store.example) }.buttonStyle(.link)
                        }
                        Text("Type @ in your chat and select a profile from the skills suggestions. You can also write its name in your message. If new mentions do not appear, start a new task or restart that profile when its work is finished.").font(.caption).foregroundStyle(.secondary)
                        if let status = store.status { Text(status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("context-connection-status") }
                    }.padding(10)
                }

        }
    }

    private var conversations: [ContextHit] {
        let hits = store.result?.hits ?? []
        let groups = Dictionary(grouping: hits) { $0.profile.id + ":" + $0.thread.id }
        return groups.values.compactMap { $0.first }.sorted {
            if store.newestFirst, $0.message.timestamp != $1.message.timestamp { return $0.message.timestamp > $1.message.timestamp }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("Search a topic, title, or exact phrase…", text: $store.query).textFieldStyle(.roundedBorder)
                            .focused($queryFocused).onSubmit { store.search() }.accessibilityIdentifier("context-search-query")
                        Button("Search") { store.search() }.buttonStyle(.borderedProminent)
                            .disabled(store.searching || store.sources.isEmpty || store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !store.query.isEmpty { Button("Clear") { store.query = ""; store.invalidate(); queryFocused = true } }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { filters }
                        VStack(alignment: .leading, spacing: 12) { filters }
                    }
                    DisclosureGroup("Search in \(store.sources.count) \(store.sources.count == 1 ? "profile" : "profiles")") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.searchable) { profile in
                                Toggle(profile.name + (profile.id == store.callerID ? " · your own profile" : ""), isOn: Binding(get: { store.sources.contains(profile.id) }, set: { if $0 { store.sources.insert(profile.id) } else { store.sources.remove(profile.id) }; store.invalidate() }))
                                    .toggleStyle(.checkbox).disabled(!store.sources.contains(profile.id) && store.sources.count >= 8)
                            }
                            HStack {
                                Button("Select all") { store.sources = Set(store.searchable.prefix(8).map(\.id)); store.invalidate() }
                                Button("Clear selection") { store.sources = []; store.invalidate() }
                            }.buttonStyle(.link)
                            if store.searchable.count > 8 { Text("Choose up to eight profiles per search.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.top, 10)
                    }
                    Text("All words searches titles and messages together. Use Any word for a broader search, or put a phrase in quotation marks for an exact match.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            if store.searching {
                HStack { ProgressView("Searching local history…").controlSize(.small); Spacer(); Button("Cancel") { store.invalidate() } }
            } else if let result = store.result {
                HStack {
                    Text("\(conversations.count) \(conversations.count == 1 ? "conversation" : "conversations") found").font(.headline)
                    Spacer()
                    Picker("Sort", selection: $store.newestFirst) { Text("Best match").tag(false); Text("Newest match").tag(true) }.frame(width: 210)
                }
                coverage(result)
                if result.hits.isEmpty {
                    ContentUnavailableView("No matching conversations", systemImage: "magnifyingglass", description: Text("Try fewer words, Any word, a wider date range, or another allowed profile. Some history may be unavailable; see search coverage above."))
                }
                ForEach(conversations) { hit in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.thread.title.isEmpty ? "Untitled conversation" : hit.thread.title).font(.headline).lineLimit(2)
                                    Text("\(hit.profile.name) · \(Date(timeIntervalSince1970: hit.message.timestamp).formatted(date: .abbreviated, time: .omitted))" + (hit.thread.archived ? " · Archived" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Button("Read conversation") { store.read(hit) }.fixedSize()
                            }
                            Text(highlighted(hit.excerpt)).font(.callout).lineLimit(6).textSelection(.enabled)
                            HStack {
                                Text(hit.message.role == "user" ? "Your message" : "Assistant reply").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy with source") { store.copy(hit.excerpt + "\n\nSource: " + hit.citation) }.buttonStyle(.link).font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if result.moreResults {
                    if result.hits.count < 30 { Button("Show more matches") { store.search(limit: 30) } }
                    else { Text("More matches exist. Narrow the query or date range to find a specific conversation.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if store.sources.isEmpty {
                ContentUnavailableView("Choose a profile to search", systemImage: "person.crop.circle", description: Text("Expand Search in profiles above and select your own profile or an allowed source."))
            } else {
                ContentUnavailableView("What are you looking for?", systemImage: "text.magnifyingglass", description: Text("Try a project name, a decision, or words you remember. Results show the original profile, conversation and date."))
            }
        }
    }
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for term in ContextQuery(store.query, mode: store.matchMode).terms {
            var remaining = text.startIndex..<text.endIndex
            while let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let start = AttributedString.Index(match.lowerBound, within: result), let end = AttributedString.Index(match.upperBound, within: result) {
                    result[start..<end].foregroundColor = .accentColor
                    result[start..<end].font = .system(.callout, weight: .semibold)
                }
                remaining = match.upperBound..<text.endIndex
            }
        }
        return result
    }
    private func coverage(_ result: ContextSearchResult) -> some View {
        let incomplete = result.coverage.contains { $0.status != "available" }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.coverage, id: \.profile.id) { item in
                    Text("\(item.profile.name): \(item.conversationsRead) conversations checked. \(item.detail)").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
        } label: {
            Label(incomplete ? "Some history could not be searched · view coverage" : "Searched \(result.coverage.reduce(0) { $0 + $1.conversationsRead }) local conversations · view coverage", systemImage: incomplete ? "exclamationmark.circle" : "checkmark.circle")
                .font(.caption).foregroundStyle(incomplete ? Color.orange : Color.secondary)
        }
    }
    @ViewBuilder private var filters: some View {
        Picker("Match", selection: $store.matchMode) { ForEach(ContextSearchMode.allCases, id: \.self) { Text($0.label).tag($0) } }
        Picker("Period", selection: $store.days) { Text("All time").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("One year").tag(365) }
        Toggle("Archived", isOn: $store.includeArchived).toggleStyle(.checkbox)
    }
    private func conversation(_ hit: ContextHit) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.thread.title).font(.title2.weight(.semibold)).lineLimit(3)
                    Text("\(hit.profile.name) · Local conversation").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(); Button("Done") { store.selectedHit = nil }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(message.role == "user" ? "You" : "Assistant") · \(Date(timeIntervalSince1970: message.timestamp).formatted(date: .abbreviated, time: .shortened))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(highlighted(message.text)).font(.callout).textSelection(.enabled)
                            if message.truncated { Text("This long message was shortened.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(message.id == hit.message.id ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)).id(message.id)
                    }
                    if store.reading { ProgressView("Reading context…").controlSize(.small) }
                    if !store.reading, store.conversation?.nextCursor != nil { Button("Read more") { store.read(hit, next: true) } }
                    if let error = store.readError { Text(error).foregroundStyle(.orange) }
                }
            }
            .onChange(of: store.messages.count) { old, _ in
                if old == 0 { reader.scrollTo(hit.message.id, anchor: .center) }
            }
            }
            Text("Historical messages may be outdated. Assistant statements are not independent verification.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 590)
    }
}
