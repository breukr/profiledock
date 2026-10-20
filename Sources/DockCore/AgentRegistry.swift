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
    /// Lowercase fragments of a resolved install path that prove which tool a command belongs to,
    /// such as an npm package folder. They settle command names that several programs share.
    public let packageMarkers: [String]
    /// Command names other programs also use. They count only together with a package marker.
    public let ambiguousExecutables: [String]
    /// Install folders relative to the user home that a GUI app's short PATH misses.
    public let installDirectories: [String]
    /// The vendor's install command or page, shown when a profile's tool is missing.
    public let installHint: String?
    /// A desktop agent app that gets a tile on its own while it runs, using the existing sign-in.
    public let addsWhenRunning: Bool
    /// A non-secret status file in a separate account's user-data folder that says whether it is signed in.
    public let signInStatus: AgentSignInStatus?

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

/// One boolean in a status file the app writes for itself. Never a credential file.
public struct AgentSignInStatus: Sendable, Equatable {
    public let relativePath: String
    public let key: String
    public init(relativePath: String, key: String) { self.relativePath = relativePath; self.key = key }
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
             documentation: "https://code.claude.com/docs/en/desktop",
             packageMarkers: ["node_modules/@anthropic-ai/claude-code/", "/.local/share/claude/versions/"], installDirectories: [".claude/local"]),
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
             documentation: "https://developers.openai.com/codex",
             packageMarkers: ["node_modules/@openai/codex/", "/caskroom/codex/"]),
        tool(id: "grok-bot", name: "Grok Bot", bundleIdentifiers: ["com.anysphere.sand"], applicationNames: ["Grok Bot.app"],
             defaultConfigDirectory: ".grokbot", configMarkers: ["Library/Application Support/Grok Bot"],
             authNote: "The sign-in lives in the app's user-data folder, encrypted with the app's own Keychain key. With --user-data-dir the app also keeps its data root (normally ~/.grokbot) inside that folder.",
             isolation: .userDataDirectory, interface: .desktop, color: "8E8E93",
             documentation: "https://docs.x.ai/grok-bot",
             addsWhenRunning: true, signInStatus: AgentSignInStatus(relativePath: "desktop-status.json", key: "signedIn")),
        tool(id: "grok", name: "Grok Build", executables: ["grok"], configHomeEnvironment: "GROK_HOME", defaultConfigDirectory: ".grok",
             authNote: "xAI Grok Build keeps the grok login session in $GROK_HOME/auth.json. XAI_API_KEY is only a fallback after that session; ProfileDock does not set it.",
             isolation: .environmentDirectory(variable: "GROK_HOME"), interface: .terminal, color: "111111",
             documentation: "https://docs.x.ai/build/settings",
             detail: "This is for xAI's Grok Build CLI. The community grok-cli (grok-dev) uses the same command name but ignores GROK_HOME.",
             installDirectories: [".grok/bin"], installHint: "curl -fsSL https://x.ai/cli/install.sh | bash"),
        // The Account Dock folder is outside ~/.hermes and not named `profiles`, so Hermes does not fall back to the root auth.json.
        tool(id: "hermes", name: "Hermes", executables: ["hermes"], configHomeEnvironment: "HERMES_HOME", defaultConfigDirectory: ".hermes",
             authNote: "auth.json and .env inside HERMES_HOME. hermes -p selects a profile by setting HERMES_HOME. ProfileDock sets the variable itself and does not read .env.",
             isolation: .environmentDirectory(variable: "HERMES_HOME"), interface: .terminal, color: "7C5CBF",
             documentation: "https://hermes-agent.nousresearch.com/docs/user-guide/profiles",
             packageMarkers: ["/.hermes/hermes-agent/", "/site-packages/hermes_agent"], installHint: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"),
        tool(id: "gemini", name: "Gemini CLI", executables: ["gemini"], configHomeEnvironment: "GEMINI_CLI_HOME", defaultConfigDirectory: ".gemini",
             authNote: "oauth_creds.json under $GEMINI_CLI_HOME/.gemini by default. The opt-in encrypted storage (GEMINI_FORCE_ENCRYPTED_FILE_STORAGE) is one Keychain item, service gemini-cli-oauth, that ignores GEMINI_CLI_HOME.",
             isolation: .environmentDirectory(variable: "GEMINI_CLI_HOME"), interface: .terminal, color: "1A73E8",
             documentation: "https://geminicli.com/docs/cli/enterprise/",
             detail: "Leave Gemini's optional Keychain storage off: that setting keeps one login for the whole Mac.",
             packageMarkers: ["node_modules/@google/gemini-cli/", "/cellar/gemini-cli/"], installHint: "npm install -g @google/gemini-cli"),
        tool(id: "opencode", name: "OpenCode", executables: ["opencode"], configHomeEnvironment: "XDG_DATA_HOME",
             defaultConfigDirectory: ".local/share/opencode", configMarkers: [".config/opencode"],
             authNote: "auth.json in $XDG_DATA_HOME/opencode (later releases move it into opencode.db in the same folder). OPENCODE_CONFIG and OPENCODE_DB do not move the sign-in.",
             isolation: .environmentDirectory(variable: "XDG_DATA_HOME"), interface: .terminal, color: "3ECF8E",
             documentation: "https://opencode.ai/docs/cli/",
             detail: "Programs that OpenCode starts from this tab also see that data folder.",
             packageMarkers: ["node_modules/opencode-ai/", "/cellar/opencode/"], installDirectories: [".opencode/bin"], installHint: "brew install sst/tap/opencode"),
        tool(id: "copilot", name: "GitHub Copilot CLI", executables: ["copilot"], configHomeEnvironment: "COPILOT_HOME", defaultConfigDirectory: ".copilot",
             authNote: "OAuth token in the macOS Keychain under the service name copilot-cli. COPILOT_HOME moves settings, not that item. COPILOT_GITHUB_TOKEN takes precedence; ProfileDock does not set it.",
             isolation: .unsupported("The sign-in is one Keychain item for this Mac. Copilot CLI switches accounts itself with /user switch."),
             interface: .terminal, color: "24292F",
             documentation: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli",
             packageMarkers: ["node_modules/@github/copilot/"], installHint: "npm install -g @github/copilot"),
        tool(id: "aider", name: "Aider", executables: ["aider"], configMarkers: [".aider.conf.yml"],
             authNote: "API keys in .aider.conf.yml or an env file the user already has. ProfileDock does not create those files or store keys.",
             isolation: .unsupported("Aider has no signed-in account directory. Chat history stays in the git repository."),
             interface: .terminal, color: "14B8A6",
             documentation: "https://aider.chat/docs/config/aider_conf.html",
             packageMarkers: ["/pipx/venvs/aider-chat/", "/uv/tools/aider-chat/"], installHint: "python -m pip install aider-install && aider-install"),
        tool(id: "amp", name: "Amp", executables: ["amp"], configMarkers: [".amp", ".config/amp"],
             authNote: "Amp keeps its saved accounts for this Mac user and changes the active one with amp account switch. AMP_API_KEY overrides per shell; ProfileDock does not set it.",
             isolation: .unsupported("Amp switches accounts itself with amp account switch, and every new terminal follows the active account."),
             interface: .terminal, color: "7C3AED",
             documentation: "https://ampcode.com/docs/cli",
             packageMarkers: ["node_modules/@sourcegraph/amp/", "/.amp/bin/"], installDirectories: [".amp/bin"], installHint: "curl -fsSL https://ampcode.com/install.sh | bash"),
        tool(id: "cursor-cli", name: "Cursor CLI", executables: ["cursor-agent", "agent"], configHomeEnvironment: "CURSOR_CONFIG_DIR",
             configMarkers: [".cursor/cli-config.json", ".local/share/cursor-agent"],
             authNote: "agent login stores its token in the macOS Keychain. CURSOR_CONFIG_DIR moves only cli-config.json. ProfileDock does not set CURSOR_API_KEY.",
             isolation: .unsupported("The browser login is kept in the Keychain, not in a folder ProfileDock can split."),
             interface: .terminal, color: "000000",
             documentation: "https://cursor.com/docs/cli/reference/configuration",
             packageMarkers: ["/.local/share/cursor-agent/"], ambiguousExecutables: ["agent"], installHint: "curl https://cursor.com/install -fsS | bash"),
        tool(id: "cursor", name: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], applicationNames: ["Cursor.app"],
             defaultConfigDirectory: ".cursor",
             authNote: "The desktop account is the one signed in to Cursor. Docs do not provide a macOS user-data directory for a second account.",
             isolation: .unsupported("ProfileDock opens the installed Cursor app and does not pass a separate data directory."),
             interface: .desktop, color: "8E8E93",
             documentation: "https://cursor.com/docs/enterprise/endpoint-security",
             addsWhenRunning: true),
        tool(id: "windsurf", name: "Windsurf / Devin", bundleIdentifiers: ["com.exafunction.windsurf"],
             applicationNames: ["Windsurf.app", "Devin.app"], defaultConfigDirectory: ".codeium/windsurf", configMarkers: [".devin"],
             authNote: "Login is the Devin or Windsurf account in the app, or an API key typed into its own settings. Package ids still use windsurf.",
             isolation: .unsupported("Devin Desktop has no documented config-directory variable, so ProfileDock only opens the installed app."),
             interface: .desktop, color: "0EA5E9",
             documentation: "https://docs.windsurf.com/windsurf/getting-started",
             addsWhenRunning: true),
        tool(id: "goose", name: "Goose", executables: ["goose"], defaultConfigDirectory: ".config/goose",
             authNote: "Provider keys are in the system keyring (service goose, account secrets). GOOSE_PATH_ROOT moves config and data but not that item. ProfileDock does not read either.",
             isolation: .unsupported("Goose keeps provider keys in one Keychain item for this Mac. Moving its config folder does not move that item."),
             interface: .terminal, color: "E8A317",
             documentation: "https://block.github.io/goose/",
             installHint: "brew install block-goose-cli"),
        // Added 2026-10-20 from vendor docs and source; see docs/AGENT-COVERAGE.md.
        tool(id: "pi", name: "pi", executables: ["pi"], configHomeEnvironment: "PI_CODING_AGENT_DIR", defaultConfigDirectory: ".pi/agent",
             authNote: "auth.json in the agent folder (PI_CODING_AGENT_DIR, normally ~/.pi/agent) holds OAuth sessions and API keys as a plain file.",
             isolation: .environmentDirectory(variable: "PI_CODING_AGENT_DIR"), interface: .terminal, color: "4B5563",
             documentation: "https://pi.dev",
             packageMarkers: ["node_modules/@earendil-works/pi-coding-agent/", "node_modules/@mariozechner/pi-coding-agent/", "/.pi/agent/install/"],
             ambiguousExecutables: ["pi"], installHint: "npm install -g @earendil-works/pi-coding-agent"),
        tool(id: "qwen", name: "Qwen Code", executables: ["qwen"], configHomeEnvironment: "QWEN_HOME", defaultConfigDirectory: ".qwen",
             authNote: "oauth_creds.json inside QWEN_HOME (normally ~/.qwen). QWEN_RUNTIME_DIR moves only temporary files.",
             isolation: .environmentDirectory(variable: "QWEN_HOME"), interface: .terminal, color: "615CED",
             documentation: "https://github.com/QwenLM/qwen-code",
             packageMarkers: ["node_modules/@qwen-code/qwen-code/"], installHint: "npm install -g @qwen-code/qwen-code"),
        tool(id: "crush", name: "Crush", executables: ["crush"], configHomeEnvironment: "CRUSH_GLOBAL_DATA",
             defaultConfigDirectory: ".local/share/crush", configMarkers: [".config/crush"],
             authNote: "Provider keys and OAuth sessions are written to crush.json in the data folder (CRUSH_GLOBAL_DATA). CRUSH_GLOBAL_CONFIG moves preferences only.",
             isolation: .environmentDirectory(variable: "CRUSH_GLOBAL_DATA"), interface: .terminal, color: "6B50FF",
             documentation: "https://github.com/charmbracelet/crush",
             packageMarkers: ["node_modules/@charmland/crush/", "/cellar/crush/"], installHint: "brew install charmbracelet/tap/crush"),
        tool(id: "kilo", name: "Kilo Code CLI", executables: ["kilo", "kilocode"], configHomeEnvironment: "XDG_DATA_HOME",
             defaultConfigDirectory: ".local/share/kilo", configMarkers: [".config/kilo"],
             authNote: "auth.json in $XDG_DATA_HOME/kilo. KILO_CONFIG_DIR moves settings only. Kilo is built on OpenCode and stores data the same way.",
             isolation: .environmentDirectory(variable: "XDG_DATA_HOME"), interface: .terminal, color: "F8F675",
             documentation: "https://kilo.ai/docs/cli",
             detail: "Programs that Kilo starts from this tab also see that data folder.",
             packageMarkers: ["node_modules/@kilocode/cli/", "/cellar/kilo/"], installHint: "npm install -g @kilocode/cli"),
        tool(id: "cline", name: "Cline CLI", executables: ["cline"], configHomeEnvironment: "CLINE_DIR", defaultConfigDirectory: ".cline",
             authNote: "Provider settings and sign-in in data/settings/providers.json under CLINE_DIR (normally ~/.cline). The Cline IDE extension reads the same folder.",
             isolation: .environmentDirectory(variable: "CLINE_DIR"), interface: .terminal, color: "5A5A5A",
             documentation: "https://docs.cline.bot/cline-cli/overview",
             packageMarkers: ["node_modules/cline/"], installHint: "npm install -g cline"),
        tool(id: "continue", name: "Continue CLI", executables: ["cn"], configHomeEnvironment: "CONTINUE_GLOBAL_DIR", defaultConfigDirectory: ".continue",
             authNote: "auth.json in CONTINUE_GLOBAL_DIR (normally ~/.continue), which the Continue IDE extensions also use.",
             isolation: .environmentDirectory(variable: "CONTINUE_GLOBAL_DIR"), interface: .terminal, color: "1C1C1C",
             documentation: "https://docs.continue.dev/cli/overview",
             packageMarkers: ["node_modules/@continuedev/cli/"], ambiguousExecutables: ["cn"], installHint: "npm install -g @continuedev/cli"),
        tool(id: "openhands", name: "OpenHands CLI", executables: ["openhands"], configHomeEnvironment: "OPENHANDS_PERSISTENCE_DIR", defaultConfigDirectory: ".openhands",
             authNote: "agent_settings.json (model key) and cloud/api_key.txt in OPENHANDS_PERSISTENCE_DIR (normally ~/.openhands).",
             isolation: .environmentDirectory(variable: "OPENHANDS_PERSISTENCE_DIR"), interface: .terminal, color: "C9B974",
             documentation: "https://docs.openhands.dev/openhands/usage/cli/installation",
             packageMarkers: ["/uv/tools/openhands/", "/pipx/venvs/openhands/"], installHint: "uv tool install openhands --python 3.12"),
        tool(id: "vibe", name: "Mistral Vibe", executables: ["vibe"], configHomeEnvironment: "VIBE_HOME", defaultConfigDirectory: ".vibe",
             authNote: "API key in .env inside VIBE_HOME (normally ~/.vibe). ProfileDock does not read that file.",
             isolation: .environmentDirectory(variable: "VIBE_HOME"), interface: .terminal, color: "FA500F",
             documentation: "https://github.com/mistralai/mistral-vibe",
             packageMarkers: ["/uv/tools/mistral-vibe/", "/pipx/venvs/mistral-vibe/", "/site-packages/vibe/"], ambiguousExecutables: ["vibe"],
             installHint: "uv tool install mistral-vibe"),
        tool(id: "kimi", name: "Kimi Code", executables: ["kimi"], configHomeEnvironment: "KIMI_CODE_HOME", defaultConfigDirectory: ".kimi-code",
             authNote: "Credentials in credentials/ inside KIMI_CODE_HOME (normally ~/.kimi-code).",
             isolation: .environmentDirectory(variable: "KIMI_CODE_HOME"), interface: .terminal, color: "1F6FEB",
             documentation: "https://github.com/MoonshotAI/kimi-code",
             detail: "This is Moonshot's Kimi Code. The archived kimi-cli uses the same command and its own ~/.kimi folder.",
             packageMarkers: ["/.kimi-code/", "node_modules/@moonshot-ai/kimi-code/", "/cellar/kimi-code/"], ambiguousExecutables: ["kimi"],
             installDirectories: [".kimi-code/bin"], installHint: "npm install -g @moonshot-ai/kimi-code"),
        tool(id: "droid", name: "Factory Droid", executables: ["droid"], defaultConfigDirectory: ".factory",
             authNote: "OAuth tokens in the system keyring, with a file fallback when FACTORY_DISABLE_KEYRING is set. FACTORY_API_KEY overrides per shell; ProfileDock does not set it.",
             isolation: .unsupported("The sign-in is one keyring item for this Mac, and Factory documents no folder setting that moves it."),
             interface: .terminal, color: "E2632A",
             documentation: "https://docs.factory.com/droid-cli/cli-reference",
             packageMarkers: ["/.local/bin/droid", "/caskroom/droid/", "node_modules/droid/"], ambiguousExecutables: ["droid"],
             installHint: "curl -fsSL https://app.factory.ai/cli | sh"),
        tool(id: "auggie", name: "Augment Auggie", executables: ["auggie"], defaultConfigDirectory: ".augment",
             authNote: "session.json in ~/.augment, per third-party sources; the CLI is closed source. AUGMENT_SESSION_AUTH overrides per shell; ProfileDock does not set it.",
             isolation: .unsupported("Augment documents a cache-folder flag but not that it moves the sign-in."),
             interface: .terminal, color: "1A1A1A",
             documentation: "https://docs.augmentcode.com/cli/overview",
             packageMarkers: ["node_modules/@augmentcode/auggie/"], installHint: "npm install -g @augmentcode/auggie"),
        tool(id: "codebuff", name: "Codebuff", executables: ["codebuff"], defaultConfigDirectory: ".config/manicode",
             authNote: "credentials.json in ~/.config/manicode.",
             isolation: .unsupported("Its folder setting is undocumented outside the source and not used by every code path."),
             interface: .terminal, color: "00C853",
             documentation: "https://www.codebuff.com/docs",
             packageMarkers: ["node_modules/codebuff/"], installHint: "npm install -g codebuff"),
        tool(id: "junie", name: "Junie CLI", executables: ["junie"], defaultConfigDirectory: ".junie",
             authNote: "JetBrains Account sign-in. JUNIE_HOME moves ~/.junie, but where the sign-in is kept is not documented.",
             isolation: .unsupported("JetBrains does not document whether JUNIE_HOME moves the sign-in."),
             interface: .terminal, color: "47E54B",
             documentation: "https://www.jetbrains.com/help/junie/junie-cli.html",
             packageMarkers: ["node_modules/@jetbrains/junie/"], installHint: "npm install -g @jetbrains/junie"),
        tool(id: "antigravity-cli", name: "Antigravity CLI", executables: ["agy"], defaultConfigDirectory: ".gemini/antigravity-cli",
             authNote: "Credentials in the macOS Keychain, per Google's docs. GEMINI_API_KEY and AGY_ADC_AUTH are other sign-in methods; ProfileDock does not set them.",
             isolation: .unsupported("The sign-in is in the Keychain for this Mac."),
             interface: .terminal, color: "3279F9",
             documentation: "https://antigravity.google/docs/install",
             installHint: "curl -fsSL https://antigravity.google/cli/install.sh | bash"),
        tool(id: "kiro-cli", name: "Kiro CLI", executables: ["kiro-cli"], defaultConfigDirectory: "Library/Application Support/kiro-cli", configMarkers: [".kiro"],
             authNote: "Version 2 keeps its sign-in in a database in ~/Library/Application Support/kiro-cli. Version 3 moves it with KIRO_HOME.",
             isolation: .unsupported("Only the version 3 preview documents a folder setting for the sign-in."),
             interface: .terminal, color: "7138CC",
             documentation: "https://kiro.dev/docs/cli/",
             installHint: "curl -fsSL https://cli.kiro.dev/install | bash"),
        tool(id: "t3code", name: "T3 Code", bundleIdentifiers: ["com.t3tools.t3code"],
             applicationNames: ["T3 Code.app", "T3 Code (Beta).app", "T3 Code (Alpha).app", "T3 Code (Nightly).app"],
             defaultConfigDirectory: ".t3", configMarkers: ["Library/Application Support/t3code-v2"],
             authNote: "T3 Code drives Claude Code, Codex, OpenCode and other CLIs through their own sign-ins. Its optional own session is in ~/.t3/userdata.",
             isolation: .unsupported("T3 Code uses the sign-ins of the coding CLIs it drives. Give those CLIs separate accounts instead."),
             interface: .desktop, color: "1E1E1E",
             documentation: "https://github.com/pingdotgg/t3code", addsWhenRunning: true),
        tool(id: "conductor", name: "Conductor", bundleIdentifiers: ["com.conductor.app"], applicationNames: ["Conductor.app"],
             configMarkers: ["Library/Application Support/com.conductor.app"],
             authNote: "Conductor uses the Claude Code and Codex sign-ins already on this Mac, plus its own account.",
             isolation: .unsupported("Conductor uses the shared Claude Code and Codex sign-ins."),
             interface: .desktop, color: "2B2B2B",
             documentation: "https://docs.conductor.build", addsWhenRunning: true),
        tool(id: "antigravity", name: "Antigravity", bundleIdentifiers: ["com.google.antigravity"], applicationNames: ["Antigravity.app"],
             defaultConfigDirectory: ".antigravity", configMarkers: ["Library/Application Support/Antigravity"],
             authNote: "The Google sign-in is in the app's user-data folder, encrypted with the app's Keychain key. Agent files in ~/.gemini/antigravity are shared.",
             isolation: .unsupported("A separate data folder has not been confirmed to keep a separate Google sign-in yet."),
             interface: .desktop, color: "3279F9",
             documentation: "https://antigravity.google/docs", addsWhenRunning: true),
        tool(id: "kiro", name: "Kiro", bundleIdentifiers: ["dev.kiro.desktop"], applicationNames: ["Kiro.app"],
             configMarkers: ["Library/Application Support/Kiro"],
             authNote: "Kiro's sign-in appears to use the shared AWS SSO cache in ~/.aws/sso/cache, outside any app folder.",
             isolation: .unsupported("The sign-in is not kept in a folder ProfileDock can split."),
             interface: .desktop, color: "7138CC",
             documentation: "https://kiro.dev/docs/", addsWhenRunning: true),
        tool(id: "trae", name: "Trae", bundleIdentifiers: ["com.trae.app"], applicationNames: ["Trae.app"],
             defaultConfigDirectory: ".trae", configMarkers: ["Library/Application Support/Trae"],
             authNote: "The Trae account signed in to the app.",
             isolation: .unsupported("ProfileDock has not verified a separate data folder for Trae."),
             interface: .desktop, color: "FF4D4F",
             documentation: "https://docs.trae.ai", addsWhenRunning: true),
        tool(id: "zed", name: "Zed", bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"], applicationNames: ["Zed.app", "Zed Preview.app"],
             defaultConfigDirectory: ".config/zed", configMarkers: ["Library/Application Support/Zed"],
             authNote: "The Zed sign-in is a Keychain item for this Mac. --user-data-dir moves Zed's data but not that item.",
             isolation: .unsupported("The sign-in is one Keychain item for this Mac."),
             interface: .desktop, color: "084CCF",
             documentation: "https://zed.dev/docs/ai/overview"),
        tool(id: "warp", name: "Warp", bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"], applicationNames: ["Warp.app", "WarpPreview.app"],
             defaultConfigDirectory: ".warp",
             authNote: "The Warp sign-in is in the macOS Keychain. WARP_API_KEY is for headless use; ProfileDock does not set it.",
             isolation: .unsupported("Warp's data-profile setting only works in development builds."),
             interface: .desktop, color: "01A4FF",
             documentation: "https://docs.warp.dev")
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
        documentation: String, detail: String? = nil, packageMarkers: [String] = [], ambiguousExecutables: [String] = [],
        installDirectories: [String] = [], installHint: String? = nil, addsWhenRunning: Bool = false, signInStatus: AgentSignInStatus? = nil
    ) -> AgentTool {
        AgentTool(id: id, name: name, executables: executables, bundleIdentifiers: bundleIdentifiers, applicationNames: applicationNames,
                  configHomeEnvironment: configHomeEnvironment, defaultConfigDirectory: defaultConfigDirectory, configMarkers: configMarkers,
                  authNote: authNote, isolation: isolation, interface: interface, legacy: legacy, color: color, documentation: documentation, detail: detail,
                  packageMarkers: packageMarkers, ambiguousExecutables: ambiguousExecutables, installDirectories: installDirectories,
                  installHint: installHint, addsWhenRunning: addsWhenRunning, signInStatus: signInStatus)
    }
}

public enum AgentEvidence: String, Sendable, Equatable, CaseIterable {
    case executable, application, config
}

public struct AgentApplication: Sendable, Equatable {
    public var path: String
    public var bundleIdentifier: String?
    public var name: String
    public var version: String?
    public init(path: String, bundleIdentifier: String?, name: String, version: String? = nil) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
    }
}

/// Facts a scan already gathered. Matching them does not read credential files.
public struct AgentScanInput: Sendable, Equatable {
    public var homePath: String
    public var pathDirectories: [String]
    public var existingPaths: Set<String>
    public var applications: [AgentApplication]
    /// Symlink targets of the executables that were found, for package markers. Empty in older callers.
    public var resolvedPaths: [String: String]
    public init(homePath: String, pathDirectories: [String], existingPaths: Set<String>, applications: [AgentApplication], resolvedPaths: [String: String] = [:]) {
        self.homePath = homePath
        self.pathDirectories = pathDirectories
        self.existingPaths = existingPaths
        self.applications = applications
        self.resolvedPaths = resolvedPaths
    }
}

public struct InstalledAgent: Sendable, Equatable, Identifiable {
    public var id: String { tool.id }
    public var tool: AgentTool
    public var executablePath: String?
    public var applicationPath: String?
    public var configPath: String?
    public var evidence: [AgentEvidence]
    /// Every copy of the app that was found, preferred copy first.
    public var applications: [AgentApplication] = []
    /// A command or app that can run. A config folder alone only shows the tool was used before.
    public var isInstalled: Bool { executablePath != nil || applicationPath != nil }
    public init(tool: AgentTool, executablePath: String?, applicationPath: String?, configPath: String?, evidence: [AgentEvidence], applications: [AgentApplication] = []) {
        self.tool = tool; self.executablePath = executablePath; self.applicationPath = applicationPath
        self.configPath = configPath; self.evidence = evidence; self.applications = applications
    }
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

    /// Fixed install folders that a GUI app's PATH misses: Homebrew, user bins, and the global bins of
    /// npm prefixes, Bun, Volta, pnpm, Yarn, Deno, Go, Cargo and the shims of mise and asdf.
    static let userBins = [".local/bin", "bin", ".cargo/bin", ".bun/bin", ".npm-global/bin", ".npm-packages/bin", ".volta/bin",
                           ".local/share/mise/shims", ".asdf/shims", "Library/pnpm", ".local/share/pnpm", ".yarn/bin",
                           ".config/yarn/global/node_modules/.bin", ".deno/bin", "go/bin", ".pyenv/shims", ".rbenv/shims"]
    /// Version folders whose `bin` holds global npm commands: nvm, fnm, mise and asdf installs. Newest version first.
    static let versionRoots: [(root: String, suffix: String)] = [
        (".nvm/versions/node", "bin"), ("Library/Application Support/fnm/node-versions", "installation/bin"),
        (".local/share/fnm/node-versions", "installation/bin"), (".local/share/mise/installs/node", "bin"),
        (".asdf/installs/nodejs", "bin"), (".local/share/mise/installs/bun", "bin")
    ]

    /// PATH plus the locations installers actually use when a GUI app has a short PATH.
    public static func directories(home: URL, path: String, tools: [AgentTool] = AgentRegistry.tools, fileManager: FileManager = .default) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let toolBins = tools.flatMap(\.installDirectories)
        var extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (userBins + toolBins).map { child(home.path, $0) }
        for (root, suffix) in versionRoots {
            let folder = child(home.path, root)
            guard let versions = try? fileManager.contentsOfDirectory(atPath: folder) else { continue }
            let sorted = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            extras += sorted.prefix(12).map { child(folder, $0 + "/" + suffix) }
        }
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
                guard input.existingPaths.contains(path) else { return nil }
                // A shared command name counts only when its install path proves the tool.
                guard tool.ambiguousExecutables.contains(name) else { return path }
                let resolved = (input.resolvedPaths[path] ?? path).lowercased()
                return tool.packageMarkers.contains { resolved.contains($0) || path.lowercased().contains($0) } ? path : nil
            }.first
        }.first
        let copies = AgentApplications.ordered(input.applications.filter { matches(tool, $0) }, home: input.homePath)
        let application = copies.first
        let relatives = [tool.defaultConfigDirectory].filter { !$0.isEmpty } + tool.configMarkers
        let config = relatives.lazy.map { AgentPaths.child(input.homePath, $0) }.first { input.existingPaths.contains($0) }
        var evidence: [AgentEvidence] = []
        if executable != nil { evidence.append(.executable) }
        if application != nil { evidence.append(.application) }
        if config != nil { evidence.append(.config) }
        guard !evidence.isEmpty else { return nil }
        return InstalledAgent(tool: tool, executablePath: executable, applicationPath: application?.path, configPath: config, evidence: evidence, applications: copies)
    }

    static func matches(_ tool: AgentTool, _ application: AgentApplication) -> Bool {
        if let bundle = application.bundleIdentifier { return tool.bundleIdentifiers.contains(bundle) }
        let filename = URL(fileURLWithPath: application.path).lastPathComponent
        return tool.applicationNames.contains(filename) || tool.applicationNames.contains(application.name + ".app")
    }

    /// Basename match for a foreground process, without arguments. Prefer `AgentIdentity.tool(launch:)`.
    public static func foregroundTool(executablePath: String, tools: [AgentTool] = AgentRegistry.tools) -> AgentTool? {
        AgentIdentity.tool(launch: AgentProcessLaunch(executable: executablePath, arguments: []), tools: tools, resolve: { $0 })
    }
}

/// Picks one copy when an app was renamed, duplicated, or left in the Trash or a mounted installer.
public enum AgentApplications {
    public static func excluded(_ path: String) -> Bool {
        ["/.Trash/", "/AppTranslocation/", "/Account Dock/", "/ProfileDock Dock Apps/", "/ProfileDock Launchers/", "/DerivedData/", "/Volumes/", ".app/Contents/"]
            .contains { path.contains($0) }
    }

    /// /Applications first, then ~/Applications, then anything else; the newest version wins within each.
    public static func ordered(_ applications: [AgentApplication], home: String) -> [AgentApplication] {
        func rank(_ path: String) -> Int {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if parent == "/Applications" { return 0 }
            if parent == AgentPaths.child(home, "Applications") { return 1 }
            if path.hasPrefix("/Applications/") || path.hasPrefix(AgentPaths.child(home, "Applications") + "/") { return 2 }
            return 3
        }
        var seen = Set<String>()
        return applications.filter { !excluded($0.path) && seen.insert(AgentPaths.normalize($0.path)).inserted }.sorted { left, right in
            let (a, b) = (rank(left.path), rank(right.path))
            if a != b { return a < b }
            let order = (left.version ?? "").compare(right.version ?? "", options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
            return left.path < right.path
        }
    }
}

public enum AgentProbe {
    /// File existence only. Applications come from the caller (Launch Services in the app), or from `applicationRoots` in tests.
    public static func scan(home: URL, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", applications: [AgentApplication] = [],
                            applicationRoots: [URL]? = nil, tools: [AgentTool] = AgentRegistry.tools, fileManager: FileManager = .default) -> AgentScanInput {
        let home = home.standardizedFileURL
        let directories = AgentPaths.directories(home: home, path: path, tools: tools, fileManager: fileManager)
        var existing = Set<String>()
        var resolved: [String: String] = [:]
        for directory in directories {
            for tool in tools {
                for name in tool.executables {
                    let candidate = AgentPaths.join(directory, name)
                    guard isExecutableFile(candidate, fileManager: fileManager) else { continue }
                    existing.insert(candidate)
                    let target = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                    if target != candidate { resolved[candidate] = target }
                }
            }
        }
        for tool in tools {
            for relative in [tool.defaultConfigDirectory].filter({ !$0.isEmpty }) + tool.configMarkers {
                let candidate = AgentPaths.child(home.path, relative)
                if fileManager.fileExists(atPath: candidate) { existing.insert(candidate) }
            }
        }
        let found = applications + (applicationRoots ?? []).flatMap { readApplications(in: $0, fileManager: fileManager) }
        for application in found { existing.insert(AgentPaths.normalize(application.path)) }
        return AgentScanInput(homePath: home.path, pathDirectories: directories, existingPaths: existing, applications: found, resolvedPaths: resolved)
    }

    /// The binary for one tool, without scanning applications. Nil when it is not in a known location;
    /// a Terminal login shell may still find it on the user's own PATH.
    public static func executable(for tool: AgentTool, home: URL, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", fileManager: FileManager = .default) -> String? {
        let input = scan(home: home, path: path, tools: [tool], fileManager: fileManager)
        return AgentDetector.installed(tool, in: input)?.executablePath
    }

    /// Reads one boolean from the app's own status file, capped in size. Nil when it is missing or unclear.
    public static func signedIn(_ status: AgentSignInStatus, userData: URL, fileManager: FileManager = .default) -> Bool? {
        let file = userData.appendingPathComponent(status.relativePath)
        guard let size = (try? fileManager.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue < 65_536,
              let data = fileManager.contents(atPath: file.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[status.key] as? Bool
    }

    static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && fileManager.isExecutableFile(atPath: path)
    }

    public static func readApplications(in root: URL, fileManager: FileManager = .default) -> [AgentApplication] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".app") }.sorted().compactMap { readApplication(root.appendingPathComponent($0), fileManager: fileManager) }
    }

    /// Info.plist only.
    public static func readApplication(_ app: URL, fileManager: FileManager = .default) -> AgentApplication? {
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: app.path, isDirectory: &directory), directory.boolValue else { return nil }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let values = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let bundle = values?["CFBundleIdentifier"] as? String
        let title = (values?["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
        return AgentApplication(path: app.standardizedFileURL.path, bundleIdentifier: bundle, name: title, version: values?["CFBundleShortVersionString"] as? String)
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
    /// `searchPath` goes in front of PATH, for a script whose `env node` must find the runtime it was installed with.
    public static func plan(profile: Profile, userHome: URL, project: String, executable: String, searchPath: String? = nil) -> AgentLaunchPlan? {
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
        guard let shell = shellCommand(project: project, environment: environment, executable: executable, searchPath: searchPath) else { return nil }
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

    public static func shellCommand(project: String, environment: [String: String], executable: String, searchPath: String? = nil) -> String? {
        guard project.hasPrefix("/"), !project.contains("\0"), !project.contains("\n") else { return nil }
        guard let executable = quotedExecutable(executable) else { return nil }
        var prefix = "cd -- " + ClaudeBridgeSettings.shellQuote(project)
        if let searchPath {
            guard searchPath.hasPrefix("/"), !searchPath.contains("\0"), !searchPath.contains("\n"), !searchPath.contains(":") else { return nil }
            prefix += " && PATH=" + ClaudeBridgeSettings.shellQuote(searchPath) + ":\"$PATH\""
        }
        guard !environment.isEmpty else { return executable.isEmpty ? nil : prefix + " && " + executable }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil,
                  let value = environment[key], !value.contains("\0"), !value.contains("\n") else { return nil }
            return key + "=" + ClaudeBridgeSettings.shellQuote(value)
        }
        guard assignments.count == environment.count else { return nil }
        return prefix + " && " + assignments.joined(separator: " ") + " " + executable
    }

    /// The folder of an npm or Bun install made by nvm, fnm, mise, asdf or Volta, whose own runtime sits beside the command.
    /// Nil for other installs, which keep the user's PATH as it is.
    public static func runtimeDirectory(for executable: String, fileManager: FileManager = .default) -> String? {
        guard executable.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        guard ["/.nvm/", "/fnm/", "/mise/installs/", "/.asdf/installs/", "/.volta/"].contains(where: { directory.contains($0) }) else { return nil }
        return ["node", "bun"].contains { fileManager.isExecutableFile(atPath: directory + "/" + $0) } ? directory : nil
    }

    public static func quotedExecutable(_ value: String) -> String? {
        if value.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil { return value }
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n") else { return nil }
        return ClaudeBridgeSettings.shellQuote(value)
    }
}
