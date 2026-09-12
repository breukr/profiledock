import Foundation

public struct HoverIntent {
    public private(set) var expanded = false
    public private(set) var collapseDeadline: TimeInterval?
    public static let exitDelay: TimeInterval = 0.12
    public init() {}

    public mutating func update(inside: Bool, now: TimeInterval) -> Bool {
        if inside {
            collapseDeadline = nil
            expanded = true
        } else if expanded {
            if collapseDeadline == nil { collapseDeadline = now + Self.exitDelay }
            if now >= (collapseDeadline ?? now) {
                expanded = false
                collapseDeadline = nil
            }
        }
        return expanded
    }
}
