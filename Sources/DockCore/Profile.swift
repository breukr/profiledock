import Foundation

public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var iconFilename: String?
    public var iconIsTile: Bool?
    public var applicationPath: String?
    public var launcherPath: String?
    /// Opt-in, locally re-signed app. applicationPath continues to identify the signed source.
    public var dockApplicationPath: String?

    public init(id: String, name: String, color: String, iconFilename: String? = nil, iconIsTile: Bool? = nil, applicationPath: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.iconFilename = iconFilename
        self.iconIsTile = iconIsTile
        self.applicationPath = applicationPath
    }

    public var initials: String {
        let parts = name.split(separator: " ")
        if parts.count > 1, let first = parts.first, let last = parts.last {
            return String(first.prefix(1) + last.prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    public func home(in userHome: URL) -> URL {
        userHome.appendingPathComponent(id == "default" ? ".codex" : ".codex-\(id)")
    }

    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]*$", options: .regularExpression) != nil
    }
}

public enum ProfileCatalog {
    // These are labels from the existing local launcher registry, not inferred login identities.
    public static func discover(home: URL) throws -> [Profile] {
        let fm = FileManager.default
        var profiles: [Profile] = []
        if fm.fileExists(atPath: home.appendingPathComponent(".codex").path) {
            profiles.append(Profile(id: "default", name: "Personal", color: "377CF6"))
        }
        let directory = home.appendingPathComponent(".config/codex-profile/launchers")
        if !fm.fileExists(atPath: directory.path) { return profiles }
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension == "state" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            guard lines.count >= 4, Profile.validID(lines[0]), file.deletingPathExtension().lastPathComponent == lines[0],
                  fm.fileExists(atPath: home.appendingPathComponent(".codex-\(lines[0])").path),
                  !profiles.contains(where: { $0.id == lines[0] }) else { continue }
            let name = lines[1].hasPrefix("ChatGPT ") ? String(lines[1].dropFirst(8)) : lines[1]
            let colors = ["teal": "009B87", "purple": "955CE5", "green": "339958", "blue": "377CF6", "orange": "D77620", "pink": "CA528B", "red": "D85252"]
            let fallback = "CA528B"
            profiles.append(Profile(id: lines[0], name: name, color: colors[lines[2]] ?? fallback))
        }
        return profiles
    }

    public static func merge(discovered: [Profile], saved: [Profile]) -> [Profile] {
        let ids = Set(discovered.map(\.id))
        var result: [Profile] = []
        for profile in saved where ids.contains(profile.id) && !result.contains(where: { $0.id == profile.id }) {
            result.append(profile)
        }
        return result + discovered.filter { candidate in !result.contains(where: { $0.id == candidate.id }) }
    }
}

public enum ProcessIdentity {
    /// Decode only argv from KERN_PROCARGS2. Never parse or expose environment entries.
    public static func arguments(from data: Data) -> [String]? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }
        let count = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard count > 0 && count < 8192 else { return nil }
        var cursor = 4
        guard let executableEnd = bytes[cursor...].firstIndex(of: 0) else { return nil }
        cursor = executableEnd + 1
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            result.append(argument)
            cursor = end + 1
        }
        return result
    }

    public static func profileID(arguments: [String], profiles: [Profile], home: URL) -> String? {
        guard let executable = arguments.first, ["ChatGPT", "Codex"].contains(URL(fileURLWithPath: executable).lastPathComponent) else { return nil }
        var userDataPath: String?
        for (index, argument) in arguments.enumerated().dropFirst() {
            if argument.hasPrefix("--user-data-dir=") {
                userDataPath = String(argument.dropFirst("--user-data-dir=".count))
            } else if argument == "--user-data-dir" {
                guard index + 1 < arguments.count else { return nil }
                userDataPath = arguments[index + 1]
            }
        }
        if let path = userDataPath {
            guard path.hasPrefix("/") else { return nil }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            for profile in profiles where profile.id != "default" {
                if normalized == profile.home(in: home).appendingPathComponent("electron-user-data").standardizedFileURL.path { return profile.id }
            }
            let stockPaths = ["Library/Application Support/Codex", "Library/Application Support/ChatGPT"].map { home.appendingPathComponent($0).path }
            return stockPaths.contains(normalized) && profiles.contains(where: { $0.id == "default" }) ? "default" : nil
        }
        return profiles.contains(where: { $0.id == "default" }) ? "default" : nil
    }
}
