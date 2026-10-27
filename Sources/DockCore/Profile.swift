import Foundation

public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var iconFilename: String?
    public var iconIsTile: Bool?
    public var applicationPath: String?
    public var provider: ProfileProvider?
    public var projectPath: String?
    public var discoveredTerminal: Bool?
    public var terminalTTY: String?
    public var terminalWindowID: Int?
    public var terminalProcessStarted: Double?
    public var terminalAgent: TerminalAgent?
    /// Registry id when this profile launches a tool other than the original Claude and Codex providers.
    public var agentID: String?
    /// True only for a registry tool whose own directory can hold a separate sign-in.
    public var isolatedAgentHome: Bool?
    public var claudeSessionID: String?
    /// A Claude Desktop entry with its own app data and Claude Code configuration, so it can stay signed in to another account.
    public var separateClaudeAccount: Bool?
    /// Hidden profiles keep their app, sign-in and history; only the strip, shortcuts and menu skip them.
    public var hiddenFromStrip: Bool?
    /// Added by ProfileDock because the app was running. Always the existing sign-in.
    public var addedAutomatically: Bool?
    /// The app that owns a discovered session outside Terminal.app (its bundle id), or `tmux` / `screen`.
    public var terminalHost: String?
    /// The user chose Open Anyway: their own shell finds this terminal tool outside the usual install folders.
    public var opensByCommandName: Bool?
    public var kind: ProfileProvider { provider ?? .codex }
    public var usesSeparateClaudeAccount: Bool { kind == .claude && separateClaudeAccount == true }
    public var agentTool: AgentTool? {
        if let agentID, let tool = AgentRegistry.tool(id: agentID) { return tool }
        return terminalAgent?.tool
    }
    public var usesIsolatedAgentHome: Bool { kind == .agent && isolatedAgentHome == true && agentTool?.supportsIsolatedProfiles == true }
    /// Saved agent profiles stay in the main strip. Once one is bound to a tab, that tab is still recognized.
    public var tracksTerminalWindow: Bool { kind.usesTerminal || (kind == .agent && agentTool?.launchesInTerminal == true && terminalTTY != nil) }
    public var isShownInStrip: Bool { hiddenFromStrip != true }
    /// Finder shortcut title. Claude and Codex keep the names they already use.
    public var shortcutTitle: String {
        if kind == .codex { return "ChatGPT" }
        if kind == .agent, let name = agentTool?.name { return name }
        return kind.label
    }
    public var listDetail: String {
        if kind == .agent, let tool = agentTool { return usesIsolatedAgentHome ? "\(tool.name) · separate account" : "\(tool.name) · shared sign-in" }
        if kind == .terminal, let tool = terminalAgent?.tool, !tool.legacy { return tool.name }
        return kind.label
    }
    public var tileCaption: String {
        if kind == .claudeCode { return "Claude Code" }
        if kind == .agent { return usesIsolatedAgentHome ? "Separate account" : "Shared sign-in" }
        if kind == .terminal, let tool = terminalAgent?.tool, !tool.legacy { return tool.name }
        return kind.label
    }
    public var accountCaption: String {
        if kind == .codex { return "Your sign-in and conversation history belong to this profile." }
        if kind == .agent, let tool = agentTool { return usesIsolatedAgentHome ? tool.accountNotice : tool.sharedNotice }
        if kind == .terminal, let tool = terminalAgent?.tool, !tool.legacy { return tool.runningHelp }
        return "This entry uses your existing app and sign-in."
    }
    public var launcherPath: String?
    /// Opt-in, locally re-signed app. applicationPath continues to identify the signed source.
    public var dockApplicationPath: String?
    public var dockIconStyle: DockIconStyle?
    public var dockIconText: String?

    /// Older profiles already had uploaded artwork before icon styles were introduced.
    public var profileIconStyle: DockIconStyle { dockIconStyle ?? (iconFilename == nil ? .initials : .image) }

    public var dockLetters: String {
        let custom = dockIconText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? initials : String(custom.prefix(3)).uppercased()
    }

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
        if kind != .codex { return userHome.appendingPathComponent("Library/Application Support/Account Dock/Companions/\(id)") }
        return userHome.appendingPathComponent(id == "default" ? ".codex" : ".codex-\(id)")
    }

    /// Claude Code honours CLAUDE_CONFIG_DIR for settings, history and its own sign-in. Nil means the shared ~/.claude.
    public func claudeConfigDirectory(in userHome: URL) -> URL? {
        usesSeparateClaudeAccount ? home(in: userHome).appendingPathComponent("claude-config") : nil
    }

    /// The exact CLAUDE_CONFIG_DIR string ProfileDock passes; Claude Code derives its Keychain item from it.
    public func claudeConfigPath(in userHome: URL) -> String? { claudeConfigDirectory(in: userHome)?.path }

    public func claudeUserDataDirectory(in userHome: URL) -> URL? {
        usesSeparateClaudeAccount ? home(in: userHome).appendingPathComponent("electron-user-data") : nil
    }

    /// A separate desktop-agent account opened with `--user-data-dir`. Nil means the app's own shared folder.
    public func agentUserDataDirectory(in userHome: URL) -> URL? {
        guard usesIsolatedAgentHome, agentTool?.isolation == .userDataDirectory else { return nil }
        return home(in: userHome).appendingPathComponent("electron-user-data")
    }

    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]*$", options: .regularExpression) != nil
    }
}

public enum DockIconStyle: String, Codable, CaseIterable, Sendable {
    case dot, initials, image, chatgpt
    public var label: String {
        switch self { case .dot: return "Colored dot"; case .initials: return "Initials"; case .image: return "Custom image"; case .chatgpt: return "ChatGPT logo" }
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
    public static func arguments(from data: Data) -> [String]? { launch(from: data)?.arguments }

    /// The kernel's executable path and argv from KERN_PROCARGS2. Decoding stops before the environment.
    public static func launch(from data: Data) -> AgentProcessLaunch? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }
        let count = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard count > 0 && count < 8192 else { return nil }
        var cursor = 4
        guard let executableEnd = bytes[cursor...].firstIndex(of: 0),
              let executable = String(bytes: bytes[cursor..<executableEnd], encoding: .utf8) else { return nil }
        cursor = executableEnd + 1
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            result.append(argument)
            cursor = end + 1
        }
        return AgentProcessLaunch(executable: executable, arguments: result)
    }

    /// nil: no user-data argument. .some(nil): an argument that cannot identify a profile.
    public static func userDataPath(_ arguments: [String]) -> String?? {
        var userDataPath: String?
        for (index, argument) in arguments.enumerated().dropFirst() {
            if argument.hasPrefix("--user-data-dir=") {
                userDataPath = String(argument.dropFirst("--user-data-dir=".count))
            } else if argument == "--user-data-dir" {
                guard index + 1 < arguments.count else { return .some(nil) }
                userDataPath = arguments[index + 1]
            }
        }
        guard let path = userDataPath else { return nil }
        guard path.hasPrefix("/") else { return .some(nil) }
        return .some(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    public static func profileID(arguments: [String], profiles: [Profile], home: URL) -> String? {
        guard let executable = arguments.first, ["ChatGPT", "Codex"].contains(URL(fileURLWithPath: executable).lastPathComponent) else { return nil }
        if let path = userDataPath(arguments) {
            guard let normalized = path else { return nil }
            for profile in profiles where profile.id != "default" && profile.kind == .codex {
                if normalized == profile.home(in: home).appendingPathComponent("electron-user-data").standardizedFileURL.path { return profile.id }
            }
            let stockPaths = ["Library/Application Support/Codex", "Library/Application Support/ChatGPT"].map { home.appendingPathComponent($0).path }
            return stockPaths.contains(normalized) && profiles.contains(where: { $0.id == "default" }) ? "default" : nil
        }
        return profiles.contains(where: { $0.id == "default" }) ? "default" : nil
    }

    /// Separate Claude accounts are identified only by their exact user-data folder; everything else belongs to the shared sign-in.
    public static func claudeProfileID(arguments: [String], profiles: [Profile], home: URL) -> String? {
        guard let executable = arguments.first, URL(fileURLWithPath: executable).lastPathComponent == "Claude" else { return nil }
        let shared = profiles.first { $0.kind == .claude && !$0.usesSeparateClaudeAccount }?.id
        guard let path = userDataPath(arguments) else { return shared }
        guard let normalized = path else { return nil }
        if let profile = profiles.first(where: { $0.claudeUserDataDirectory(in: home)?.standardizedFileURL.path == normalized }) { return profile.id }
        return normalized == home.appendingPathComponent("Library/Application Support/Claude").standardizedFileURL.path ? shared : nil
    }

    /// A desktop agent instance belongs to the separate profile whose exact user-data folder it was given.
    /// Without that argument it is the shared sign-in; any other folder is not ours.
    public static func agentProfileID(tool: AgentTool, arguments: [String], profiles: [Profile], home: URL) -> String? {
        let candidates = profiles.filter { $0.kind == .agent && $0.agentID == tool.id }
        let shared = candidates.first { !$0.usesIsolatedAgentHome }?.id
        guard let path = userDataPath(arguments) else { return shared }
        guard let normalized = path else { return nil }
        return candidates.first { $0.agentUserDataDirectory(in: home)?.standardizedFileURL.path == normalized }?.id
    }
}
