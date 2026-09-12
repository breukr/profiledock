import Foundation

public enum TaskActivity: String, Sendable {
    case working, waiting, idle, unavailable

    public static func parse(_ runtime: [String: Any]?) -> TaskActivity {
        guard let runtime else { return .unavailable }
        switch runtime["type"] as? String {
        case "idle": return .idle
        case "active":
            let flags = runtime["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? .waiting : .working
        default: return .unavailable
        }
    }
}

/// Retains only status metadata. Conversation text and tool payloads are never stored.
public struct ActivityProjection {
    public private(set) var revision: Int?
    public private(set) var activity: TaskActivity = .unavailable
    public private(set) var unread: Bool?
    private var runtime: [String: Any]?
    public init() {}

    /// False means a revision gap or unsupported update: the observer needs a fresh snapshot.
    public mutating func apply(_ change: [String: Any]) -> Bool {
        guard let next = change["revision"] as? Int else { return invalidate() }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            runtime = state["threadRuntimeStatus"] as? [String: Any]
            unread = state["hasUnreadTurn"] as? Bool
        } else if change["type"] as? String == "patches", let base = change["baseRevision"] as? Int,
                  base == revision, let patches = change["patches"] as? [[String: Any]] {
            for patch in patches {
                guard let path = patch["path"] as? [Any], let first = path.first as? String else { continue }
                let remove = patch["op"] as? String == "remove"
                if first == "hasUnreadTurn", path.count == 1 { unread = remove ? nil : patch["value"] as? Bool }
                if first == "threadRuntimeStatus" {
                    if path.count == 1 { runtime = remove ? nil : patch["value"] as? [String: Any] }
                    else if path.count == 2, let key = path[1] as? String {
                        if remove { runtime?.removeValue(forKey: key) } else { runtime?[key] = patch["value"] }
                    } else if path.count == 3, path[1] as? String == "activeFlags", let index = path[2] as? Int {
                        var flags = runtime?["activeFlags"] as? [String] ?? []
                        if remove, flags.indices.contains(index) { flags.remove(at: index) }
                        else if let value = patch["value"] as? String, index >= 0, index <= flags.count {
                            if patch["op"] as? String == "add" { flags.insert(value, at: index) }
                            else if flags.indices.contains(index) { flags[index] = value }
                        } else { return invalidate() }
                        runtime?["activeFlags"] = flags
                    } else { return invalidate() }
                }
            }
        } else { return invalidate() }
        revision = next
        activity = TaskActivity.parse(runtime)
        return true
    }

    private mutating func invalidate() -> Bool {
        revision = nil; runtime = nil; unread = nil; activity = .unavailable
        return false
    }
}

public struct ActivitySummary: Equatable, Sendable {
    public var unread: Int?
    public var working = 0
    public var waiting = 0
    public var liveAvailable = false
    public var appOpen = false
    public init(unread: Int? = nil, working: Int = 0, waiting: Int = 0, liveAvailable: Bool = false, appOpen: Bool = false) {
        self.unread = unread; self.working = working; self.waiting = waiting
        self.liveAvailable = liveAvailable; self.appOpen = appOpen
    }
    public var badge: String? { unread.flatMap { $0 > 0 ? ($0 > 99 ? "99+" : String($0)) : nil } }
}

public enum ActivityFrameError: Error { case oversized, invalidJSON }

/// Length-prefixed local desktop IPC. The bound also covers a fragmented oversized message.
public struct ActivityFrames {
    public static let limit = 64 * 1_024 * 1_024
    private var buffer = Data()
    public init() {}
    public mutating func append(_ chunk: Data) throws -> [[String: Any]] {
        buffer.append(chunk)
        var messages: [[String: Any]] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let length = (0..<4).reduce(0) { $0 | Int(buffer[offset + $1]) << ($1 * 8) }
            guard length > 0, length <= Self.limit else { buffer.removeAll(); throw ActivityFrameError.oversized }
            guard buffer.count - offset >= length + 4 else { break }
            guard let object = try JSONSerialization.jsonObject(with: buffer.subdata(in: (offset + 4)..<(offset + 4 + length))) as? [String: Any] else { throw ActivityFrameError.invalidJSON }
            messages.append(object)
            offset += 4 + length
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        guard buffer.count <= Self.limit + 4 else { buffer.removeAll(); throw ActivityFrameError.oversized }
        return messages
    }
    public static func encode(_ value: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: value)
        var length = UInt32(body.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(body)
        return data
    }
}
