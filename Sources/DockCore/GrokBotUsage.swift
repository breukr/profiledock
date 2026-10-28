import Foundation

/// Grok Bot's own weekly usage reading, from the cache its usage menu keeps on disk. ProfileDock never uses
/// Grok Bot's sign-in, which the app encrypts with its own Keychain key. The cache format is Grok Bot's internal
/// one, so anything unexpected reads as unknown, never as zero.
public enum GrokBotUsage {
    public static let toolID = "grok-bot"

    /// The app's data folder: a separate account's own folder, otherwise Grok Bot's shared one. Nil for other tiles.
    public static func dataDirectory(for profile: Profile, home: URL) -> URL? {
        guard profile.kind == .agent, profile.agentID == toolID else { return nil }
        return profile.agentUserDataDirectory(in: home) ?? home.appendingPathComponent("Library/Application Support/Grok Bot")
    }

    /// The signed-in account's weekly reading. Nil when there is no account, no cache, or the reading has expired,
    /// predates the weekly reset or is not recognized.
    public static func snapshot(in folder: URL, now: Date = Date()) -> UsageSnapshot? {
        let store = folder.appendingPathComponent("sand-client-persistence")
        guard let slot = entry(store, key: "sand.client.slice.client-meta.account-slot"), slot["schemaVersion"] as? Int == 1,
              let account = slot["value"] as? String, !account.isEmpty, account.count <= 256,
              let encoded = account.addingPercentEncoding(withAllowedCharacters: uriComponent),
              let cache = entry(store, key: "sand.client.slice.account.\(encoded).weekly-usage.cache") else { return nil }
        return parse(cache, account: account, now: now)
    }

    static func parse(_ root: [String: Any], account: String, now: Date) -> UsageSnapshot? {
        guard root["schemaVersion"] as? Int == 2, let value = root["value"] as? [String: Any], value["kind"] as? String == "present",
              let reading = value["reading"] as? [String: Any], let usage = reading["usage"] as? [String: Any],
              let used = number(usage["percentUsed"]), used >= 0,
              let readAt = number(reading["readAtMs"]), readAt > 0 else { return nil }
        // Grok Bot itself stops trusting a reading after this moment.
        if let expires = number(value["expiresAtMs"]), expires / 1000 <= now.timeIntervalSince1970 { return nil }
        var resetsAt: Date?
        if let raw = usage["nextResetMs"], !(raw is NSNull) {
            guard let reset = number(raw), reset > 0 else { return nil }
            // A reading from before the weekly reset no longer describes this week.
            guard reset / 1000 > now.timeIntervalSince1970 else { return nil }
            resetsAt = Date(timeIntervalSince1970: reset / 1000)
        }
        // percentUsed is on a 0 to 100 scale: Grok Bot clamps it to that range and shows it rounded as "N% used".
        let window = UsageWindow(id: "grok_week", duration: 604800, usedPercent: min(used, 100), resetsAt: resetsAt)
        return UsageSnapshot(identity: "grok-bot:" + account, plan: usage["unifiedPlanName"] as? String, windows: [window],
                             bankedResets: nil, applicableResets: nil, resetExpiries: nil, fetchedAt: Date(timeIntervalSince1970: readAt / 1000))
    }

    /// Grok Bot names each entry's file after the lowercase, unpadded base32 of its key.
    public static func fileName(key: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var name = "", buffer = 0, bits = 0
        for byte in Data(key.utf8) {
            buffer = buffer << 8 | Int(byte); bits += 8
            while bits >= 5 { name.append(alphabet[buffer >> (bits - 5) & 31]); bits -= 5 }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { name.append(alphabet[buffer << (5 - bits) & 31]) }
        return name + ".blob"
    }

    /// Account ids appear in keys the way JavaScript's encodeURIComponent writes them.
    private static let uriComponent = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// A regular file, not followed through a link, read up to 64 KB.
    private static func entry(_ store: URL, key: String) -> [String: Any]? {
        let descriptor = open(store.appendingPathComponent(fileName(key: key)).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 65_536 else { return nil }
        let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readData(ofLength: 65_536)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
