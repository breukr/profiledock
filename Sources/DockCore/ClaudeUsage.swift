import Foundation
import CoreFoundation

/// Account measurements are independent of Claude Code's optional terminal status line.
public enum ClaudeUsageParser {
    public static func parse(_ data: Data, identity: String, plan: String?, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageParseError.invalidResponse }
        var malformed = false
        let windows = [("seven_day", 604800.0), ("five_hour", 18000.0)].compactMap { key, duration -> UsageWindow? in
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let value = raw as? [String: Any], let used = number(value["utilization"]), used >= 0,
                  let text = value["resets_at"] as? String, let reset = date(text) else { malformed = true; return nil }
            return UsageWindow(id: key, duration: duration, usedPercent: used, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw UsageParseError.invalidResponse }
        let inventory = resets(root["cedar_ember"], now: fetchedAt)
        return UsageSnapshot(identity: identity, plan: plan, windows: windows, bankedResets: inventory?.count,
                             applicableResets: inventory?.usable, resetExpiries: inventory?.expiries,
                             fetchedAt: fetchedAt, hasUnparsedWindows: malformed)
    }

    public struct ResetInventory: Equatable, Sendable {
        public let count: Int
        public let usable: Int
        public let expiries: [Date]
    }

    public static func resets(_ raw: Any?, now: Date) -> ResetInventory? {
        guard let value = raw as? [String: Any], value["eligible"] as? Bool == true,
              let grants = value["grants"] as? [[String: Any]], grants.count <= 256 else { return nil }
        var count = 0, usable = 0, expiries: [Date] = []
        var ids: Set<String> = []
        for grant in grants {
            guard let id = grant["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let remaining = number(grant["resets_left"]), remaining >= 0, remaining <= 1000,
                  remaining.rounded() == remaining else { return nil }
            for field in ["ends_at", "starts_at"] {
                if let raw = grant[field], !(raw is NSNull), !(raw is String) { return nil }
            }
            let end: Date?
            if let text = grant["ends_at"] as? String {
                guard let parsed = date(text) else { return nil }; end = parsed
            } else { end = nil }
            if let end, end <= now { continue }
            if let text = grant["starts_at"] as? String {
                guard let start = date(text) else { return nil }
                if start > now { continue }
            }
            let amount = Int(remaining)
            count += amount
            if grant["usable_now"] as? Bool == true, grant["paused"] as? Bool != true { usable += amount }
            if let end { expiries.append(contentsOf: Array(repeating: end, count: amount)) }
        }
        return ResetInventory(count: count, usable: usable, expiries: expiries.sorted())
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]; return parser.date(from: text)
    }
}
