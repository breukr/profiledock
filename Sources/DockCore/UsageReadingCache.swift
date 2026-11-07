import Foundation

/// The last good usage reading per tile, plus sign-in reminder bookkeeping, kept on disk so a relaunch,
/// reboot or expired token never empties the bars. Stores readings and timestamps only, never tokens,
/// cookies or raw account ids: identities are already one-way SHA-256 digests (a hash cannot be turned
/// back into the account it came from), and anything else is dropped on load.
public final class UsageReadingCache {
    public struct Reading: Codable, Equatable, Sendable {
        public let identity: String
        public let snapshot: UsageSnapshot
    }
    /// Per connection: when ProfileDock last showed a sign-in reminder, and until when "Later" hides it.
    public struct Reminder: Codable, Equatable, Sendable {
        public var lastNudgedAt: Date?
        public var snoozedUntil: Date?
        public init(lastNudgedAt: Date? = nil, snoozedUntil: Date? = nil) { self.lastNudgedAt = lastNudgedAt; self.snoozedUntil = snoozedUntil }
        var isEmpty: Bool { lastNudgedAt == nil && snoozedUntil == nil }
    }
    private struct Contents: Codable {
        var version = 1
        var readings: [String: Reading] = [:]
        var reminders: [String: Reminder] = [:]
    }

    public let url: URL
    private var contents: Contents

    public init(url: URL) {
        self.url = url
        contents = Self.load(url)
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> UsageReadingCache {
        UsageReadingCache(url: home.appendingPathComponent("Library/Application Support/Account Dock/usage-cache.json"))
    }

    public func reading(for key: String) -> Reading? { contents.readings[key] }
    public var readingKeys: Set<String> { Set(contents.readings.keys) }
    public func reminder(for key: String) -> Reminder { contents.reminders[key] ?? Reminder() }
    public var reminderKeys: Set<String> { Set(contents.reminders.keys) }

    /// Saves a verified reading; a reading whose identity is not a digest is never written.
    public func store(_ snapshot: UsageSnapshot, for key: String) {
        guard Self.isDigest(snapshot.identity) else { return }
        let value = Reading(identity: snapshot.identity, snapshot: snapshot)
        guard contents.readings[key] != value else { return }
        contents.readings[key] = value
        save()
    }
    public func removeReading(for key: String) {
        guard contents.readings.removeValue(forKey: key) != nil else { return }
        save()
    }
    public func setReminder(_ reminder: Reminder, for key: String) {
        guard contents.reminders[key] ?? Reminder() != reminder else { return }
        contents.reminders[key] = reminder.isEmpty ? nil : reminder
        save()
    }
    /// Drops readings and reminders for tiles and connections that no longer exist.
    public func retain(readings: Set<String>, reminders: Set<String>) {
        let before = (contents.readings.count, contents.reminders.count)
        contents.readings = contents.readings.filter { readings.contains($0.key) }
        contents.reminders = contents.reminders.filter { reminders.contains($0.key) }
        if before != (contents.readings.count, contents.reminders.count) { save() }
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// A missing, unreadable, oversized or corrupt file reads as empty; the next save replaces it.
    private static func load(_ url: URL) -> Contents {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return Contents() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard var value = try? decoder.decode(Contents.self, from: data), value.version == 1 else { return Contents() }
        value.readings = value.readings.filter { isDigest($0.value.identity) && $0.value.snapshot.identity == $0.value.identity }
        return value
    }

    /// Atomic write (a temporary file renamed over the old one, so a crash never leaves half a file),
    /// readable only by this user (POSIX mode 0600).
    private func save() {
        guard let data = try? Self.encoder().encode(contents) else { return }
        let manager = FileManager.default, folder = url.deletingLastPathComponent()
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".usage-cache-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? manager.removeItem(at: temporary) }
    }
}
