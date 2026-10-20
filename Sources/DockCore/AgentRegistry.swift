import Foundation

/// One description of an agent tool. Adding a tool should mean adding one `AgentTool` below.
/// ProfileDock never reads or writes API keys, tokens, or credential files named here.
public struct AgentTool: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Foreground executable names, lowercase. The first is the command ProfileDock launches.
    public let executables: [String]
    public let bundleIdentifiers: [String]
    public let applicationNames: [String]
    /// Environment variable that relocates this tool's config, when it has one.
    public let configHomeEnvironment: String?
    /// Config directory relative to the user home. Empty when the tool has no directory of its own.
    public let defaultConfigDirectory: String
    /// Extra files or directories relative to the user home that show the tool has been used.
    public let configMarkers: [String]
    /// Where the vendor stores a sign-in. A description only — ProfileDock does not open it.
    public let authNote: String
    public let isolation: AgentIsolation
    public let interface: AgentInterface
    /// Claude and Codex keep their existing profile, launch, and usage code.
    public let legacy: Bool
    public let color: String
    public let documentation: String
    /// Extra sentence appended to the isolation notice.
    public let detail: String?

    public var launchesInTerminal: Bool { interface != .desktop && !executables.isEmpty }
    public var supportsIsolatedProfiles: Bool {
        switch isolation {
        case .environmentDirectory, .userDataDirectory: return true
        case .legacy, .unsupported: return false
        }
    }
    public var preferredExecutable: String? { executables.first }

    /// What a separate profile gets, or why there is none.
    public var accountNotice: String {
        switch isolation {
        case .legacy:
            return ""
        case .environmentDirectory(let variable):
            return Self.isolatedNotice(name: name, mechanism: "folder (\(variable))") + Self.detailSentence(detail)
        case .userDataDirectory:
            return "Opens its own \(name) window with a separate sign-in and app data in Account Dock. Both accounts can stay open at the same time. Sign in from \(name) the first time it opens. ProfileDock does not store the API key or token." + Self.detailSentence(detail)
        case .unsupported(let reason):
            return "Separate accounts aren't supported for \(name). ProfileDock can open it, and it keeps using the sign-in already on this Mac. \(reason)"
        }
    }

    /// A profile that uses the sign-in already on this Mac.
    public var sharedNotice: String {
        guard supportsIsolatedProfiles else { return accountNotice }
        return "Uses the \(name) sign-in already on this Mac, with its usual settings and history."
    }

    public var runningHelp: String {
        if supportsIsolatedProfiles {
            return "\(name) is running in this Terminal tab. A saved profile can keep another \(name) sign-in beside this one. ProfileDock does not store the API key or token."
        }
        return "\(name) is running in this Terminal tab. Separate accounts aren't supported for \(name). It uses the sign-in already on this Mac."
    }

    private static func isolatedNotice(name: String, mechanism: String) -> String {
        "This profile has its own \(name) \(mechanism) in Account Dock. Sign in from \(name) the first time it opens. ProfileDock does not store the API key or token."
    }
    private static func detailSentence(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " " + detail
    }
}

public enum AgentInterface: String, Sendable, Equatable {
    case terminal, desktop, both
}

public enum AgentIsolation: Sendable, Equatable {
    /// Existing Claude or Codex behavior. Do not launch these through the generic agent path.
    case legacy
    /// The variable is set to the profile directory under Account Dock.
    case environmentDirectory(variable: String)
    /// An Electron desktop app started as another instance with `--user-data-dir` inside that directory,
    /// the same way separate Claude Desktop accounts are opened.
    case userDataDirectory
    case unsupported(String)
}

public enum AgentRegistry {
    public static let tools: [AgentTool] = [
        tool(id: "claude", name: "Claude Code", executables: ["claude"],
             configHomeEnvironment: "CLAUDE_CONFIG_DIR", defaultConfigDirectory: ".claude",
             authNote: "Keychain item Claude Code-credentials for the shared sign-in. A separate Claude account keeps its own CLAUDE_CONFIG_DIR. ProfileDock does not write either credential.",
             isolation: .legacy, interface: .terminal, legacy: true, color: "C97B5D",
             documentation: "https://code.claude.com/docs/en/desktop"),
        tool(id: "claude-desktop", name: "Claude Desktop", bundleIdentifiers: ["com.anthropic.claudefordesktop"],
             applicationNames: ["Claude.app"], configHomeEnvironment: "CLAUDE_CONFIG_DIR", defaultConfigDirectory: ".claude",
             configMarkers: ["Library/Application Support/Claude"],
             authNote: "The Desktop sign-in lives in the app. Claude Code usage reads the Keychain and never refreshes it.",
             isolation: .legacy, interface: .desktop, legacy: true, color: "C97B5D",
             documentation: "https://code.claude.com/docs/en/desktop"),
        tool(id: "codex", name: "Codex", executables: ["codex"], bundleIdentifiers: ["com.openai.codex"],
             applicationNames: ["ChatGPT.app", "Codex.app"], configHomeEnvironment: "CODEX_HOME", defaultConfigDirectory: ".codex",
             configMarkers: ["Library/Application Support/Codex", "Library/Application Support/ChatGPT"],
             authNote: "ChatGPT session in <CODEX_HOME>/auth.json. The Codex CLI writes that file. ProfileDock does not copy the token.",
             isolation: .legacy, interface: .both, legacy: true, color: "202020",
             documentation: "https://developers.openai.com/codex"),
        tool(id: "grok-bot", name: "Grok Bot", bundleIdentifiers: ["com.anysphere.sand"], applicationNames: ["Grok Bot.app"],
             defaultConfigDirectory: ".grokbot", configMarkers: ["Library/Application Support/Grok Bot"],
             authNote: "The sign-in lives in the app's user-data folder, encrypted with the app's own Keychain key. With --user-data-dir the app also keeps its data root (normally ~/.grokbot) inside that folder.",
             isolation: .userDataDirectory, interface: .desktop, color: "8E8E93",
             documentation: "https://docs.x.ai/grok-bot"),
        tool(id: "grok", name: "Grok Build", executables: ["grok"], configHomeEnvironment: "GROK_HOME", defaultConfigDirectory: ".grok",
             authNote: "xAI Grok Build keeps the grok login session in $GROK_HOME/auth.json. XAI_API_KEY is only a fallback after that session; ProfileDock does not set it.",
             isolation: .environmentDirectory(variable: "GROK_HOME"), interface: .terminal, color: "111111",
             documentation: "https://docs.x.ai/build/settings",
             detail: "This is for xAI's Grok Build CLI. The community grok-cli (grok-dev) uses the same command name but ignores GROK_HOME."),
        // The Account Dock folder is outside ~/.hermes and not named `profiles`, so Hermes does not fall back to the root auth.json.
        tool(id: "hermes", name: "Hermes", executables: ["hermes"], configHomeEnvironment: "HERMES_HOME", defaultConfigDirectory: ".hermes",
             authNote: "auth.json and .env inside HERMES_HOME. hermes -p selects a profile by setting HERMES_HOME. ProfileDock sets the variable itself and does not read .env.",
             isolation: .environmentDirectory(variable: "HERMES_HOME"), interface: .terminal, color: "7C5CBF",
             documentation: "https://hermes-agent.nousresearch.com/docs/user-guide/profiles"),
        tool(id: "gemini", name: "Gemini CLI", executables: ["gemini"], configHomeEnvironment: "GEMINI_CLI_HOME", defaultConfigDirectory: ".gemini",
             authNote: "oauth_creds.json under $GEMINI_CLI_HOME/.gemini by default. The opt-in encrypted storage (GEMINI_FORCE_ENCRYPTED_FILE_STORAGE) is one Keychain item, service gemini-cli-oauth, that ignores GEMINI_CLI_HOME.",
             isolation: .environmentDirectory(variable: "GEMINI_CLI_HOME"), interface: .terminal, color: "1A73E8",
             documentation: "https://geminicli.com/docs/cli/enterprise/",
             detail: "Leave Gemini's optional Keychain storage off: that setting keeps one login for the whole Mac."),
        tool(id: "opencode", name: "OpenCode", executables: ["opencode"], configHomeEnvironment: "XDG_DATA_HOME",
             defaultConfigDirectory: ".local/share/opencode", configMarkers: [".config/opencode"],
             authNote: "auth.json in $XDG_DATA_HOME/opencode (later releases move it into opencode.db in the same folder). OPENCODE_CONFIG and OPENCODE_DB do not move the sign-in.",
             isolation: .environmentDirectory(variable: "XDG_DATA_HOME"), interface: .terminal, color: "3ECF8E",
             documentation: "https://opencode.ai/docs/cli/",
             detail: "Programs that OpenCode starts from this tab also see that data folder."),
        tool(id: "copilot", name: "GitHub Copilot CLI", executables: ["copilot"], configHomeEnvironment: "COPILOT_HOME", defaultConfigDirectory: ".copilot",
             authNote: "OAuth token in the macOS Keychain under the service name copilot-cli. COPILOT_HOME moves settings, not that item. COPILOT_GITHUB_TOKEN takes precedence; ProfileDock does not set it.",
             isolation: .unsupported("The sign-in is one Keychain item for this Mac. Copilot CLI switches accounts itself with /user switch."),
             interface: .terminal, color: "24292F",
             documentation: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli"),
        tool(id: "aider", name: "Aider", executables: ["aider"], configMarkers: [".aider.conf.yml"],
             authNote: "API keys in .aider.conf.yml or an env file the user already has. ProfileDock does not create those files or store keys.",
             isolation: .unsupported("Aider has no signed-in account directory. Chat history stays in the git repository."),
             interface: .terminal, color: "14B8A6",
             documentation: "https://aider.chat/docs/config/aider_conf.html"),
        tool(id: "amp", name: "Amp", executables: ["amp"], configMarkers: [".amp", ".config/amp"],
             authNote: "Amp keeps its saved accounts for this Mac user and changes the active one with amp account switch. AMP_API_KEY overrides per shell; ProfileDock does not set it.",
             isolation: .unsupported("Amp switches accounts itself with amp account switch, and every new terminal follows the active account."),
             interface: .terminal, color: "7C3AED",
             documentation: "https://ampcode.com/docs/cli"),
        tool(id: "cursor-cli", name: "Cursor CLI", executables: ["cursor-agent", "agent"], configHomeEnvironment: "CURSOR_CONFIG_DIR",
             configMarkers: [".cursor/cli-config.json", ".local/share/cursor-agent"],
             authNote: "agent login stores its token in the macOS Keychain. CURSOR_CONFIG_DIR moves only cli-config.json. ProfileDock does not set CURSOR_API_KEY.",
             isolation: .unsupported("The browser login is kept in the Keychain, not in a folder ProfileDock can split. The command `agent` is treated as Cursor CLI."),
             interface: .terminal, color: "000000",
             documentation: "https://cursor.com/docs/cli/reference/configuration"),
        tool(id: "cursor", name: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], applicationNames: ["Cursor.app"],
             defaultConfigDirectory: ".cursor",
             authNote: "The desktop account is the one signed in to Cursor. Docs do not provide a macOS user-data directory for a second account.",
             isolation: .unsupported("ProfileDock opens the installed Cursor app and does not pass a separate data directory."),
             interface: .desktop, color: "8E8E93",
             documentation: "https://cursor.com/docs/enterprise/endpoint-security"),
        tool(id: "windsurf", name: "Windsurf / Devin", bundleIdentifiers: ["com.exafunction.windsurf"],
             applicationNames: ["Windsurf.app", "Devin.app"], defaultConfigDirectory: ".codeium/windsurf", configMarkers: [".devin"],
             authNote: "Login is the Devin or Windsurf account in the app, or an API key typed into its own settings. Package ids still use windsurf.",
             isolation: .unsupported("Devin Desktop has no documented config-directory variable, so ProfileDock only opens the installed app."),
             interface: .desktop, color: "0EA5E9",
             documentation: "https://docs.windsurf.com/windsurf/getting-started"),
        tool(id: "goose", name: "Goose", executables: ["goose"], defaultConfigDirectory: ".config/goose",
             authNote: "Provider keys are in the system keyring (service goose, account secrets). GOOSE_PATH_ROOT moves config and data but not that item. ProfileDock does not read either.",
             isolation: .unsupported("Goose keeps provider keys in one Keychain item for this Mac. Moving its config folder does not move that item."),
             interface: .terminal, color: "E8A317",
             documentation: "https://block.github.io/goose/")
    ]

    public static var addable: [AgentTool] { tools.filter { !$0.legacy } }

    public static func tool(id: String) -> AgentTool? { tools.first { $0.id == id } }

    public static func tool(executable name: String) -> AgentTool? {
        let name = name.lowercased()
        return tools.first { $0.executables.contains(name) }
    }

    private static func tool(
        id: String, name: String, executables: [String] = [], bundleIdentifiers: [String] = [], applicationNames: [String] = [],
        configHomeEnvironment: String? = nil, defaultConfigDirectory: String = "", configMarkers: [String] = [],
        authNote: String, isolation: AgentIsolation, interface: AgentInterface, legacy: Bool = false, color: String,
        documentation: String, detail: String? = nil
    ) -> AgentTool {
        AgentTool(id: id, name: name, executables: executables, bundleIdentifiers: bundleIdentifiers, applicationNames: applicationNames,
                  configHomeEnvironment: configHomeEnvironment, defaultConfigDirectory: defaultConfigDirectory, configMarkers: configMarkers,
                  authNote: authNote, isolation: isolation, interface: interface, legacy: legacy, color: color, documentation: documentation, detail: detail)
    }
}

public enum AgentEvidence: String, Sendable, Equatable, CaseIterable {
    case executable, application, config
}

public struct AgentApplication: Sendable, Equatable {
    public var path: String
    public var bundleIdentifier: String?
    public var name: String
    public init(path: String, bundleIdentifier: String?, name: String) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Facts a scan already gathered. Matching them does not read credential files.
public struct AgentScanInput: Sendable, Equatable {
    public var homePath: String
    public var pathDirectories: [String]
    public var existingPaths: Set<String>
    public var applications: [AgentApplication]
    public init(homePath: String, pathDirectories: [String], existingPaths: Set<String>, applications: [AgentApplication]) {
        self.homePath = homePath
        self.pathDirectories = pathDirectories
        self.existingPaths = existingPaths
        self.applications = applications
    }
}

public struct InstalledAgent: Sendable, Equatable, Identifiable {
    public var id: String { tool.id }
    public var tool: AgentTool
    public var executablePath: String?
    public var applicationPath: String?
    public var configPath: String?
    public var evidence: [AgentEvidence]
}

public enum AgentPaths {
    public static func normalize(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public static func join(_ directory: String, _ name: String) -> String {
        let directory = directory == "/" ? "" : directory
        return normalize(directory + "/" + name)
    }

    public static func child(_ home: String, _ relative: String) -> String {
        relative.split(separator: "/").filter { !$0.isEmpty }.reduce(URL(fileURLWithPath: home)) { $0.appendingPathComponent(String($1)) }.standardizedFileURL.path
    }

    /// PATH plus the locations installers actually use when a GUI app has a short PATH.
    public static func directories(home: URL, path: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + [".local/bin", "bin", ".cargo/bin", ".grok/bin", ".amp/bin", ".opencode/bin", ".bun/bin", ".npm-global/bin", ".volta/bin"].map { home.appendingPathComponent($0).path }
        for directory in path.split(separator: ":").map(String.init) + extras where directory.hasPrefix("/") && seen.insert(normalize(directory)).inserted {
            result.append(normalize(directory))
        }
        return result
    }
}

public enum AgentDetector {
    public static func installed(_ input: AgentScanInput, tools: [AgentTool] = AgentRegistry.tools) -> [InstalledAgent] {
        tools.compactMap { installed($0, in: input) }
    }

    public static func installed(_ tool: AgentTool, in input: AgentScanInput) -> InstalledAgent? {
        let executable = tool.executables.lazy.compactMap { name in
            input.pathDirectories.lazy.compactMap { directory -> String? in
                let path = AgentPaths.join(directory, name)
                return input.existingPaths.contains(path) ? path : nil
            }.first
        }.first
        let application = input.applications.first { application in
            if let bundle = application.bundleIdentifier, tool.bundleIdentifiers.contains(bundle) { return true }
            let filename = URL(fileURLWithPath: application.path).lastPathComponent
            return tool.applicationNames.contains(filename) || tool.applicationNames.contains(application.name + ".app")
        }
        let relatives = [tool.defaultConfigDirectory].filter { !$0.isEmpty } + tool.configMarkers
        let config = relatives.lazy.map { AgentPaths.child(input.homePath, $0) }.first { input.existingPaths.contains($0) }
        var evidence: [AgentEvidence] = []
        if executable != nil { evidence.append(.executable) }
        if application != nil { evidence.append(.application) }
        if config != nil { evidence.append(.config) }
        guard !evidence.isEmpty else { return nil }
        return InstalledAgent(tool: tool, executablePath: executable, applicationPath: application?.path, configPath: config, evidence: evidence)
    }

    /// Basename match for a foreground process. `cursor-agent` and `agent` both mean Cursor CLI.
    public static func foregroundTool(executablePath: String, tools: [AgentTool] = AgentRegistry.tools) -> AgentTool? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return tools.first { $0.launchesInTerminal && $0.executables.contains(name) }
    }
}

public enum AgentProbe {
    public static func scan(home: URL, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", applicationRoots: [URL]? = nil, fileManager: FileManager = .default) -> AgentScanInput {
        let home = home.standardizedFileURL
        let directories = AgentPaths.directories(home: home, path: path)
        var existing = Set<String>()
        for directory in directories {
            for tool in AgentRegistry.tools {
                for name in tool.executables {
                    let candidate = AgentPaths.join(directory, name)
                    if isExecutableFile(candidate, fileManager: fileManager) { existing.insert(candidate) }
                }
            }
        }
        for tool in AgentRegistry.tools {
            for relative in [tool.defaultConfigDirectory].filter({ !$0.isEmpty }) + tool.configMarkers {
                let candidate = AgentPaths.child(home.path, relative)
                if fileManager.fileExists(atPath: candidate) { existing.insert(candidate) }
            }
        }
        let roots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let applications = roots.flatMap { readApplications(in: $0, fileManager: fileManager) }
        for application in applications { existing.insert(AgentPaths.normalize(application.path)) }
        return AgentScanInput(homePath: home.path, pathDirectories: directories, existingPaths: existing, applications: applications)
    }

    /// The binary for one tool, without scanning applications. Nil when it is not in a known location;
    /// a Terminal login shell may still find it on the user's own PATH.
    public static func executable(for tool: AgentTool, home: URL, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", fileManager: FileManager = .default) -> String? {
        let directories = AgentPaths.directories(home: home.standardizedFileURL, path: path)
        return tool.executables.lazy.compactMap { name in
            directories.lazy.map { AgentPaths.join($0, name) }.first { isExecutableFile($0, fileManager: fileManager) }
        }.first
    }

    private static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    private static func readApplications(in root: URL, fileManager: FileManager) -> [AgentApplication] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
            let app = root.appendingPathComponent(name)
            var directory: ObjCBool = false
            guard fileManager.fileExists(atPath: app.path, isDirectory: &directory), directory.boolValue else { return nil }
            let plist = app.appendingPathComponent("Contents/Info.plist")
            let values = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let bundle = values?["CFBundleIdentifier"] as? String
            let title = (values?["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
            return AgentApplication(path: app.standardizedFileURL.path, bundleIdentifier: bundle, name: title)
        }
    }
}

public struct AgentLaunchPlan: Sendable, Equatable {
    public var environment: [String: String]
    public var executable: String
    public var shellCommand: String
    public var bundleIdentifier: String?
    public var notice: String
    public var opensDesktopApp: Bool
}

public enum AgentProfiles {
    /// A saved launcher. A separate profile points the tool at an Account Dock companion folder and nothing else;
    /// otherwise it uses the sign-in already on this Mac.
    public static func make(tool: AgentTool, name: String, separate: Bool = true) -> Profile? {
        guard !tool.legacy, var profile = ProfileLaunch.newProfile(name: name) else { return nil }
        profile.provider = .agent
        profile.agentID = tool.id
        profile.color = tool.color
        // Desktop apps show their installed app icon with the profile color as a dot.
        profile.dockIconStyle = tool.launchesInTerminal || tool.bundleIdentifiers.isEmpty ? .initials : .dot
        profile.terminalAgent = tool.launchesInTerminal ? TerminalAgent(rawValue: tool.id) : nil
        profile.isolatedAgentHome = separate && tool.supportsIsolatedProfiles ? true : nil
        return profile
    }
}

public enum AgentLaunch {
    public static func plan(profile: Profile, userHome: URL, project: String, executable: String) -> AgentLaunchPlan? {
        guard profile.kind == .agent, let tool = profile.agentTool, !tool.legacy else { return nil }
        var environment: [String: String] = [:]
        if profile.usesIsolatedAgentHome {
            let directory = profile.home(in: userHome)
            switch tool.isolation {
            case .environmentDirectory(let variable):
                environment[variable] = directory.path
            case .legacy, .unsupported, .userDataDirectory:
                return nil
            }
        }
        guard let shell = shellCommand(project: project, environment: environment, executable: executable) else { return nil }
        return AgentLaunchPlan(environment: environment, executable: executable, shellCommand: shell,
                                bundleIdentifier: tool.bundleIdentifiers.first, notice: tool.accountNotice, opensDesktopApp: !tool.launchesInTerminal)
    }

    /// `open -n` starts another instance; its own user-data folder keeps the sign-in apart. Same shape as separate Claude accounts.
    public static func desktopArguments(profile: Profile, userHome: URL, application: URL) -> [String]? {
        guard let data = profile.agentUserDataDirectory(in: userHome), application.path.hasSuffix(".app") else { return nil }
        return ["-n", "-a", application.path, "--args", "--user-data-dir=\(data.path)"]
    }

    /// Same command Terminal already runs for Claude Code and Codex: `cd` then the executable name.
    public static func terminalCommand(project: String, agent: TerminalAgent?) -> String? {
        guard let agent else {
            guard project.hasPrefix("/"), !project.contains("\0"), !project.contains("\n") else { return nil }
            return "cd -- " + ClaudeBridgeSettings.shellQuote(project)
        }
        return shellCommand(project: project, environment: [:], executable: agent.launchExecutable)
    }

    public static func shellCommand(project: String, environment: [String: String], executable: String) -> String? {
        guard project.hasPrefix("/"), !project.contains("\0"), !project.contains("\n") else { return nil }
        guard let executable = quotedExecutable(executable) else { return nil }
        let prefix = "cd -- " + ClaudeBridgeSettings.shellQuote(project)
        guard !environment.isEmpty else { return executable.isEmpty ? nil : prefix + " && " + executable }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil,
                  let value = environment[key], !value.contains("\0"), !value.contains("\n") else { return nil }
            return key + "=" + ClaudeBridgeSettings.shellQuote(value)
        }
        guard assignments.count == environment.count else { return nil }
        return prefix + " && " + assignments.joined(separator: " ") + " " + executable
    }

    public static func quotedExecutable(_ value: String) -> String? {
        if value.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil { return value }
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n") else { return nil }
        return ClaudeBridgeSettings.shellQuote(value)
    }
}
