import Foundation

public struct UsageWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let duration: TimeInterval
    public let usedPercent: Double
    public let resetsAt: Date?
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    public var title: String {
        if duration == 604800 { return "Week" }
        if duration == 18000 { return "5 hours" }
        if duration >= 86400, duration.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(duration / 86400)) days" }
        if duration >= 3600, duration.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(duration / 3600)) hours" }
        return "\(Int(duration / 60)) min"
    }
    public init(id: String, duration: TimeInterval, usedPercent: Double, resetsAt: Date?) {
        self.id = id; self.duration = duration; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let identity: String
    public let plan: String?
    public let windows: [UsageWindow]
    public let bankedResets: Int?
    public let applicableResets: Int?
    public let resetExpiries: [Date]?
    public let fetchedAt: Date
    public let hasUnparsedWindows: Bool

    public init(identity: String, plan: String?, windows: [UsageWindow], bankedResets: Int?, applicableResets: Int?, resetExpiries: [Date]?, fetchedAt: Date, hasUnparsedWindows: Bool = false) {
        self.identity = identity; self.plan = plan; self.windows = windows
        self.bankedResets = bankedResets; self.applicableResets = applicableResets
        self.resetExpiries = resetExpiries; self.fetchedAt = fetchedAt; self.hasUnparsedWindows = hasUnparsedWindows
    }
}

public enum UsageParseError: Error { case invalidResponse, wrongAccount }

/// The wire schema is the account-scoped Codex usage endpoint used by CodexBar.
/// Banked resets are distinct from both purchase credits and resets currently applicable to a reached limit.
public enum UsageParser {
    public static func parse(usage: Data, resets: Data?, expectedAccount: String, identity: String, fetchedAt: Date) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(UsagePayload.self, from: usage)
        guard payload.accountID == expectedAccount else { throw UsageParseError.wrongAccount }
        let slots = [("primary", payload.rateLimit?.primary), ("secondary", payload.rateLimit?.secondary)]
        let windows = slots.compactMap { id, raw -> UsageWindow? in
            guard let raw, raw.duration.isFinite, raw.duration > 0, raw.duration <= 366 * 86400,
                  raw.usedPercent.isFinite, raw.usedPercent >= 0 else { return nil }
            let reset = raw.resetAt.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                ?? raw.resetAfter.flatMap { $0 >= 0 && $0.isFinite ? fetchedAt.addingTimeInterval($0) : nil }
            return UsageWindow(id: id, duration: raw.duration, usedPercent: raw.usedPercent, resetsAt: reset)
        }.sorted { $0.duration > $1.duration }
        let inventory = resets.flatMap { try? JSONDecoder().decode(ResetPayload.self, from: $0) }
        let count = validCount(inventory?.availableCount) ?? validCount(payload.resetCredits?.availableCount)
        let expiries = inventory?.credits?.compactMap { credit -> Date? in
            guard credit.status == "available", let expiry = credit.expiresAt.flatMap(parseDate), expiry > fetchedAt else { return nil }
            return expiry
        }.sorted()
        return UsageSnapshot(identity: identity, plan: payload.planType, windows: windows,
                             bankedResets: count, applicableResets: validCount(payload.resetCredits?.applicableCount),
                             resetExpiries: expiries, fetchedAt: fetchedAt,
                             hasUnparsedWindows: (payload.rateLimit?.hasMalformedWindow ?? false) || windows.count < slots.compactMap(\.1).count)
    }

    private static func validCount(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct UsagePayload: Decodable {
        let accountID: String
        let planType: String?
        let rateLimit: LimitPayload?
        let resetCredits: CountPayload?
        enum CodingKeys: String, CodingKey {
            case accountID = "account_id", planType = "plan_type", rateLimit = "rate_limit", resetCredits = "rate_limit_reset_credits"
        }
    }
    private struct CountPayload: Decodable {
        let availableCount: Int?
        let applicableCount: Int?
        enum CodingKeys: String, CodingKey { case availableCount = "available_count", applicableCount = "applicable_available_count" }
    }
    private struct LimitPayload: Decodable {
        let primary: WindowPayload?
        let secondary: WindowPayload?
        let hasMalformedWindow: Bool
        enum CodingKeys: String, CodingKey { case primary = "primary_window", secondary = "secondary_window" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? values.decodeIfPresent(WindowPayload.self, forKey: .primary)
            secondary = try? values.decodeIfPresent(WindowPayload.self, forKey: .secondary)
            hasMalformedWindow = (values.contains(.primary) && (try? values.decodeNil(forKey: .primary)) == false && primary == nil)
                || (values.contains(.secondary) && (try? values.decodeNil(forKey: .secondary)) == false && secondary == nil)
        }
    }
    private struct WindowPayload: Decodable {
        let usedPercent: Double
        let duration: Double
        let resetAt: Double?
        let resetAfter: Double?
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent", duration = "limit_window_seconds", resetAt = "reset_at", resetAfter = "reset_after_seconds" }
    }
    private struct ResetPayload: Decodable {
        let availableCount: Int?
        let credits: [ResetCredit]?
        enum CodingKeys: String, CodingKey { case availableCount = "available_count", credits }
    }
    private struct ResetCredit: Decodable {
        let status: String?
        let expiresAt: String?
        enum CodingKeys: String, CodingKey { case status, expiresAt = "expires_at" }
    }
}
