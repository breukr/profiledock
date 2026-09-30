import AppKit
import Combine
import DockCore

struct UsageEntry: Equatable {
    var snapshot: UsageSnapshot?
    var identity: String?
    var isRefreshing = false
    var validatingIdentity = true
    var error: UsageLoadError?
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var entries: [String: UsageEntry] = [:]
    var cardUsageRows: Int { max(1, entries.values.compactMap { $0.snapshot?.windows.count }.max() ?? 2) }
    @Published private(set) var now = Date()
    private let client: any UsageFetching
    private let claudeClient: any UsageFetching
    private let backgroundInterval: TimeInterval
    private var profiles: [Profile] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation: [String: UUID] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var visibleScreens: Set<String> = []
    private var timer: Timer?

    init(client: any UsageFetching = UsageClient(), claudeClient: any UsageFetching = ClaudeUsageClient(), backgroundInterval: TimeInterval = 300) {
        self.client = client; self.claudeClient = claudeClient; self.backgroundInterval = backgroundInterval
    }

    func configure(_ profiles: [Profile]) {
        self.profiles = profiles
        let ids = Set(profiles.map(\.id))
        for id in tasks.keys.filter({ !ids.contains($0) }) { tasks.removeValue(forKey: id)?.cancel(); generation[id] = nil }
        entries = entries.filter { ids.contains($0.key) }
        for profile in profiles where entries[profile.id] == nil { entries[profile.id] = UsageEntry(validatingIdentity: profile.kind == .codex || profile.usesClaudeAccountUsage) }
        scheduleRefresh()
    }

    func setVisible(_ visible: Bool, screen: String) {
        if visible { visibleScreens.insert(screen) } else { visibleScreens.remove(screen) }
        if visible { refreshAll() }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = nil
        if !profiles.isEmpty {
            let timer = Timer(timeInterval: visibleScreens.isEmpty ? backgroundInterval : 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.visibleScreens.isEmpty {
                        self.now = Date()
                        for profile in self.profiles where profile.usesClaudeAccountUsage { self.refresh(profile) }
                    } else { self.refreshAll() }
                }
            }
            timer.tolerance = min(5, backgroundInterval / 10)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func refreshAll(force: Bool = false) {
        now = Date()
        for profile in profiles { refresh(profile, force: force) }
    }

    func refresh(_ profile: Profile, force: Bool = false) {
        guard profile.kind == .codex || profile.usesClaudeAccountUsage, tasks[profile.id] == nil else { return }
        let client = profile.usesClaudeAccountUsage ? claudeClient : self.client
        let id = profile.id
        let token = UUID()
        generation[id] = token
        entries[id, default: UsageEntry()].validatingIdentity = true
        tasks[id] = Task { [weak self, client] in
            guard let self else { return }
            defer { if self.generation[id] == token { self.tasks[id] = nil } }
            do {
                let identity = try await client.identity(for: profile)
                guard self.generation[id] == token, !Task.isCancelled else { return }
                if self.entries[id]?.identity != identity {
                    self.entries[id]?.snapshot = nil
                    self.entries[id]?.error = nil
                    self.lastAttempt[id] = nil
                }
                self.entries[id]?.identity = identity
                self.entries[id]?.validatingIdentity = false
                let fresh = self.entries[id]?.snapshot.map { Date().timeIntervalSince($0.fetchedAt) < 60 } ?? false
                let recentAttempt = self.lastAttempt[id].map { Date().timeIntervalSince($0) < 15 } ?? false
                if !force && ((fresh && self.entries[id]?.error == nil) || recentAttempt) { return }
                self.lastAttempt[id] = Date()
                self.entries[id]?.isRefreshing = true
                let snapshot = try await client.fetch(profile, expectedIdentity: identity)
                guard self.generation[id] == token, !Task.isCancelled else { return }
                guard snapshot.identity == identity else { throw UsageLoadError.wrongAccount }
                self.entries[id] = UsageEntry(snapshot: snapshot, identity: identity, validatingIdentity: false)
                self.now = Date()
            } catch is CancellationError {
                if self.generation[id] == token { self.entries[id]?.isRefreshing = false }
            } catch {
                guard self.generation[id] == token, !Task.isCancelled else { return }
                let failure = error as? UsageLoadError ?? .network
                if failure.clearsSnapshot || self.entries[id]?.validatingIdentity == true { self.entries[id]?.snapshot = nil }
                self.entries[id]?.validatingIdentity = false
                self.entries[id]?.isRefreshing = false
                self.entries[id]?.error = failure
            }
        }
    }

    func claudeConnectionChanged() {
        for profile in profiles where profile.usesClaudeAccountUsage {
            tasks.removeValue(forKey: profile.id)?.cancel(); generation[profile.id] = nil
            entries[profile.id] = UsageEntry()
        }
        Task {
            await claudeClient.invalidate()
            for profile in profiles where profile.usesClaudeAccountUsage { refresh(profile, force: true) }
        }
    }

    func updateCompanions(model: DockModel) {
        now = Date()
        for profile in profiles where profile.kind != .codex && !profile.usesClaudeAccountUsage {
            let session = model.companions.sessions(for: profile).filter { $0.usageAt != nil }.max { ($0.usageAt ?? .distantPast) < ($1.usageAt ?? .distantPast) }
            let identity = "claude-session:" + (session?.id ?? profile.id)
            let value = UsageEntry(snapshot: session?.snapshot(identity: identity, now: now), identity: identity, validatingIdentity: false)
            if entries[profile.id] != value { entries[profile.id] = value }
        }
    }

    func shutdown() {
        timer?.invalidate(); timer = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); generation.removeAll()
    }

    var isRefreshing: Bool { entries.values.contains { $0.isRefreshing || $0.validatingIdentity } }
    var diagnostics: [[String: Any]] {
        profiles.map { profile in
            let entry = entries[profile.id]
            let snapshot = entry?.snapshot
            return ["profile": profile.id, "loading": entry?.isRefreshing ?? false,
                    "identityVerified": entry?.validatingIdentity == false,
                    "plan": snapshot?.plan as Any? ?? NSNull(),
                    "windows": snapshot?.windows.map { ["title": $0.title, "remainingPercent": $0.remainingPercent, "resetsAt": $0.resetsAt?.timeIntervalSince1970 as Any? ?? NSNull()] as [String: Any] } ?? [],
                    "bankedResets": snapshot?.bankedResets as Any? ?? NSNull(),
                    "resetExpiries": snapshot?.resetExpiries?.map(\.timeIntervalSince1970) as Any? ?? NSNull(),
                    "fetchedAt": snapshot?.fetchedAt.timeIntervalSince1970 as Any? ?? NSNull(),
                    "error": entry?.error?.message as Any? ?? NSNull()]
        }
    }
}
