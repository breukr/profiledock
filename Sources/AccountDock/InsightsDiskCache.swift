import Foundation
import CryptoKit
import DockCore

/// Rebuildable metadata only. File names are hashed; transcript lines and credentials never enter this format.
struct InsightsDiskCache: Codable {
    static let format = 1
    static let maximumSize = 64 * 1024 * 1024
    var version = Self.format
    var pricing = InsightPricing.checkedOn
    var updated: Date
    var warnings: [String: String]
    var files: [String: Record]
    var claudeSamples: [InsightSample]?
    var claudePricing: String?

    struct Record: Codable {
        var inode: UInt64
        var modified: Date
        var offset: UInt64
        var size: UInt64
        var fingerprint: String?
        var parser: InsightRolloutParser.Checkpoint
    }

    static func location(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/nl.breukr.profiledock/insights-v1.json")
    }

    static func key(profile: String, file: URL, home: URL) -> String {
        let relative = file.path.hasPrefix(home.path + "/") ? String(file.path.dropFirst(home.path.count + 1)) : file.path
        return SHA256.hash(data: Data((profile + ":" + relative).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(home: URL, now: Date) -> Self? {
        let url = location(home: home)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumSize,
              let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Self.self, from: data),
              cache.version == format, cache.pricing == InsightPricing.checkedOn,
              cache.updated <= now.addingTimeInterval(300), now.timeIntervalSince(cache.updated) < 31 * 86400,
              cache.files.count <= 100_000,
              (cache.claudeSamples?.count ?? 0) <= 100_000,
              (cache.claudeSamples ?? []).allSatisfy({ $0.tokens.valid && Profile.validID($0.profileID) && $0.id.count <= 512 && $0.sessionID.count <= 160 && ($0.estimatedCost.map { $0.isFinite && $0 >= 0 } ?? true) }),
              cache.files.allSatisfy({ key, file in
                  key.count == 64 && file.offset <= file.size && file.fingerprint?.count == 64 && file.parser.valid
              }) else { return nil }
        return cache
    }

    static func save(_ cache: Self, home: URL) throws {
        let url = location(home: home), fm = FileManager.default
        let data = try JSONEncoder().encode(cache)
        guard data.count <= maximumSize else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        // Create the staging file privately before writing; the final rename is atomic.
        let stage = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        guard fm.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        defer { try? fm.removeItem(at: stage) }
        let handle = try FileHandle(forWritingTo: stage)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: stage) }
        else { try fm.moveItem(at: stage, to: url) }
    }
}
