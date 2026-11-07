import Foundation
import Darwin
import DockCore

/// Receives attention items from agent hooks on the local inbox socket and posts them to `AttentionCenter`. A request
/// that holds an agent keeps its connection open; the user's decision is written back on that connection, once.
/// All socket work runs on a private serial queue (one background lane, so it never waits on the main thread);
/// `AttentionCenter` is only touched on the main thread.
final class InboxServer: @unchecked Sendable {
    static let maxConnections = 64
    /// A connection that has not sent a request after this long is closed, so idle peers cannot use up the slots.
    static let idleTimeout: TimeInterval = 5
    let socketURL: URL
    private let directory: URL
    private let attention: AttentionCenter
    private let queue = DispatchQueue(label: "nl.breukr.account-dock.inbox", qos: .userInitiated)
    private var listener: DispatchSourceRead?
    private var socketInode: ino_t?
    private var connections: [Int32: Connection] = [:]
    /// Request id -> the connection whose hook is waiting for it.
    private var waiting: [String: Int32] = [:]
    /// Ids already seen, so a request id is used once (bounded to the newest 1000).
    private var seen: Set<String> = [], seenOrder: [String] = []
    /// Main thread only: sessions with a PermissionRequest since their last activity, so Claude's later
    /// "permission_prompt" notification for the same prompt is not shown twice.
    private var permissionSessions: Set<String> = []
    /// Main thread only. Decides whether a request may hold its agent, for example false while the user is already in
    /// that session's terminal. Returning false releases the agent at once and shows nothing.
    var shouldHold: ((AgentAttention) -> Bool)?

    private final class Connection {
        let fd: Int32, source: DispatchSourceRead
        var frames = AgentInboxFrames()
        var requestID: String?
        /// The held item's kind, current deadline and the latest it may be extended to (the helper enforces the same cap).
        var kind: AttentionKind?
        var deadline: Date?
        var limit: Date?
        var timer: DispatchWorkItem?
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    init(home: URL, attention: AttentionCenter) {
        directory = AgentInbox.directory(home: home); socketURL = AgentInbox.socket(home: home); self.attention = attention
    }

    @MainActor func start() throws {
        attention.onDecision = { [weak self] id, decision in self?.send(id, decision) }
        attention.onExtend = { [weak self] id, until in self?.extend(id, until: until) }
        try queue.sync { try listen() }
    }

    /// Closes every connection, so waiting hooks print nothing and the agents show their own dialogs.
    @MainActor func stop() {
        attention.onDecision = nil; attention.onExtend = nil
        queue.sync {
            listener?.cancel(); listener = nil
            for connection in connections.values { connection.timer?.cancel(); connection.source.cancel() }
            connections.removeAll(); waiting.removeAll()
            var info = stat()
            if let socketInode, lstat(socketURL.path, &info) == 0, info.st_ino == socketInode { unlink(socketURL.path) }
            socketInode = nil
        }
    }

    private func listen() throws {
        guard listener == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { throw CompanionError.message("The inbox folder is not a private folder.") }
        chmod(directory.path, 0o700)
        if lstat(socketURL.path, &info) == 0 {
            // A socket left by an earlier run is replaced; anything else at that path is not ours to remove.
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { throw CompanionError.message("Another file is in the way of the inbox socket.") }
            unlink(socketURL.path)
        }
        guard var address = AgentInbox.address(socketURL.path) else { throw CompanionError.message("The inbox socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CompanionError.message("Cannot open the inbox socket.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(socketURL.path, 0o600) == 0, Darwin.listen(fd, 16) == 0, lstat(socketURL.path, &info) == 0 else {
            Darwin.close(fd); throw CompanionError.message("Cannot open the inbox socket.")
        }
        socketInode = info.st_ino
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source; source.resume()
    }

    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // Only processes of the same macOS user may talk to the app.
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(), connections.count < Self.maxConnections else { Darwin.close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(fd: fd, source: source)
            source.setEventHandler { [weak self, weak connection] in if let self, let connection { self.read(connection) } }
            source.setCancelHandler { Darwin.close(fd) }
            connections[fd] = connection
            schedule(connection, after: Self.idleTimeout)
            source.resume()
        }
    }

    private func schedule(_ connection: Connection, after delay: TimeInterval) {
        connection.timer?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in if let self, let connection { self.close(connection) } }
        connection.timer = work
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func read(_ connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(connection.fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { close(connection); return }
        do {
            for body in try connection.frames.append(Data(buffer[0..<count])) where connections[connection.fd] === connection {
                handle(try AgentInbox.decode(body), from: connection)
            }
        } catch { close(connection) }
    }

    private func handle(_ message: AgentInboxMessage, from connection: Connection) {
        switch message {
        case .attention(let raw, let notification):
            // Reused ids and malformed items end the connection; nothing is shown for them.
            guard let item = raw.sanitized(), !seen.contains(item.id), !(item.awaitsDecision && connection.requestID != nil) else { close(connection); return }
            remember(item.id)
            if item.awaitsDecision, let deadline = item.deadline {
                connection.requestID = item.id; waiting[item.id] = connection.fd
                connection.kind = item.kind; connection.deadline = deadline
                // A reply can be extended while the user types; a permission wait keeps the hold the hook group was given.
                connection.limit = item.kind == .finished ? StopReply.limit(receivedAt: item.receivedAt) : deadline
                schedule(connection, after: deadline.timeIntervalSinceNow + 1)
            }
            main { $0.present(item, notification: notification) }
        case .clear(let source, let sessionID, let includeFinished):
            main { $0.clear(source: source, sessionID: sessionID, includeFinished: includeFinished) }
        case .decision, .extend:
            close(connection)
        }
    }

    /// Moves a held request's deadline (the user is typing a reply) and tells its hook, capped at the request's limit.
    /// When the cap is lower than asked, the item's countdown is corrected to the real deadline.
    private func extend(_ id: String, until: Date) {
        queue.async { [self] in
            guard let fd = waiting[id], let connection = connections[fd], let limit = connection.limit else { return }
            let capped = min(until, limit)
            if let current = connection.deadline, capped > current,
               let data = try? AgentInbox.encode(.extend(id: id, until: capped)), AgentInboxClient.write(data, to: fd, until: Date().addingTimeInterval(1)) {
                connection.deadline = capped
                schedule(connection, after: capped.timeIntervalSinceNow + 1)
            }
            let real = connection.deadline ?? capped
            if real < until { main { $0.correctDeadline(id, to: real) } }
        }
    }

    @MainActor private func correctDeadline(_ id: String, to deadline: Date) {
        guard var item = attention.items.first(where: { $0.id == id }), item.deadline != deadline else { return }
        item.deadline = deadline
        attention.post(item)
    }

    private func remember(_ id: String) {
        seen.insert(id); seenOrder.append(id)
        if seenOrder.count > 1_000 { seenOrder.prefix(500).forEach { seen.remove($0) }; seenOrder.removeFirst(500) }
    }

    /// Writes the decision to the connection still waiting for `id`. Unknown or finished ids are ignored.
    private func send(_ id: String, _ decision: AttentionDecision) {
        queue.async { [self] in
            guard let fd = waiting.removeValue(forKey: id), let connection = connections[fd],
                  let data = try? AgentInbox.encode(.decision(id: id, decision: decision)) else { return }
            _ = AgentInboxClient.write(data, to: fd, until: Date().addingTimeInterval(1))
            close(connection, expire: false)
        }
    }

    /// Ends a connection. A request still waiting is expired, so its item leaves the notch; a finished turn that waited
    /// for a reply stays as a plain "Done" item.
    private func close(_ connection: Connection, expire: Bool = true) {
        guard connections[connection.fd] === connection else { return }
        connections.removeValue(forKey: connection.fd)
        connection.timer?.cancel(); connection.source.cancel()
        if let id = connection.requestID, waiting[id] == connection.fd {
            waiting.removeValue(forKey: id)
            if expire, connection.kind == .finished { main { $0.demote(id) } } else if expire { main { $0.attention.expire(id) } }
        }
    }

    /// Keeps an item but marks it as no longer holding its agent (same id, no deadline).
    @MainActor private func demote(_ id: String) {
        guard var item = attention.items.first(where: { $0.id == id }), item.awaitsDecision else { return }
        item.deadline = nil
        attention.post(item)
    }

    /// Lets every held finished turn that `release` matches end now (for example the user switched to its terminal);
    /// the items stay as plain "Done" items.
    @MainActor func releaseHeldReplies(where release: (AgentAttention) -> Bool) {
        for item in attention.items where item.kind == .finished && item.awaitsDecision && release(item) {
            demote(item.id)
            send(item.id, .passThrough)
        }
    }

    private func main(_ body: @escaping @MainActor (InboxServer) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { MainActor.assumeIsolated { body(self) } } }
    }

    @MainActor private func present(_ item: AgentAttention, notification: String?) {
        let key = item.source + "\u{0}" + item.sessionID
        if item.kind == .permission, notification == nil {
            if permissionSessions.count > 500 { permissionSessions.removeAll() }
            permissionSessions.insert(key)
        }
        if notification == "permission_prompt", permissionSessions.contains(key)
            || attention.items.contains(where: { $0.source == item.source && $0.sessionID == item.sessionID && ($0.kind == .permission || $0.kind == .question) }) { return }
        if item.awaitsDecision, let shouldHold, !shouldHold(item) {
            if item.kind == .finished {
                // The turn ends at once, but "Done" is still shown.
                var shown = item; shown.deadline = nil
                attention.post(shown); send(item.id, .passThrough); attention.compact(); return
            }
            // Released before it was shown: the agent's own dialog takes over at once.
            attention.post(item); attention.respond(item.id, .passThrough); return
        }
        attention.post(item)
        attention.compact()
    }

    /// The session moved on: display-only items that no longer apply leave. Requests that hold an agent stay.
    @MainActor private func clear(source: String, sessionID: String, includeFinished: Bool) {
        permissionSessions.remove(source + "\u{0}" + sessionID)
        for item in attention.items where item.source == source && item.sessionID == sessionID && !item.awaitsDecision && (includeFinished || item.kind != .finished) {
            attention.expire(item.id)
        }
    }
}

/// Whether a request may hold its agent, given the app in front. Never while the user is in a terminal (they see the agent's
/// own prompt) or in the session's own app (Claude Desktop for its Code tab, the Codex or ChatGPT app for Codex chats).
enum AttentionHoldPolicy {
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let codexApps: Set<String> = ["com.openai.codex", "com.openai.chat"]

    static func allows(_ item: AgentAttention, frontmost: String?, isTerminal: (String?) -> Bool = CompanionPolling.isTerminalApp) -> Bool {
        if isTerminal(frontmost) { return false }
        guard let frontmost else { return true }
        switch (item.source, item.entrypoint) {
        case ("claude", "claude-desktop"): return frontmost != claudeDesktop
        case ("codex", _): return !codexApps.contains(frontmost)
        default: return true
        }
    }
}

/// Starts the inbox with the app and keeps the helper's switches and the Claude Code connection in step with preferences.
@MainActor
final class AgentInboxService {
    let server: InboxServer
    private let model: DockModel
    private var writtenFlags: AgentInboxFlags?
    private var refreshedHold: Int?
    private(set) var lastError: String?

    init(model: DockModel, attention: AttentionCenter) {
        self.model = model
        server = InboxServer(home: model.home, attention: attention)
    }

    /// `replyHold` is the seconds a finished turn waits for a reply typed in the pop-up (0 = off), from preferences.
    static func flags(for preferences: Preferences, replyHold: Int? = nil) -> AgentInboxFlags {
        let replyHold = max(0, min(60, replyHold ?? preferences.replyHoldSeconds ?? AgentInbox.defaultReplyHold))
        return AgentInboxFlags(popups: preferences.attentionPopups != false, answerFromNotch: preferences.answerPermissionsFromNotch != false,
                        holdSeconds: AgentInbox.clampedHold(preferences.attentionHoldSeconds), replyHoldSeconds: replyHold)
    }

    func start(bundledHelper: URL? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ProfileDockClaude")) {
        do { try server.start() } catch { lastError = error.localizedDescription }
        preferencesChanged(bundledHelper: bundledHelper)
    }

    /// Call from `DockModel.onPreferencesChanged`. Rewrites the helper's switches when they changed and, at launch or
    /// when the hold time changed, refreshes every connected Claude configuration in the background.
    func preferencesChanged(bundledHelper: URL? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ProfileDockClaude")) {
        let flags = Self.flags(for: model.preferences)
        if flags != writtenFlags {
            do { try flags.write(home: model.home); writtenFlags = flags } catch { lastError = error.localizedDescription }
        }
        guard refreshedHold != flags.holdSeconds else { return }
        refreshedHold = flags.holdSeconds
        let bridges = model.claudeBridges, hold = flags.holdSeconds, others = AgentHookBridge(home: model.home)
        Task.detached(priority: .utility) {
            for bridge in bridges { _ = try? bridge.refresh(bundledHelper: bundledHelper, hold: hold) }
            // Other agents connected by an older version get their current entries (for example Codex's longer Stop timeout).
            others.refreshConnected(bundledHelper: bundledHelper)
        }
    }

    func stop() { server.stop() }
}
