import Foundation

public struct HoverIntent {
    public private(set) var expanded = false
    public private(set) var collapseDeadline: TimeInterval?
    /// While held, the island stays open without the pointer, e.g. for a sign-in notice.
    public private(set) var holdUntil: TimeInterval?
    public static let exitDelay: TimeInterval = 0.12
    public init() {}

    public mutating func hold(until deadline: TimeInterval) {
        holdUntil = deadline; collapseDeadline = deadline; expanded = true
    }
    public mutating func releaseHold() {
        guard holdUntil != nil else { return }
        holdUntil = nil; collapseDeadline = nil
    }

    public mutating func update(inside: Bool, now: TimeInterval) -> Bool {
        if inside {
            // The pointer takes over; leaving afterwards collapses normally.
            holdUntil = nil
            collapseDeadline = nil
            expanded = true
        } else if let hold = holdUntil, now < hold {
            collapseDeadline = hold
            expanded = true
        } else if expanded {
            // An expired hold ends with the ordinary exit delay instead of snapping shut.
            if holdUntil != nil { holdUntil = nil; collapseDeadline = nil }
            if collapseDeadline == nil { collapseDeadline = now + Self.exitDelay }
            if now >= (collapseDeadline ?? now) {
                expanded = false
                collapseDeadline = nil
            }
        }
        return expanded
    }
}
