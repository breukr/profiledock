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
        case .unknown: return "Task status unknown"
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
    public let left: CGRect
    public let right: CGRect
    public init(screen: CGRect, obstacle: CGRect, floating: Bool = false) {
        let height = min(26, max(12, obstacle.height - 4))
        let width = min(42, max(0, (screen.width - obstacle.width) / 2 - 8))
        if floating {
            let y = obstacle.maxY + 6 + height <= screen.maxY ? obstacle.maxY + 6 : max(screen.minY, obstacle.minY - height - 6)
            left = CGRect(x: obstacle.minX, y: y, width: width, height: height)
            right = CGRect(x: obstacle.maxX - width, y: y, width: width, height: height)
            return
        }
        let y = min(screen.maxY - height, obstacle.midY - height / 2)
        left = CGRect(x: max(screen.minX, obstacle.minX - width - 5), y: y, width: width, height: height)
        right = CGRect(x: min(screen.maxX - width, obstacle.maxX + 5), y: y, width: width, height: height)
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
