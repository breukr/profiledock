import Foundation
import Darwin

/// The local inbox between agent hooks and the app: a Unix domain socket (a file-system address that only processes
/// on this Mac can open) carrying length-prefixed JSON frames (a 4-byte little-endian length, then the JSON body).
public enum AgentInbox {
    public static let frameLimit = 256 * 1_024
    public static let defaultHold = 90
    /// Seconds a hook may wait for an answer. Values outside are clamped.
    public static let holdRange = 1...600
    public static func clampedHold(_ value: Int?) -> Int { min(max(value ?? defaultHold, holdRange.lowerBound), holdRange.upperBound) }
    /// Hook timeout for the two hook groups that may wait. It leaves the helper 15 seconds to give up on its own first.
    public static func blockingTimeout(hold: Int) -> Int { clampedHold(hold) + 15 }
    /// Seconds a finished turn waits for a reply typed in the pop-up before the agent ends its turn. 0 turns it off.
    public static let defaultReplyHold = 12
    /// A reply hold can be extended while the user types, but never past this many seconds after the turn ended.
    public static let maxReplyHold = 600
    public static func clampedReplyHold(_ value: Int?) -> Int { min(max(value ?? defaultReplyHold, 0), maxReplyHold) }
    /// Hook timeout for the Stop group: the longest reply hold plus the same 15-second margin.
    public static var replyTimeout: Int { maxReplyHold + 15 }
    public static func directory(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Account Dock/Inbox") }
    public static func socket(home: URL) -> URL { directory(home: home).appendingPathComponent("inbox.sock") }
    /// Written by the app, read by the helper: whether pop-ups and notch answers are on, and the hold time.
    public static func flagsFile(home: URL) -> URL { directory(home: home).appendingPathComponent("settings.json") }
    /// Empty marker files, one per session whose last turn was continued by a pop-up reply (`StopReplyMarkers`).
    public static func replyMarkers(home: URL) -> URL { directory(home: home).appendingPathComponent("replies") }

    /// Request ids are one-time tokens: letters, digits and dashes, at most 128 characters.
    public static func validID(_ value: String) -> Bool { value.count <= 128 && Profile.validID(value) }

    public static func encode(_ message: AgentInboxMessage) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let body = try encoder.encode(message)
        guard body.count <= frameLimit else { throw ActivityFrameError.oversized }
        return AgentInboxFrames.frame(body)
    }
    public static func decode(_ body: Data) throws -> AgentInboxMessage {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(AgentInboxMessage.self, from: body)
    }

    /// The socket address for `path`, or nil when the path does not fit (macOS allows 103 bytes).
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !path.isEmpty, path.utf8.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: Array(path.utf8)) }
        return address
    }
}

/// Messages on the inbox socket. The helper sends `attention` and `clear`; the app answers a held request with `decision`,
/// and may first send `extend` to move its deadline while the user is still typing.
public enum AgentInboxMessage: Equatable, Sendable {
    /// `notification` names the Claude Code notification type an item came from, so the app can skip duplicates.
    case attention(AgentAttention, notification: String?)
    case decision(id: String, decision: AttentionDecision)
    /// Hold request `id` until `until` instead (the helper caps it, see `AgentInboxClient.request`).
    case extend(id: String, until: Date)
    /// The session moved on (a tool ran, a prompt was sent, the session ended): stale display-only items can go.
    case clear(source: String, sessionID: String, includeFinished: Bool)
}

extension AgentInboxMessage: Codable {
    private enum Keys: String, CodingKey { case type, item, notification, id, decision, source, sessionID, includeFinished, until }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "attention": self = .attention(try container.decode(AgentAttention.self, forKey: .item), notification: try container.decodeIfPresent(String.self, forKey: .notification))
        case "decision": self = .decision(id: try container.decode(String.self, forKey: .id), decision: try container.decode(AttentionDecision.self, forKey: .decision))
        case "extend": self = .extend(id: try container.decode(String.self, forKey: .id), until: try container.decode(Date.self, forKey: .until))
        case "clear": self = .clear(source: try container.decode(String.self, forKey: .source), sessionID: try container.decode(String.self, forKey: .sessionID),
                                    includeFinished: try container.decodeIfPresent(Bool.self, forKey: .includeFinished) ?? false)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown inbox message")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .attention(let item, let notification):
            try container.encode("attention", forKey: .type); try container.encode(item, forKey: .item); try container.encodeIfPresent(notification, forKey: .notification)
        case .decision(let id, let decision):
            try container.encode("decision", forKey: .type); try container.encode(id, forKey: .id); try container.encode(decision, forKey: .decision)
        case .extend(let id, let until):
            try container.encode("extend", forKey: .type); try container.encode(id, forKey: .id); try container.encode(until, forKey: .until)
        case .clear(let source, let sessionID, let includeFinished):
            try container.encode("clear", forKey: .type); try container.encode(source, forKey: .source)
            try container.encode(sessionID, forKey: .sessionID); try container.encode(includeFinished, forKey: .includeFinished)
        }
    }
}

/// Splits a byte stream into frame bodies. A frame over `limit`, even one still arriving in pieces, is an error.
public struct AgentInboxFrames {
    public let limit: Int
    private var buffer = Data()
    public init(limit: Int = AgentInbox.frameLimit) { self.limit = limit }
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = [], offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = (0..<4).reduce(0) { $0 | Int(buffer[offset + $1]) << ($1 * 8) }
            guard length > 0, length <= limit else { buffer.removeAll(); throw ActivityFrameError.oversized }
            guard buffer.endIndex - offset >= length + 4 else { break }
            bodies.append(Data(buffer[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
        buffer = Data(buffer[offset...])
        return bodies
    }
    public static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(body)
        return data
    }
}

/// The app's switches as the helper sees them. A missing file means the app never wrote one: nothing is held.
public struct AgentInboxFlags: Codable, Equatable, Sendable {
    public var popups: Bool
    public var answerFromNotch: Bool
    public var holdSeconds: Int
    /// Seconds a finished turn waits for a reply typed in the pop-up (0 = off). Files written before this key existed
    /// read as the default.
    public var replyHoldSeconds: Int
    public init(popups: Bool = true, answerFromNotch: Bool = true, holdSeconds: Int = AgentInbox.defaultHold, replyHoldSeconds: Int = AgentInbox.defaultReplyHold) {
        self.popups = popups; self.answerFromNotch = answerFromNotch; self.holdSeconds = AgentInbox.clampedHold(holdSeconds)
        self.replyHoldSeconds = AgentInbox.clampedReplyHold(replyHoldSeconds)
    }
    /// A request is held only when the pop-up that can answer it is shown.
    public var holds: Bool { popups && answerFromNotch }
    /// A finished turn is held for a reply only while pop-ups are on and the reply wait is not 0.
    public var holdsReplies: Bool { popups && replyHoldSeconds > 0 }

    private enum CodingKeys: String, CodingKey { case popups, answerFromNotch, holdSeconds, replyHoldSeconds }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(popups: try container.decode(Bool.self, forKey: .popups), answerFromNotch: try container.decode(Bool.self, forKey: .answerFromNotch),
                  holdSeconds: try container.decode(Int.self, forKey: .holdSeconds),
                  replyHoldSeconds: try container.decodeIfPresent(Int.self, forKey: .replyHoldSeconds) ?? AgentInbox.defaultReplyHold)
    }

    public static func read(home: URL) -> AgentInboxFlags? {
        let url = AgentInbox.flagsFile(home: home)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? .max) <= 4_096, let data = try? Data(contentsOf: url),
              var flags = try? JSONDecoder().decode(AgentInboxFlags.self, from: data) else { return nil }
        flags.holdSeconds = AgentInbox.clampedHold(flags.holdSeconds)
        return flags
    }
    public func write(home: URL) throws {
        let directory = AgentInbox.directory(home: home), url = AgentInbox.flagsFile(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw CompanionError.message("The inbox settings path is linked elsewhere.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension AttentionQuestion {
    /// Bounded copy for display: at most 8 options, with control characters removed.
    public func sanitized() -> AttentionQuestion? {
        let text = AgentAttention.clean(question, limit: 300)
        guard !text.isEmpty else { return nil }
        let choices = options.prefix(8).compactMap { option -> AttentionOption? in
            let label = AgentAttention.clean(option.label, limit: 80)
            return label.isEmpty ? nil : AttentionOption(label: label, detail: option.detail.map { AgentAttention.clean($0, limit: 200) }.flatMap { $0.isEmpty ? nil : $0 })
        }
        return AttentionQuestion(header: header.map { AgentAttention.clean($0, limit: 40) }.flatMap { $0.isEmpty ? nil : $0 }, question: text, options: choices, multiSelect: multiSelect)
    }
}

extension AgentAttention {
    /// Re-validates an item that arrived over the socket: bounded text, known shapes, and a deadline only where a
    /// decision is possible and within the longest hold. Nil for an item that cannot be shown. Sources are registry ids
    /// (lowercase letters, digits and dashes, such as "cursor-cli").
    public func sanitized(now: Date = Date()) -> AgentAttention? {
        guard AgentInbox.validID(id), source.count <= 16, source.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
              ClaudeSession.validID(sessionID) else { return nil }
        let questions = self.questions.prefix(4).compactMap { $0.sanitized() }
        guard kind != .question || !questions.isEmpty else { return nil }
        let latest = now.addingTimeInterval(TimeInterval(AgentInbox.blockingTimeout(hold: AgentInbox.holdRange.upperBound)))
        // A finished turn may wait too: for a reply typed in the pop-up (`AttentionDecision.reply`).
        let deadline = kind != .waiting ? self.deadline.flatMap { $0 > now && $0 <= latest ? $0 : nil } : nil
        func path(_ value: String?) -> String? { value.flatMap { $0.hasPrefix("/") && $0.utf8.count < 4_096 ? $0 : nil } }
        return AgentAttention(id: id, source: source, sessionID: sessionID, kind: kind, title: title, message: message, toolName: toolName, preview: preview,
                              questions: questions, cwd: path(cwd), configDirectory: path(configDirectory), tty: tty.flatMap { ClaudeSession.validTTY($0) ? $0 : nil },
                              pid: pid.flatMap { $0 > 0 ? $0 : nil }, entrypoint: entrypoint.map { AgentAttention.clean($0, limit: 40) },
                              receivedAt: now, deadline: deadline)
    }
}

/// The helper's side of the socket. Every call is bounded in time and fails quietly: no app means no answer.
public enum AgentInboxClient {
    /// Connects within `timeout` seconds, or nil when the app is not listening.
    public static func connect(_ socket: URL, timeout: TimeInterval) -> Int32? {
        guard var address = AgentInbox.address(socket.path) else { return nil }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN, wait(fd, for: Int16(POLLOUT), until: Date().addingTimeInterval(timeout)) else { Darwin.close(fd); return nil }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { Darwin.close(fd); return nil }
        }
        return fd
    }

    /// Sends one message without waiting for a reply. False when the app is not running.
    @discardableResult public static func post(_ message: AgentInboxMessage, socket: URL, timeout: TimeInterval = 0.05) -> Bool {
        guard let data = try? AgentInbox.encode(message), let fd = connect(socket, timeout: timeout) else { return false }
        defer { Darwin.close(fd) }
        return write(data, to: fd, until: Date().addingTimeInterval(timeout))
    }

    /// Sends a request and waits until `deadline` for the app's decision on that id. Nil means no answer: let the agent ask.
    /// The app may move the deadline with `extend` while the user types, never past `limit` (nil: the deadline is fixed),
    /// so the hook always gives up before the agent's own hook timeout.
    public static func request(_ item: AgentAttention, socket: URL, connectTimeout: TimeInterval = 0.1, deadline: Date, limit: Date? = nil) -> AttentionDecision? {
        guard let data = try? AgentInbox.encode(.attention(item, notification: nil)), let fd = connect(socket, timeout: connectTimeout) else { return nil }
        defer { Darwin.close(fd) }
        guard write(data, to: fd, until: min(deadline, Date().addingTimeInterval(1))) else { return nil }
        var frames = AgentInboxFrames(), buffer = [UInt8](repeating: 0, count: 16_384), deadline = deadline
        let limit = max(limit ?? deadline, deadline)
        while wait(fd, for: Int16(POLLIN), until: deadline) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0, let bodies = try? frames.append(Data(buffer[0..<count])) else { return nil }
            for body in bodies {
                switch try? AgentInbox.decode(body) {
                case .decision(let id, let decision)? where id == item.id: return decision
                case .extend(let id, let until)? where id == item.id: deadline = max(deadline, min(until, limit))
                default: break
                }
            }
        }
        return nil
    }

    public static func write(_ data: Data, to fd: Int32, until deadline: Date) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EAGAIN || errno == EINTR, wait(fd, for: Int16(POLLOUT), until: deadline) else { return false }
        }
        return true
    }

    /// Waits with poll() (a system call that sleeps until the socket is ready or the time is up). False on timeout or error.
    public static func wait(_ fd: Int32, for events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1_000, 60_000).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { if result == 0 { continue }; return false }
            return descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
        }
    }
}
