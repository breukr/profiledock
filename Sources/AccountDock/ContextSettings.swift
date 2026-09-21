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
    private var requestID = UUID()
    private var readID = UUID()

    init(home: URL) {
        registry = ContextRegistry(home: home)
        refresh()
    }
    var caller: ContextProfile? { profiles.first { $0.id == callerID } }
    var allowed: [ContextProfile] { profiles.filter { access.allows(caller: callerID, source: $0.id) } }
    func refresh() {
        do {
            profiles = try registry.profiles(); access = try registry.access()
            if !profiles.contains(where: { $0.id == callerID }) { callerID = profiles.first?.id ?? "" }
            sources = Set(allowed.map(\.id)); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func selectCaller(_ id: String) {
        callerID = id; invalidate(); sources = Set(allowed.map(\.id)); status = nil; connected = false; connectionChecked = false
        checkConnection()
    }
    func setAllowed(_ source: ContextProfile, _ allowed: Bool) {
        do {
            // Reload before mutation so changes from another settings window are preserved.
            var latest = try registry.access(); latest.set(caller: callerID, source: source.id, allowed: allowed)
            try registry.save(latest); access = latest
            if allowed { sources.insert(source.id) } else { sources.remove(source.id) }
            invalidate(); error = nil
            if connected, let caller { try ContextMentions(registry: registry).synchronize(caller) }
        } catch { self.error = error.localizedDescription }
    }
    func invalidate() {
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
    func search() {
        guard !sources.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let service = ContextService(registry: registry, caller: callerID), query = self.query, sources = Array(self.sources).sorted()
        let since = days == 0 ? nil : Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let archived = includeArchived
        invalidate(); let id = requestID; searching = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try service.search(query: query, sources: sources, since: since, includeArchived: archived) }.value
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

struct ContextSettingsView: View {
    @ObservedObject var model: DockModel
    @StateObject private var store: ContextSettingsStore
    init(model: DockModel, initialCallerID: String? = nil) {
        self.model = model
        let store = ContextSettingsStore(home: model.home)
        if let initialCallerID, store.profiles.contains(where: { $0.id == initialCallerID }) { store.callerID = initialCallerID; store.sources = Set(store.allowed.map(\.id)) }
        _store = StateObject(wrappedValue: store)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose which profiles can tag each other.").font(.headline)
            Text("Select the profile you work in, then allow the profiles whose earlier conversations it may retrieve with @mentions. Covers local Work/Codex tasks; ChatGPT web and mobile history is not included.").foregroundStyle(.secondary)
            if store.profiles.isEmpty {
                ContentUnavailableView("Add a profile first", systemImage: "person.crop.rectangle.stack", description: Text("Your profiles will appear here when they are available in ProfileDock."))
            } else {
                Picker("Profile that can tag", selection: Binding(get: { store.callerID }, set: { store.selectCaller($0) })) {
                    ForEach(store.profiles) { Text($0.name).tag($0.id) }
                }.disabled(store.connecting)
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
                Divider()
                search
                if let error = store.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { store.refresh(); if model.home == FileManager.default.homeDirectoryForCurrentUser { store.checkConnection() } }
        .onChange(of: model.preferences.profiles) { _, _ in store.invalidate(); store.refresh(); store.checkConnection() }
        .onChange(of: store.query) { _, _ in store.invalidate() }
        .onChange(of: store.days) { _, _ in store.invalidate() }
        .onChange(of: store.includeArchived) { _, _ in store.invalidate() }
        .sheet(item: $store.selectedHit) { hit in conversation(hit) }
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try a search").font(.headline)
            Text("Preview the passages available to this profile. This preview stays on your Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Topic or words from a conversation", text: $store.query).textFieldStyle(.roundedBorder)
                    .onSubmit { if !store.searching { store.search() } }.accessibilityIdentifier("context-search-query")
                Button("Search") { store.search() }.disabled(store.searching || store.sources.isEmpty || store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !store.allowed.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { filters }
                    VStack(alignment: .leading) { filters }
                }
                ForEach(store.allowed) { profile in
                    Toggle(profile.name, isOn: Binding(get: { store.sources.contains(profile.id) }, set: { if $0 { store.sources.insert(profile.id) } else { store.sources.remove(profile.id) }; store.invalidate() })).toggleStyle(.checkbox)
                }
            }
            if store.searching { ProgressView("Searching local conversations…").controlSize(.small) }
            if let result = store.result {
                ForEach(result.coverage, id: \.profile.id) { coverage in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: coverage.status == "available" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(coverage.status == "available" ? .secondary : Color.orange)
                        Text("\(coverage.profile.name) · \(coverage.conversationsRead) \(coverage.conversationsRead == 1 ? "conversation" : "conversations") checked. \(coverage.detail)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if result.hits.isEmpty {
                    Text(result.coverage.contains(where: { $0.status != "available" }) ? "No matches in the available history. Some context could not be checked." : "No matches. Try a different word or a wider date range.").foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(result.hits) { hit in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hit.thread.title.isEmpty ? "Untitled conversation" : hit.thread.title).font(.headline).lineLimit(2)
                                Spacer()
                                Button("Read context") { store.read(hit) }.fixedSize()
                            }
                            Text("\(hit.profile.name) · \(Date(timeIntervalSince1970: hit.message.timestamp).formatted(date: .abbreviated, time: .shortened)) · \(hit.message.role == "user" ? "You" : "Assistant")" + (hit.thread.archived ? " · Archived" : "")).font(.caption).foregroundStyle(.secondary)
                            Text(hit.excerpt).font(.callout).lineLimit(7).textSelection(.enabled)
                            Button("Copy passage with source") { store.copy(hit.excerpt + "\n\nSource: " + hit.citation) }.buttonStyle(.link).font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if result.moreResults { Text("Showing the strongest matches. Use a more specific topic to narrow the results.").font(.caption).foregroundStyle(.secondary) }
            } else if store.allowed.isEmpty { Text("Enable a source profile above to try it.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var filters: some View {
        Picker("Period", selection: $store.days) { Text("All time").tag(0); Text("30 days").tag(30); Text("90 days").tag(90); Text("One year").tag(365) }.frame(maxWidth: 240)
        Toggle("Include archived", isOn: $store.includeArchived).toggleStyle(.checkbox)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(message.role == "user" ? "You" : "Assistant") · \(Date(timeIntervalSince1970: message.timestamp).formatted(date: .abbreviated, time: .shortened))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.text).font(.callout).textSelection(.enabled)
                            if message.truncated { Text("This long message was shortened.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(message.id == hit.message.id ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if store.reading { ProgressView("Reading context…").controlSize(.small) }
                    if !store.reading, store.conversation?.nextCursor != nil { Button("Read more") { store.read(hit, next: true) } }
                    if let error = store.readError { Text(error).foregroundStyle(.orange) }
                }
            }
            Text("Historical messages may be outdated. Assistant statements are not independent verification.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 590)
    }
}
