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
    @Published private(set) var reconnecting: Set<String> = []
    @Published private(set) var reconnectionMessages: [String: String] = [:]
    var onConnectionLost: ((Profile) -> Void)?
    /// Muted connections keep their tile and menu actions but never drop the strip down.
    @Published var mutedConnections: Set<String> = []
    @Published var remindersEnabled = true
    @Published private(set) var dismissedNotices: Set<String> = []
    private var nudgedConnections: Set<String> = []
    private var signInTasks: [String: Task<Void, Never>] = [:]
    private let signInRunner: any AccountSigningIn
    private let signInCommand: (Profile, URL) throws -> AccountSignInCommand
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

    init(client: any UsageFetching = UsageClient(), claudeClient: any UsageFetching = ClaudeUsageClient(), backgroundInterval: TimeInterval = 300, signInRunner: any AccountSigningIn = AccountSignInRunner(), signInCommand: @escaping (Profile, URL) throws -> AccountSignInCommand = { try AccountSignInCommand.make(profile: $0, home: $1) }) {
        self.client = client; self.claudeClient = claudeClient; self.backgroundInterval = backgroundInterval
        self.signInRunner = signInRunner
        self.signInCommand = signInCommand
    }

    func configure(_ profiles: [Profile]) {
        self.profiles = profiles
        let ids = Set(profiles.map(\.id))
        let connections = Set(profiles.map { connectionKey($0) })
        for key in signInTasks.keys.filter({ !connections.contains($0) }) { cancelReconnect(key: key) }
        nudgedConnections.formIntersection(connections)
        reconnectionMessages = reconnectionMessages.filter { connections.contains($0.key) }
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
                        for profile in self.profiles { self.refresh(profile) }
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
                self.nudgedConnections.remove(self.connectionKey(profile))
                self.reconnectionMessages[self.connectionKey(profile)] = nil
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
                let key = self.connectionKey(profile)
                if failure.needsSignIn && self.nudgedConnections.insert(key).inserted && self.remindersEnabled && !self.mutedConnections.contains(key) {
                    self.dismissedNotices.remove(key)
                    self.onConnectionLost?(profile)
                }
            }
        }
    }

    func connectionKey(_ profile: Profile) -> String { profile.usesClaudeAccountUsage ? "claude-account" : "codex:" + profile.id }
    func isReconnecting(_ profile: Profile) -> Bool { reconnecting.contains(connectionKey(profile)) }
    /// Accounts the strip's sign-in notice lists: disconnected, not muted and not set aside with Later.
    var signInNotices: [Profile] {
        guard remindersEnabled else { return [] }
        return disconnectedProfiles.filter { !mutedConnections.contains(connectionKey($0)) && !dismissedNotices.contains(connectionKey($0)) }
    }
    func dismissNotices() { dismissedNotices.formUnion(signInNotices.map(connectionKey)) }
    var disconnectedProfiles: [Profile] {
        var seen = Set<String>()
        return profiles.filter { entries[$0.id]?.error?.needsSignIn == true && seen.insert(connectionKey($0)).inserted }
    }

    func reconnect(_ profile: Profile, home: URL) {
        guard profiles.contains(where: { $0.id == profile.id }), entries[profile.id]?.error?.needsSignIn == true else { return }
        let key = connectionKey(profile)
        guard signInTasks[key] == nil, !reconnecting.contains(key) else { return }
        // Codex uses one local callback port. Keep profile login flows sequential.
        if !profile.usesClaudeAccountUsage && reconnecting.contains(where: { $0.hasPrefix("codex:") }) {
            reconnectionMessages[key] = "Finish the other Codex profile’s sign-in first."; return
        }
        let command: AccountSignInCommand
        do { command = try signInCommand(profile, home) }
        catch {
            reconnectionMessages[key] = (error as? AccountSignInError)?.message ?? AccountSignInError.failed.message
            return
        }
        reconnecting.insert(key)
        reconnectionMessages[key] = nil
        signInTasks[key] = Task { [weak self, signInRunner] in
            do {
                try await signInRunner.signIn(command)
                guard let self, !Task.isCancelled, self.reconnecting.contains(key) else { return }
                self.reconnecting.remove(key); self.signInTasks[key] = nil
                await (profile.usesClaudeAccountUsage ? self.claudeClient : self.client).invalidate()
                guard !Task.isCancelled else { return }
                // Refresh all Claude tiles sharing the account, or only this Codex profile.
                for current in self.profiles where self.connectionKey(current) == key {
                    self.tasks.removeValue(forKey: current.id)?.cancel(); self.generation[current.id] = nil
                    self.entries[current.id] = UsageEntry()
                    self.refresh(current, force: true)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reconnecting.remove(key); self.signInTasks[key] = nil
                self.reconnectionMessages[key] = (error as? AccountSignInError)?.message ?? AccountSignInError.failed.message
            }
        }
    }

    func cancelReconnect(_ profile: Profile) { cancelReconnect(key: connectionKey(profile)) }
    private func cancelReconnect(key: String) {
        signInTasks.removeValue(forKey: key)?.cancel()
        reconnecting.remove(key); reconnectionMessages[key] = nil
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
        signInTasks.values.forEach { $0.cancel() }; signInTasks.removeAll(); reconnecting.removeAll()
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
                    "error": entry?.error?.message as Any? ?? NSNull(),
                    "needsSignIn": entry?.error?.needsSignIn ?? false,
                    "reconnecting": isReconnecting(profile)]
        }
    }
}
