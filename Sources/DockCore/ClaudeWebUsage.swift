import Foundation
import CryptoKit

/// Reading Claude usage through a claude.ai web sign-in, the same organization usage endpoint the
/// claude.ai settings page uses (`/api/organizations/{id}/usage`). Pure parsing only; the request runs
/// inside ProfileDock's own signed-in web view. Shapes follow the public CodexBar Claude web fetcher.
public enum ClaudeWebUsage {
    public enum Outcome: Equatable, Sendable {
        /// No claude.ai connection was set up for this account.
        case notConnected
        /// The web session ended (401, 403 or a redirect to the login page).
        case signedOut
        /// The web sign-in belongs to another account than the tile's Claude app.
        case otherAccount
        case rateLimited
        /// Network trouble, a page still loading or an unexpected answer. Nothing definitive.
        case unavailable
        case reading(UsageSnapshot)
    }

    public struct Account: Equatable, Sendable {
        public let accountID: String
        /// Organizations that can chat, in claude.ai's own order.
        public let organizations: [String]
    }

    /// The identity digest the OAuth path computes for the same account and organization, so a tile keeps one
    /// identity whichever source answered.
    public static func identity(accountID: String, organizationID: String) -> String {
        SHA256.hash(data: Data("claude\n\(accountID)\n\(organizationID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Maps a non-200 answer. A status 0 is an opaque redirect (claude.ai sends signed-out requests to its login page).
    public static func failure(status: Int) -> Outcome {
        switch status {
        case 0, 401, 403: return .signedOut
        case 429: return .rateLimited
        default: return .unavailable
        }
    }

    /// `/api/account` gives the account uuid; `/api/organizations` lists organizations with capabilities.
    public static func account(account: Any?, organizations: Any?) -> Account? {
        guard let root = account as? [String: Any], let id = (root["uuid"] ?? root["account_uuid"]) as? String, UUID(uuidString: id) != nil,
              let list = organizations as? [[String: Any]] else { return nil }
        let valid = list.filter { ($0["uuid"] as? String).flatMap(UUID.init(uuidString:)) != nil }
        let chat = valid.filter { ($0["capabilities"] as? [String])?.contains("chat") ?? true }
        let ids = (chat.isEmpty ? valid : chat).compactMap { $0["uuid"] as? String }
        return ids.isEmpty ? nil : Account(accountID: id, organizations: ids)
    }

    /// The organization whose identity ProfileDock already verified wins; otherwise claude.ai's first chat organization.
    public static func organization(for account: Account, knownIdentity: String?) -> String? {
        if let knownIdentity, let match = account.organizations.first(where: { identity(accountID: account.accountID, organizationID: $0) == knownIdentity }) { return match }
        return account.organizations.first
    }

    /// The usage payload has the OAuth endpoint's shape (`five_hour`, `seven_day`, `cedar_ember`), plus per-model weeks.
    public static func snapshot(usage: Data, identity: String, plan: String?, fetchedAt: Date) throws -> UsageSnapshot {
        let parsed = try ClaudeUsageParser.parse(usage, identity: identity, plan: plan, fetchedAt: fetchedAt)
        return parsed.with(modelWindows: modelWindows(usage))
    }

    /// `seven_day_opus` and `seven_day_sonnet` when present. Optional: missing or malformed entries are skipped.
    public static func modelWindows(_ data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return ["seven_day_opus", "seven_day_sonnet"].compactMap { key in
            guard let value = root[key] as? [String: Any], let used = value["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite, used.doubleValue >= 0 else { return nil }
            let reset = (value["resets_at"] as? String).flatMap(date)
            return UsageWindow(id: key, duration: 604800, usedPercent: used.doubleValue, resetsAt: reset)
        }
    }

    private static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]; return parser.date(from: text)
    }
}
