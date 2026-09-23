import Foundation
import DockCore

public enum ContextError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public struct ContextAccess: Codable, Equatable, Sendable {
    public var version = 1
    public var grants: [String: [String]] = [:]
    public init() {}
    public func allows(caller: String, source: String) -> Bool { grants[caller]?.contains(source) == true }
    public mutating func set(caller: String, source: String, allowed: Bool) {
        var sources = Set(grants[caller] ?? [])
        if allowed { sources.insert(source) } else { sources.remove(source) }
        grants[caller] = sources.sorted()
    }
}

public struct ContextProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String
    public let provider: ProfileProvider?
    public let projectPath: String?
    public var kind: ProfileProvider { provider ?? .codex }
    public init(_ profile: Profile) {
        id = profile.id; name = profile.name
        provider = profile.provider; projectPath = profile.projectPath
        let value = profile.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        alias = "@" + (value.isEmpty ? profile.id : value)
    }
    public func root(in home: URL) -> URL { home.appendingPathComponent(kind != .codex ? ".claude" : id == "default" ? ".codex" : ".codex-" + id) }
}

public struct ContextRegistry: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.resolvingSymlinksInPath().standardizedFileURL }
    public var directory: URL { home.appendingPathComponent("Library/Application Support/Account Dock/Context") }
    public var accessURL: URL { directory.appendingPathComponent("access.json") }
    public var helperURL: URL { directory.appendingPathComponent("ProfileDockContext") }

    public func profiles() throws -> [ContextProfile] {
        struct Preferences: Decodable { var profiles: [Profile]; var hiddenProfileIDs: [String]? }
        let url = home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json")
        let saved: Preferences
        if FileManager.default.fileExists(atPath: url.path) {
            saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        } else { saved = Preferences(profiles: [], hiddenProfileIDs: []) }
        let discovered = try ProfileCatalog.discover(home: home)
        let hidden = Set(saved.hiddenProfileIDs ?? [])
        // Saved profiles can have generated IDs and no launcher registry entry.
        let candidates = saved.profiles + discovered.filter { p in !saved.profiles.contains(where: { $0.id == p.id }) }
        var seen = Set<String>()
        return candidates.filter { $0.kind != .terminal && Profile.validID($0.id) && !hidden.contains($0.id) && seen.insert($0.id).inserted && FileManager.default.fileExists(atPath: $0.home(in: home).path) }.map(ContextProfile.init)
    }

    public func access() throws -> ContextAccess {
        guard FileManager.default.fileExists(atPath: accessURL.path) else { return ContextAccess() }
        let value = try JSONDecoder().decode(ContextAccess.self, from: Data(contentsOf: accessURL))
        guard value.version == 1 else { throw ContextError.message("This context configuration needs a newer ProfileDock.") }
        return value
    }

    public func save(_ access: ContextAccess) throws {
        guard access.version == 1 else { throw ContextError.message("Unsupported context configuration.") }
        try createPrivateDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(access).write(to: accessURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessURL.path)
    }

    public func createPrivateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func resolve(_ value: String, in profiles: [ContextProfile]) throws -> ContextProfile {
        if let exact = profiles.first(where: { $0.id == value }) { return exact }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = profiles.filter { $0.alias.lowercased() == key || String($0.alias.dropFirst()).lowercased() == key || $0.name.lowercased() == key }
        guard matches.count == 1, let profile = matches.first else {
            throw ContextError.message(matches.isEmpty ? "Unknown profile. Use list_profiles to see available profiles." : "That profile name is ambiguous. Use its exact profile ID.")
        }
        return profile
    }

    public func authorized(caller: String, sources: [String]) throws -> [ContextProfile] {
        let all = try profiles()
        guard all.contains(where: { $0.id == caller }) else { throw ContextError.message("The calling profile is no longer in ProfileDock.") }
        guard !sources.isEmpty, sources.count <= 8 else { throw ContextError.message("Choose between one and eight source profiles.") }
        let policy = try access()
        var seen = Set<String>()
        return try sources.map { try resolve($0, in: all) }.filter { seen.insert($0.id).inserted }.map { profile in
            guard profile.id == caller || policy.allows(caller: caller, source: profile.id) else { throw ContextError.message("Context from \(profile.name) is not enabled for this profile. Enable it in ProfileDock → Settings → Context access.") }
            let root = profile.root(in: home)
            guard root.resolvingSymlinksInPath().path == root.path else { throw ContextError.message("Linked profile folders are not supported for context sharing.") }
            return profile
        }
    }
}
