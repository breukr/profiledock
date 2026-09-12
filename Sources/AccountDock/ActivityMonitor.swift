import Foundation
import Network
import Darwin
import DockCore

@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var entries: [String: ActivitySummary] = [:]
    @Published private(set) var event: ActivityEvent?
    private var observers: [String: ProfileActivityObserver] = [:]
    private var observerIDs: [String: UUID] = [:]
    private let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func configure(_ profiles: [Profile], running: Set<String>) {
        let ids = Set(profiles.map(\.id))
        for id in Set(observers.keys).subtracting(ids) {
            observers.removeValue(forKey: id)?.stop(); observerIDs.removeValue(forKey: id); entries.removeValue(forKey: id)
        }
        for profile in profiles {
            if observers[profile.id] == nil {
                let observerID = UUID()
                observerIDs[profile.id] = observerID
                let observer = ProfileActivityObserver(profile: profile, home: home, signal: { [weak self] signal in
                    Task { @MainActor in
                        guard let self, self.observerIDs[profile.id] == observerID else { return }
                        self.event = ActivityEvent(profileID: profile.id, signal: signal)
                    }
                }) { [weak self] summary in
                    Task { @MainActor in
                        guard let self, self.observerIDs[profile.id] == observerID else { return }
                        if self.entries[profile.id] != summary { self.entries[profile.id] = summary }
                    }
                }
                observers[profile.id] = observer
            }
            observers[profile.id]?.setOpen(running.contains(profile.id))
        }
    }
    func shutdown() { observers.values.forEach { $0.stop() }; observers.removeAll(); observerIDs.removeAll() }
    var diagnostics: [String: Any] {
        entries.mapValues { value -> [String: Any] in
            ["unreadFinished": value.unread as Any? ?? NSNull(), "working": value.working, "waiting": value.waiting,
             "liveAvailable": value.liveAvailable, "appOpen": value.appOpen, "coverage": "local Work/Codex tasks"]
        }
    }
}

/// One read-only observer per existing profile. All file, SQLite and stream work stays off the UI thread.
private final class ProfileActivityObserver: @unchecked Sendable {
    private let profile: Profile
    private let home: URL
    private let queue: DispatchQueue
    private let deliver: (ActivitySummary) -> Void
    private let signal: (ActivitySignal) -> Void
    private var metadata: ActivityMetadata?
    private var connection: NWConnection?
    private var generation = 0
    private var client = "initializing-client"
    private var frames = ActivityFrames()
    private var ready = false
    private var open = false
    private var stopped = false
    private var owners: [String: String] = [:]
    private var projections: [String: ActivityProjection] = [:]
    private var pending: [String: String] = [:]
    private var attempted: [String: Date] = [:]
    private var watchers: [String: (UInt64, DispatchSourceFileSystemObject)] = [:]
    private var refreshWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var previous: ActivitySummary?

    init(profile: Profile, home: URL, signal: @escaping (ActivitySignal) -> Void, deliver: @escaping (ActivitySummary) -> Void) {
        self.signal = signal
        self.profile = profile; self.home = home; self.deliver = deliver
        queue = DispatchQueue(label: "nl.breukr.account-dock.activity.\(profile.id)", qos: .utility)
    }

    func setOpen(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let changed = self.open != value
            self.open = value
            if !value, changed { self.disconnect() }
            self.refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true; refreshWork?.cancel(); reconnectWork?.cancel()
            disconnect()
            watchers.values.forEach { $0.1.cancel() }; watchers.removeAll()
        }
    }

    private func scheduleRefresh() {
        guard !stopped, refreshWork == nil else { return }
        // A leading coalesced refresh still fires while a task writes its WAL continuously.
        let work = DispatchWorkItem { [weak self] in self?.refreshWork = nil; self?.refresh() }
        refreshWork = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func refresh() {
        guard !stopped else { return }
        installWatchers()
        do {
            let next = try ActivityMetadata.read(profile: profile, home: home)
            if metadata?.identity != next.identity { disconnect(); attempted.removeAll() }
            metadata = next
            if open, connection == nil { connect() }
            if ready { reconcile() }
        } catch {
            metadata = nil; disconnect()
            scheduleReconnect()
        }
        publish()
    }

    private func installWatchers() {
        let directory = profile.home(in: home)
        let paths = [directory.path] + ["auth.json", ".codex-global-state.json", "state_5.sqlite", "state_5.sqlite-wal", "thread_history_1.sqlite", "thread_history_1.sqlite-wal", "ipc", "sqlite", "sqlite/codex-dev.db", "sqlite/codex-dev.db-wal", "sqlite/codex.db", "sqlite/codex.db-wal"].map { directory.appendingPathComponent($0).path }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                watchers.removeValue(forKey: path)?.1.cancel(); continue
            }
            let inode = UInt64(info.st_ino)
            if watchers[path]?.0 == inode { continue }
            watchers.removeValue(forKey: path)?.1.cancel()
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { Darwin.close(fd) }
            watchers[path] = (inode, source); source.resume()
        }
    }

    private func connect() {
        guard open, !stopped, metadata != nil, connection == nil else { return }
        let path = profile.home(in: home).appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else { scheduleReconnect(); return }
        generation += 1
        let current = generation
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
                self.request("initialize", version: 0, params: ["clientType": "account-dock-read-only"])
                self.receive(connection, generation: current)
            case .failed, .cancelled:
                self.disconnect(); self.publish(); self.scheduleReconnect()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard open, !stopped, reconnectWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            if self.open { self.refresh() }
        }
        reconnectWork = work; queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func disconnect() {
        for (thread, owner) in owners { follow(thread, owner: owner, value: false) }
        generation += 1
        if let old = connection {
            old.stateUpdateHandler = nil
            if ready {
                // Flush observer-unsubscribe messages before closing this stream.
                old.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in old.cancel() })
                queue.asyncAfter(deadline: .now() + 0.25) { old.cancel() }
            } else { old.cancel() }
        }
        connection = nil
        ready = false; client = "initializing-client"; frames = ActivityFrames()
        owners.removeAll(); projections.removeAll(); pending.removeAll(); attempted.removeAll()
    }

    private func receive(_ connection: NWConnection, generation current: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.generation == current, !self.stopped else { return }
            do {
                if let data {
                    // JSON messages live only in this autorelease scope; no transcript is cached or logged.
                    try autoreleasepool { for message in try self.frames.append(data) { self.handle(message) } }
                }
            } catch { self.disconnect(); self.publish(); self.scheduleReconnect(); return }
            if complete || error != nil { self.disconnect(); self.publish(); self.scheduleReconnect() }
            else if self.generation == current { self.receive(connection, generation: current) }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let connection, let data = try? ActivityFrames.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    @discardableResult private func request(_ method: String, version: Int, params: [String: Any]) -> String {
        let id = UUID().uuidString
        send(["type": "request", "requestId": id, "sourceClientId": client, "version": version,
              "method": method, "params": params, "timeoutMs": 2000])
        return id
    }
    private func follow(_ thread: String, owner: String, value: Bool) {
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": client,
              "targetClientIds": [owner], "params": ["conversationId": thread, "hostId": "local", "following": value]])
    }

    private func reconcile() {
        guard ready, let metadata else { return }
        for thread in Set(owners.keys).subtracting(metadata.candidates) {
            if let owner = owners.removeValue(forKey: thread) { follow(thread, owner: owner, value: false) }
            projections.removeValue(forKey: thread)
            attempted.removeValue(forKey: thread)
        }
        for thread in metadata.candidates where owners[thread] == nil && !pending.values.contains(thread) {
            guard Date().timeIntervalSince(attempted[thread] ?? .distantPast) >= 30 else { continue }
            attempted[thread] = Date()
            let requestID = request("thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": thread])
            pending[requestID] = thread
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.pending.removeValue(forKey: requestID) }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "client-discovery-request":
            if let requestID = message["requestId"] { send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]]) }
        case "response":
            if message["method"] as? String == "initialize", let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
                client = id; ready = true; reconcile(); publish()
            } else if let id = message["requestId"] as? String, let thread = pending.removeValue(forKey: id),
                      message["resultType"] as? String == "success", let owner = message["handledByClientId"] as? String,
                      metadata?.candidates.contains(thread) == true {
                owners[thread] = owner; projections[thread] = ActivityProjection()
                follow(thread, owner: owner, value: true)
            }
        case "broadcast":
            guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
            if method == "thread-stream-state-changed", message["version"] as? Int == 11,
               params["hostId"] as? String == "local", let thread = params["conversationId"] as? String,
               let owner = owners[thread], owner == message["sourceClientId"] as? String,
               let change = params["change"] as? [String: Any] {
                var projection = projections[thread] ?? ActivityProjection()
                let old = projection.activity, oldUnread = projection.unread
                let accepted = projection.apply(change)
                projections[thread] = projection
                if accepted, let event = ActivitySignal.transition(from: old, to: projection.activity, isLivePatch: change["type"] as? String == "patches") { signal(event) }
                if !accepted { follow(thread, owner: owner, value: true) }
                if old != projection.activity || oldUnread != projection.unread { publish(); scheduleRefresh() }
            } else if method == "thread-stream-following-status-requested" {
                if params["hostId"] as? String == "local", let thread = params["conversationId"] as? String {
                    if let owner = owners.removeValue(forKey: thread) { follow(thread, owner: owner, value: false) }
                    projections.removeValue(forKey: thread); attempted.removeValue(forKey: thread)
                }
                scheduleRefresh()
            } else if method == "thread-read-state-changed" { scheduleRefresh() }
            else if method == "client-status-changed" {
                if params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
                    for thread in owners.filter({ $0.value == owner }).map(\.key) {
                        owners.removeValue(forKey: thread); projections.removeValue(forKey: thread)
                    }
                    publish()
                }
                attempted.removeAll(); scheduleRefresh()
            }
        default: break
        }
    }

    private func publish() {
        guard !stopped else { return }
        // Never deliver a result cached under credentials from an earlier login.
        if let metadata, (try? ActivityIdentity.read(profile: profile, home: home)) != metadata.identity {
            self.metadata = nil; disconnect(); scheduleRefresh()
        }
        var unread = metadata?.unread
        for (thread, projection) in projections {
            // A cached stream snapshot must never reintroduce an already-read result.
            // Unread events trigger a metadata refresh; only the native persisted read state determines the count.
            if projection.activity == .working || projection.activity == .waiting { unread?.remove(thread) }
        }
        let summary = ActivitySummary(unread: unread?.count, working: projections.values.filter { $0.activity == .working }.count,
                                      waiting: projections.values.filter { $0.activity == .waiting }.count,
                                      liveAvailable: ready && metadata != nil && !projections.values.contains(where: { $0.activity == .unavailable }), appOpen: open)
        if previous != summary { previous = summary; deliver(summary) }
    }
}
