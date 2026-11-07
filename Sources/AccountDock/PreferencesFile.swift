import Foundation
import DockCore

/// Reads preferences.json leniently and remembers what this version could not read, so a save never loses it.
/// A newer version may add a provider, a placement or a whole setting; an older copy of the app must still open
/// every other profile and write the unknown parts back unchanged.
struct PreferencesFile {
    var preferences = Preferences()
    /// Top-level values this version does not know or could not decode. Written back while the key is absent.
    var keptValues: [String: Any] = [:]
    /// The same per profile id.
    var keptProfileValues: [String: [String: Any]] = [:]
    /// Whole profile entries this version cannot use, such as one with an unknown provider. Written back unchanged.
    var keptProfiles: [Any] = []

    enum ReadError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The settings file is not valid JSON." }
    }

    /// Profile keys without which an entry cannot be used safely. A missing provider would turn it into a ChatGPT profile.
    static let requiredProfileKeys: Set<String> = ["id", "name", "color", "provider"]

    /// Throws only when the file is not a JSON object at all (truly corrupt).
    static func read(_ data: Data) throws -> PreferencesFile {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (root.removeValue(forKey: "profiles") ?? []) as? [Any] else { throw ReadError.unreadable }
        root["profiles"] = [Any]()
        guard let top = lenient(Preferences.self, root, defaults: ["scale": 1, "profiles": [Any]()]) else { throw ReadError.unreadable }
        var file = PreferencesFile(preferences: top.value)
        file.keptValues = top.dropped.merging(unknownKeys(root, encoded: top.value)) { dropped, _ in dropped }
        file.keptValues.removeValue(forKey: "profiles")
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let profile = lenient(Profile.self, object, required: requiredProfileKeys) else { file.keptProfiles.append(entry); continue }
            file.preferences.profiles.append(profile.value)
            let kept = profile.dropped.merging(unknownKeys(object, encoded: profile.value)) { dropped, _ in dropped }
            if !kept.isEmpty { file.keptProfileValues[profile.value.id] = kept }
        }
        return file
    }

    /// The file's bytes: this version's preferences plus everything it kept aside.
    func data(for preferences: Preferences) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        guard !keptValues.isEmpty || !keptProfileValues.isEmpty || !keptProfiles.isEmpty,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for (key, value) in keptValues where root[key] == nil { root[key] = value }
        var profiles = root["profiles"] as? [[String: Any]] ?? []
        for index in profiles.indices {
            guard let id = profiles[index]["id"] as? String, let kept = keptProfileValues[id] else { continue }
            for (key, value) in kept where profiles[index][key] == nil { profiles[index][key] = value }
        }
        let ids = Set(profiles.compactMap { $0["id"] as? String })
        // An entry whose id this version now uses for its own profile is not written twice.
        root["profiles"] = profiles + keptProfiles.filter { (($0 as? [String: Any])?["id"] as? String).map { !ids.contains($0) } ?? true }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Decodes `object`, leaving out each value that fails (an unknown enum value, a wrong type) until the rest decodes.
    /// A missing value with a default gets that default. Nil when a required key fails.
    static func lenient<T: Decodable>(_ type: T.Type, _ object: [String: Any], required: Set<String> = [], defaults: [String: Any] = [:]) -> (value: T, dropped: [String: Any])? {
        var object = object, dropped: [String: Any] = [:]
        for _ in 0...(object.count + defaults.count) {
            do {
                return (try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)), dropped)
            } catch let error as DecodingError {
                guard let key = error.topLevelKey, !required.contains(key) else { return nil }
                if let value = object.removeValue(forKey: key) { dropped[key] = value }
                else if let fallback = defaults[key] { object[key] = fallback }
                else { return nil }
            } catch { return nil }
        }
        return nil
    }

    /// Keys in the file that this version does not write back: settings it does not know. Explicit nulls are left out.
    static func unknownKeys<T: Encodable>(_ object: [String: Any], encoded value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let written = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object.filter { written[$0.key] == nil && !($0.value is NSNull) }
    }
}

private extension DecodingError {
    /// The first key on the path to the failing value, which is the value to leave out.
    var topLevelKey: String? {
        switch self {
        case .keyNotFound(let key, let context): return context.codingPath.first?.stringValue ?? key.stringValue
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): return context.codingPath.first?.stringValue
        @unknown default: return nil
        }
    }
}
