import AppKit
import Combine
import Network
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
    /// Connections set aside with "Later": hidden until their next successful reading or for 24 hours, across relaunches.
    @Published private(set) var dismissedNotices: Set<String> = []
    /// Last reading per tile and reminder timestamps per connection, on disk. Nil keeps everything in memory (tests, previews).
    private var cache: UsageReadingCache?
    private var reminders: [String: UsageReadingCache.Reminder] = [:]
    private let clock: () -> Date
    /// No sign-in reminder during a tile's first refresh cycles after launch: tokens are often renewed moments later.
    private let launchGraceCycles: Int
    /// Quiet period after the Mac wakes: network errors stay silent and no reminder appears.
    private let wakeGrace: TimeInterval
    private let wakeSettle: TimeInterval
    private let waitForNetwork: @Sendable (TimeInterval) async -> Void
    private static let reminderInterval: TimeInterval = 86400
    private var finishedCycles: [String: Int] = [:]
    private var wokeAt: Date?
    private var wakeTask: Task<Void, Never>?
    private var wakeRetries: [String: Int] = [:]
    private var signInTasks: [String: Task<Void, Never>] = [:]
    private let signInRunner: any AccountSigningIn
    private let signInCommand: (Profile, URL) throws -> AccountSignInCommand
    /// Status-line limits for separate Claude accounts, shown only while their account endpoint has no reading.
    @Published private(set) var statusLineReadings: [String: UsageSnapshot] = [:]
    var cardUsageRows: Int { max(1, (entries.values.compactMap { $0.snapshot?.windows.count } + statusLineReadings.values.map(\.windows.count)).max() ?? 2) }
    @Published private(set) var now = Date()
    private let client: any UsageFetching
    private let claudeClient: any UsageFetching
    /// One account client per separate CLAUDE_CONFIG_DIR, so requests, caches and rate limits never mix accounts.
    private let makeClaudeAccountClient: (String) -> any UsageFetching
    private var claudeAccountClients: [String: any UsageFetching] = [:]
    private let home: URL
    private let backgroundInterval: TimeInterval
    private var profiles: [Profile] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation: [String: UUID] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var visibleScreens: Set<String> = []
    private var timer: Timer?

    init(client: any UsageFetching = UsageClient(), claudeClient: any UsageFetching = ClaudeUsageClient(expectedAccount: ClaudeUsageClient.desktopAccount), claudeAccountClient: @escaping (String) -> any UsageFetching = { ClaudeUsageClient(configDirectory: $0, expectedAccount: ClaudeUsageClient.desktopAccount) }, backgroundInterval: TimeInterval = 300, signInRunner: any AccountSigningIn = AccountSignInRunner(), signInCommand: @escaping (Profile, URL) throws -> AccountSignInCommand = { try AccountSignInCommand.make(profile: $0, home: $1) }, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         cache: UsageReadingCache? = nil, clock: @escaping () -> Date = Date.init, launchGraceCycles: Int = 2, wakeGrace: TimeInterval = 60, wakeSettle: TimeInterval = 5, waitForNetwork: @escaping @Sendable (TimeInterval) async -> Void = UsageStore.waitForNetwork) {
        self.client = client; self.claudeClient = claudeClient; self.makeClaudeAccountClient = claudeAccountClient; self.backgroundInterval = backgroundInterval
        self.home = home
        self.signInRunner = signInRunner
        self.signInCommand = signInCommand
        self.clock = clock; self.launchGraceCycles = launchGraceCycles; self.wakeGrace = wakeGrace; self.wakeSettle = wakeSettle; self.waitForNetwork = waitForNetwork
        if let cache { useReadingCache(cache) }
    }

    /// Attach the on-disk cache before the first `configure`, so tiles start with their last reading and its age.
    func useReadingCache(_ cache: UsageReadingCache) {
        self.cache = cache
        reminders = Dictionary(uniqueKeysWithValues: cache.reminderKeys.map { ($0, cache.reminder(for: $0)) })
        pruneSnoozes()
    }

    func configure(_ profiles: [Profile]) {
        self.profiles = profiles
        let ids = Set(profiles.map(\.id))
        let connections = Set(profiles.map { connectionKey($0) })
        for key in signInTasks.keys.filter({ !connections.contains($0) }) { cancelReconnect(key: key) }
        reconnectionMessages = reconnectionMessages.filter { connections.contains($0.key) }
        for id in tasks.keys.filter({ !ids.contains($0) }) { tasks.removeValue(forKey: id)?.cancel(); generation[id] = nil }
        entries = entries.filter { ids.contains($0.key) }
        statusLineReadings = statusLineReadings.filter { ids.contains($0.key) }
        let configs = Set(profiles.compactMap(claudeConfigPath))
        claudeAccountClients = claudeAccountClients.filter { configs.contains($0.key) }
        for profile in profiles where entries[profile.id] == nil {
            var entry = UsageEntry(validatingIdentity: profile.kind == .codex || profile.usesClaudeAccountUsage)
            // A cached reading shows at once with its age; the first refresh confirms the account or clears it.
            if usesAccountEndpoint(profile), let cached = cache?.reading(for: readingKey(profile)) {
                entry.snapshot = cached.snapshot; entry.identity = cached.identity; entry.validatingIdentity = false
                let client = usageClient(for: profile)
                Task { await client.remember(identity: cached.identity) }
            }
            entries[profile.id] = entry
        }
        if let cache {
            cache.retain(readings: Set(profiles.filter(usesAccountEndpoint).map(readingKey)), reminders: connections)
            reminders = reminders.filter { connections.contains($0.key) }
        }
        scheduleRefresh()
    }

    private func usesAccountEndpoint(_ profile: Profile) -> Bool {
        (profile.kind == .codex || profile.usesClaudeAccountUsage) && GrokBotUsage.dataDirectory(for: profile, home: home) == nil
    }
    /// Cache key: the tile within its connection, so a shared Claude sign-in still verifies each tile's own account.
    private func readingKey(_ profile: Profile) -> String { connectionKey(profile) + "|" + profile.id }

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
        pruneSnoozes()
        for profile in profiles { refresh(profile, force: force) }
    }

    /// After sleep the network needs a moment: wait for a usable connection (at most 30 s) plus a short settle,
    /// then refresh. Errors in the first minute after wake stay silent and retry with a short backoff.
    func handleWake() {
        wokeAt = clock(); wakeRetries = [:]
        wakeTask?.cancel()
        wakeTask = Task { [weak self, waitForNetwork, wakeSettle] in
            await waitForNetwork(30)
            try? await Task.sleep(for: .seconds(wakeSettle))
            guard !Task.isCancelled else { return }
            self?.refreshAll()
        }
    }

    private var inWakeGrace: Bool { wokeAt.map { clock().timeIntervalSince($0) < wakeGrace } ?? false }

    private func retryAfterWake(_ profile: Profile) {
        let attempt = wakeRetries[profile.id, default: 0]
        guard attempt < 3 else { return }
        wakeRetries[profile.id] = attempt + 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5 * pow(2, Double(attempt))))
            guard let self, self.profiles.contains(where: { $0.id == profile.id }) else { return }
            self.refresh(profile, force: true)
        }
    }

    /// Resolves once the system reports a usable network path, or after `limit` seconds.
    nonisolated static let waitForNetwork: @Sendable (TimeInterval) async -> Void = { limit in
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let monitor = NWPathMonitor(), once = ResumeOnce()
            let finish = { if once.claim() { monitor.cancel(); continuation.resume() } }
            monitor.pathUpdateHandler = { if $0.status == .satisfied { finish() } }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { finish() }
        }
    }

    func refresh(_ profile: Profile, force: Bool = false) {
        if let folder = GrokBotUsage.dataDirectory(for: profile, home: home) { refreshGrokBot(profile, folder: folder); return }
        guard profile.kind == .codex || profile.usesClaudeAccountUsage, tasks[profile.id] == nil else { return }
        let client = usageClient(for: profile)
        let id = profile.id
        let token = UUID()
        generation[id] = token
        // A tile that already shows a reading keeps it steady while the account is re-checked.
        if entries[id]?.snapshot == nil { entries[id, default: UsageEntry()].validatingIdentity = true }
        tasks[id] = Task { [weak self, client] in
            guard let self else { return }
            defer { if self.generation[id] == token { self.tasks[id] = nil } }
            do {
                let identity = try await client.identity(for: profile)
                guard self.generation[id] == token, !Task.isCancelled else { return }
                if self.entries[id]?.identity != identity {
                    // Another account: the only case that discards a reading, on screen and on disk.
                    if self.entries[id]?.snapshot != nil { self.cache?.removeReading(for: self.readingKey(profile)) }
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
                self.finishedCycles[id, default: 0] += 1
                let key = self.connectionKey(profile)
                self.cache?.store(snapshot, for: self.readingKey(profile))
                self.wakeRetries[id] = nil
                self.reconnectionMessages[key] = nil
                // A good reading ends "Later": a future sign-in problem is new and may be shown again.
                if self.reminders[key]?.snoozedUntil != nil { self.updateReminder(key) { $0.snoozedUntil = nil } }
                self.dismissedNotices.remove(key)
                self.now = Date()
            } catch is CancellationError {
                if self.generation[id] == token { self.entries[id]?.isRefreshing = false }
            } catch {
                guard self.generation[id] == token, !Task.isCancelled else { return }
                let failure = error as? UsageLoadError ?? .network
                let key = self.connectionKey(profile)
                self.finishedCycles[id, default: 0] += 1
                self.entries[id]?.validatingIdentity = false
                self.entries[id]?.isRefreshing = false
                // Right after wake the network is often not back yet: no error, just a quiet retry.
                if failure == .network && self.inWakeGrace { self.retryAfterWake(profile); return }
                if failure.clearsSnapshot {
                    if self.entries[id]?.snapshot != nil { self.cache?.removeReading(for: self.readingKey(profile)) }
                    self.entries[id]?.snapshot = nil
                }
                self.entries[id]?.error = failure
                if failure.needsSignIn && self.mayRemind(profile) {
                    self.updateReminder(key) { $0.lastNudgedAt = self.clock() }
                    self.onConnectionLost?(profile)
                }
            }
        }
    }

    /// Grok Bot keeps its own weekly reading on disk. Two small local reads, so this runs inline; no network, no sign-in.
    private func refreshGrokBot(_ profile: Profile, folder: URL) {
        let snapshot = GrokBotUsage.snapshot(in: folder)
        let value = UsageEntry(snapshot: snapshot, identity: snapshot?.identity, validatingIdentity: false)
        if entries[profile.id] != value { entries[profile.id] = value }
    }

    /// The exact CLAUDE_CONFIG_DIR ProfileDock launches a separate account with; nil for the shared sign-in.
    func claudeConfigPath(_ profile: Profile) -> String? { profile.claudeConfigPath(in: home) }
    private func usageClient(for profile: Profile) -> any UsageFetching {
        guard profile.usesClaudeAccountUsage else { return client }
        guard let config = claudeConfigPath(profile) else { return claudeClient }
        if let existing = claudeAccountClients[config] { return existing }
        let created = makeClaudeAccountClient(config)
        claudeAccountClients[config] = created
        return created
    }

    /// Shared Claude tiles have one connection; each separate account has its own, keyed like its Keychain item.
    func connectionKey(_ profile: Profile) -> String {
        guard profile.usesClaudeAccountUsage else { return "codex:" + profile.id }
        guard let config = claudeConfigPath(profile) else { return "claude-account" }
        return "claude-account:" + ClaudeCredentialService.name(configDirectory: config).suffix(8)
    }
    func isReconnecting(_ profile: Profile) -> Bool { reconnecting.contains(connectionKey(profile)) }
    /// Accounts the strip's sign-in notice lists: disconnected, not muted, not set aside with Later, and past the
    /// quiet periods after launch and wake.
    var signInNotices: [Profile] {
        guard remindersEnabled, !inWakeGrace else { return [] }
        return disconnectedProfiles.filter { !mutedConnections.contains(connectionKey($0)) && !dismissedNotices.contains(connectionKey($0)) && pastLaunchGrace($0) }
    }
    /// "Later": hides the listed accounts until their next good reading or for 24 hours, remembered across relaunches.
    func dismissNotices() {
        let until = clock().addingTimeInterval(Self.reminderInterval)
        for key in Set(signInNotices.map(connectionKey)) { updateReminder(key) { $0.snoozedUntil = until } }
        dismissedNotices.formUnion(signInNotices.map(connectionKey))
    }

    private func pastLaunchGrace(_ profile: Profile) -> Bool { finishedCycles[profile.id, default: 0] > launchGraceCycles }
    /// A pop-down reminder at most once per 24 hours per account, never in the quiet periods, never while snoozed.
    private func mayRemind(_ profile: Profile) -> Bool {
        let key = connectionKey(profile), state = reminders[key] ?? .init(), now = clock()
        guard remindersEnabled, !mutedConnections.contains(key), pastLaunchGrace(profile), !inWakeGrace,
              (state.snoozedUntil ?? .distantPast) <= now else { return false }
        return state.lastNudgedAt.map { now.timeIntervalSince($0) >= Self.reminderInterval } ?? true
    }
    private func updateReminder(_ key: String, _ change: (inout UsageReadingCache.Reminder) -> Void) {
        var value = reminders[key] ?? .init()
        change(&value)
        reminders[key] = value
        cache?.setReminder(value, for: key)
    }
    private func pruneSnoozes() {
        let now = clock()
        let snoozed = Set(reminders.compactMap { key, value in (value.snoozedUntil ?? .distantPast) > now ? key : nil })
        if dismissedNotices != snoozed { dismissedNotices = snoozed }
    }
    var disconnectedProfiles: [Profile] {
        var seen = Set<String>()
        return profiles.filter { entries[$0.id]?.error?.needsSignIn == true && seen.insert(connectionKey($0)).inserted }
    }

    func reconnect(_ profile: Profile, home: URL) {
        guard profiles.contains(where: { $0.id == profile.id }), entries[profile.id]?.error?.offersReconnect == true else { return }
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
                await self.usageClient(for: profile).invalidate()
                guard !Task.isCancelled else { return }
                // Refresh all Claude tiles sharing the account, or only this separate account or Codex profile.
                for current in self.profiles where self.connectionKey(current) == key {
                    self.tasks.removeValue(forKey: current.id)?.cancel(); self.generation[current.id] = nil
                    self.keepReading(current.id)
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

    /// A saved-resets connection changed for one account: nil is the shared sign-in, otherwise a separate CLAUDE_CONFIG_DIR.
    func claudeConnectionChanged(configDirectory: String?) {
        let affected = profiles.filter { $0.usesClaudeAccountUsage && claudeConfigPath($0) == configDirectory }
        guard let first = affected.first else { return }
        for profile in affected {
            tasks.removeValue(forKey: profile.id)?.cancel(); generation[profile.id] = nil
            keepReading(profile.id)
        }
        let client = usageClient(for: first)
        Task {
            await client.invalidate()
            for profile in affected { refresh(profile, force: true) }
        }
    }

    /// Restart a tile's checks without dropping its reading; only a different account identity clears it.
    private func keepReading(_ id: String) {
        let old = entries[id]
        entries[id] = UsageEntry(snapshot: old?.snapshot, identity: old?.identity, validatingIdentity: old?.snapshot == nil)
    }

    func updateCompanions(model: DockModel) {
        now = Date()
        for profile in profiles where profile.kind != .codex && profile.kind != .agent && (!profile.usesClaudeAccountUsage || profile.usesSeparateClaudeAccount) {
            let session = model.companions.sessions(for: profile).filter { $0.usageAt != nil }.max { ($0.usageAt ?? .distantPast) < ($1.usageAt ?? .distantPast) }
            let identity = "claude-session:" + (session?.id ?? profile.id)
            let snapshot = session?.snapshot(identity: identity, now: now)
            // Separate accounts keep their status-line report apart from endpoint readings, as a fallback only.
            if profile.usesSeparateClaudeAccount {
                if statusLineReadings[profile.id] != snapshot { statusLineReadings[profile.id] = snapshot }
                continue
            }
            let value = UsageEntry(snapshot: snapshot, identity: identity, validatingIdentity: false)
            if entries[profile.id] != value { entries[profile.id] = value }
        }
    }

    func shutdown() {
        timer?.invalidate(); timer = nil
        wakeTask?.cancel(); wakeTask = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); generation.removeAll()
        signInTasks.values.forEach { $0.cancel() }; signInTasks.removeAll(); reconnecting.removeAll()
    }

    /// Includes the identity check of a tile that keeps showing its last reading meanwhile.
    var isRefreshing: Bool { !tasks.isEmpty || entries.values.contains { $0.isRefreshing || $0.validatingIdentity } }
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

/// Lets exactly one of several racing callbacks resume a continuation (resuming twice would crash).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}
