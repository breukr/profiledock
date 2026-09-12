import Foundation
import CoreGraphics

public enum ProfileActivityState: String, CaseIterable, Sendable {
    case working, waiting, unread, idle, unknown, closed

    public init(summary: ActivitySummary?, isOpen: Bool) {
        if let summary, summary.waiting > 0 { self = .waiting }
        else if let summary, summary.working > 0 { self = .working }
        else if (summary?.unread ?? 0) > 0 { self = .unread }
        else if !isOpen { self = .closed }
        else if summary?.liveAvailable == true { self = .idle }
        else { self = .unknown }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs your input"
        case .unread: return "Unread results"
        case .idle: return "Idle"
        case .unknown: return "Activity unavailable"
        case .closed: return "Closed"
        }
    }
}

public enum ActivitySignal: String, Sendable {
    case finished, needsInput

    /// Only consecutive live patches can alert. Startup, reconnect snapshots and gaps stay quiet.
    public static func transition(from old: TaskActivity, to new: TaskActivity, isLivePatch: Bool) -> Self? {
        guard isLivePatch, old != .unavailable, old != new else { return nil }
        if new == .waiting { return .needsInput }
        if new == .idle, old == .working || old == .waiting { return .finished }
        return nil
    }
}

public struct ActivityEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: String
    public let signal: ActivitySignal
    public init(profileID: String, signal: ActivitySignal) {
        id = UUID(); self.profileID = profileID; self.signal = signal
    }
}

public struct ActivityCueLayout: Equatable {
    public let frame: CGRect
    public let origin: CGRect
    public let left: CGRect
    public let right: CGRect
    public init(screen: CGRect, obstacle: CGRect, floating: Bool = false, statusWidth: CGFloat = 88, nameWidth: CGFloat = 140) {
        origin = obstacle
        let height = obstacle.height
        if floating {
            let width = min(screen.width, max(obstacle.width, statusWidth + nameWidth + 28))
            frame = CGRect(x: min(screen.maxX - width, max(screen.minX, obstacle.midX - width / 2)), y: obstacle.minY, width: width, height: height)
            left = CGRect(x: frame.minX + 12, y: frame.minY, width: min(statusWidth, width * 0.42), height: height)
            right = CGRect(x: left.maxX + 8, y: frame.minY, width: max(0, frame.maxX - left.maxX - 20), height: height)
            return
        }
        let leftWidth = min(statusWidth + 16, max(0, obstacle.minX - screen.minX))
        let rightWidth = min(nameWidth + 16, max(0, screen.maxX - obstacle.maxX))
        frame = CGRect(x: obstacle.minX - leftWidth, y: obstacle.minY, width: leftWidth + obstacle.width + rightWidth, height: height)
        left = CGRect(x: frame.minX + 12, y: frame.minY, width: max(0, leftWidth - 20), height: height)
        right = CGRect(x: obstacle.maxX + 8, y: frame.minY, width: max(0, rightWidth - 20), height: height)
    }
}

public struct ActivityNotice: Equatable, Sendable {
    public let signal: ActivitySignal
    public let profileIDs: [String]
}

/// Coalesce duplicate profile events without attributing another profile's result to them.
public struct ActivityCueBatch: Sendable {
    private var events: [String: ActivitySignal] = [:]
    public init() {}
    public mutating func insert(_ event: ActivityEvent) { events[event.profileID] = event.signal }
    public mutating func next() -> ActivityNotice? {
        guard !events.isEmpty else { return nil }
        let signal: ActivitySignal = events.values.contains(.needsInput) ? .needsInput : .finished
        let ids = events.filter { $0.value == signal }.map(\.key).sorted()
        ids.forEach { events.removeValue(forKey: $0) }
        return ActivityNotice(signal: signal, profileIDs: ids)
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public let received: Int64
    public let expected: Int64
    public init(received: Int64, expected: Int64) { self.received = max(0, received); self.expected = max(0, expected) }
    public var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    public var label: String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard expected > 0 else { return receivedText }
        return "\(receivedText) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }
}
