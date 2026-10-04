import Foundation

public enum ProfileLaunch {
    public static func arguments(profile: Profile, home: URL, application: URL) -> [String] {
        if profile.id == "default" { return ["-n", "--env", "CODEX_HOME=\(profile.home(in: home).path)", "--env", "CODEX_ELECTRON_USER_DATA_PATH=", "-a", application.path] }
        let profileHome = profile.home(in: home)
        let data = profileHome.appendingPathComponent("electron-user-data").path
        return ["-n", "--env", "CODEX_HOME=\(profileHome.path)", "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(data)", "-a", application.path, "--args", "--user-data-dir=\(data)"]
    }

    /// `open -n` starts another Claude instance; its own user-data folder keeps the Desktop sign-in apart.
    public static func claudeArguments(profile: Profile, home: URL, application: URL) -> [String]? {
        guard let config = profile.claudeConfigDirectory(in: home), let data = profile.claudeUserDataDirectory(in: home) else { return nil }
        return ["-n", "--env", "CLAUDE_CONFIG_DIR=\(config.path)", "-a", application.path, "--args", "--user-data-dir=\(data.path)"]
    }

    public static func newProfile(name: String) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32 else { return nil }
        return Profile(id: "profile-" + UUID().uuidString.lowercased(), name: name, color: "377CF6")
    }
}

public struct AppUpdateGroup: Identifiable, Equatable, Sendable {
    public var id: String { application.path }
    public let application: URL
    public let profiles: [Profile]

    public static func make(profiles: [Profile], defaultApplication: URL?) -> [AppUpdateGroup] {
        let pairs = profiles.filter { $0.kind == .codex }.compactMap { profile -> (String, Profile)? in
            guard let path = profile.applicationPath ?? defaultApplication?.path else { return nil }
            return (URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path, profile)
        }
        return Dictionary(grouping: pairs, by: { $0.0 }).map { path, rows in
            AppUpdateGroup(application: URL(fileURLWithPath: path), profiles: rows.map(\.1))
        }.sorted { $0.id < $1.id }
    }
}
