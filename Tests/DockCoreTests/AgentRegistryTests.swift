import XCTest
@testable import DockCore

final class AgentRegistryTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/example")

    func testRegistryDescribesEachToolOnceAndIsolatesOnlyTheCleanHomes() {
        let ids = AgentRegistry.tools.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ["claude", "claude-desktop", "codex", "grok", "hermes", "gemini", "opencode", "copilot", "aider", "amp", "cursor-cli", "cursor", "windsurf", "goose"] {
            XCTAssertNotNil(AgentRegistry.tool(id: id), id)
        }
        XCTAssertEqual(AgentRegistry.tools.filter(\.supportsIsolatedProfiles).map(\.id), ["grok", "hermes", "gemini", "opencode"])
        var seen: [String] = []
        for tool in AgentRegistry.tools {
            XCTAssertFalse(tool.name.isEmpty)
            XCTAssertFalse(tool.authNote.isEmpty)
            XCTAssertTrue(tool.documentation.hasPrefix("https://"), tool.id)
            XCTAssertFalse(tool.authNote.contains("sk-"))
            for name in tool.executables {
                XCTAssertEqual(name, name.lowercased())
                XCTAssertFalse(seen.contains(name), name)
                seen.append(name)
                XCTAssertNotNil(AgentLaunch.quotedExecutable(name))
            }
        }
        XCTAssertEqual(AgentRegistry.tool(id: "grok")?.configHomeEnvironment, "GROK_HOME")
        XCTAssertEqual(AgentRegistry.tool(id: "hermes")?.configHomeEnvironment, "HERMES_HOME")
        XCTAssertEqual(AgentRegistry.tool(id: "gemini")?.configHomeEnvironment, "GEMINI_CLI_HOME")
        XCTAssertEqual(AgentRegistry.tool(id: "opencode")?.configHomeEnvironment, "OPENCODE_DB")
        XCTAssertEqual(AgentRegistry.tool(id: "grok")?.defaultConfigDirectory, ".grok")
        XCTAssertEqual(AgentRegistry.tool(id: "opencode")?.defaultConfigDirectory, ".local/share/opencode")
    }

    func testForegroundDetectionKeepsClaudeAndCodexAndAddsTheOtherClis() {
        let table = """
        ttys001 S+ /Users/fixture/.local/bin/claude
        ttys002 R+ /opt/bin/codex
        ttys012 S+ /opt/homebrew/bin/grok
        ttys013 S+ /Users/fixture/.local/bin/hermes
        ttys014 S+ gemini
        ttys015 S+ /usr/local/bin/opencode
        ttys016 S+ copilot
        ttys017 S+ /opt/bin/aider
        ttys018 S+ amp
        ttys019 S+ /Users/fixture/.local/bin/cursor-agent
        ttys020 S+ /Users/fixture/.local/bin/agent
        ttys021 S+ /Users/fixture/.local/bin/goose
        ttys022 S /opt/bin/grok
        ttys023 S+ /bin/zsh
        ttys024 S+ node
        """
        let found = TerminalAgent.processes(table)
        XCTAssertEqual(found["/dev/ttys001"], .claude)
        XCTAssertEqual(found["/dev/ttys002"], .codex)
        XCTAssertEqual(found["/dev/ttys012"]?.rawValue, "grok")
        XCTAssertEqual(found["/dev/ttys013"]?.rawValue, "hermes")
        XCTAssertEqual(found["/dev/ttys014"]?.rawValue, "gemini")
        XCTAssertEqual(found["/dev/ttys015"]?.rawValue, "opencode")
        XCTAssertEqual(found["/dev/ttys016"]?.rawValue, "copilot")
        XCTAssertEqual(found["/dev/ttys017"]?.rawValue, "aider")
        XCTAssertEqual(found["/dev/ttys018"]?.rawValue, "amp")
        XCTAssertEqual(found["/dev/ttys019"], found["/dev/ttys020"])
        XCTAssertEqual(found["/dev/ttys019"]?.rawValue, "cursor-cli")
        XCTAssertEqual(found["/dev/ttys021"]?.rawValue, "goose")
        XCTAssertNil(found["/dev/ttys022"])
        XCTAssertNil(found["/dev/ttys023"])
        XCTAssertNil(found["/dev/ttys024"])
        let original = """
        ttys001 S+ /Users/fixture/.local/bin/claude
        ttys002 R+ /opt/bin/codex
        ttys003 S+ /bin/zsh
        ttys004 S /opt/bin/claude
        ttys005 T+ /opt/bin/codex
        ?? S+ /Applications/Claude.app/Contents/MacOS/Claude
        ttys006 S+ /opt/bin/not-claude
        ttys007 Z+ /opt/bin/claude
        ttys008 S+ /Users/fixture/Folder With Spaces/claude
        ttys009  S+   claude
        ttys010  R+   codex
        ttys011  S+   node
        """
        XCTAssertEqual(TerminalAgent.processes(original), ["/dev/ttys001": .claude, "/dev/ttys002": .codex, "/dev/ttys008": .claude, "/dev/ttys009": .claude, "/dev/ttys010": .codex])
        XCTAssertEqual(TerminalAgent.claude.label, "Claude Code")
        XCTAssertEqual(TerminalAgent.codex.label, "Codex")
        XCTAssertEqual(TerminalAgent.claude.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(TerminalAgent.codex.bundleIdentifier, "com.openai.codex")
    }

    func testInstalledToolsMatchPathBundlesAndConfigDirectoriesWithoutReadingSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let app = root.appendingPathComponent("Applications/Cursor.app/Contents")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hermes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("grok"))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.todesktop.230313mzl4w4u92</string><key>CFBundleName</key><string>Cursor</string></dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let scan = AgentProbe.scan(home: root, path: bin.path, applicationRoots: [root.appendingPathComponent("Applications")])
        let installed = AgentDetector.installed(scan)
        let grok = try XCTUnwrap(installed.first { $0.id == "grok" })
        XCTAssertEqual(grok.evidence, [.executable])
        XCTAssertEqual(grok.executablePath, bin.appendingPathComponent("grok").standardizedFileURL.path)
        XCTAssertEqual(installed.first { $0.id == "hermes" }?.evidence, [.config])
        XCTAssertEqual(installed.first { $0.id == "cursor" }?.evidence, [.application])
        XCTAssertNil(installed.first { $0.id == "amp" })
        XCTAssertFalse(scan.existingPaths.contains { $0.hasSuffix("auth.json") || $0.hasSuffix("secrets.json") })

        let named = AgentScanInput(homePath: "/Users/example", pathDirectories: ["/usr/bin", "/opt/homebrew/bin"],
                                    existingPaths: ["/opt/homebrew/bin/copilot", "/Users/example/.gemini", "/Applications/Devin.app"],
                                    applications: [AgentApplication(path: "/Applications/Devin.app", bundleIdentifier: nil, name: "Devin")])
        let matched = AgentDetector.installed(named)
        XCTAssertEqual(matched.first { $0.id == "copilot" }?.executablePath, "/opt/homebrew/bin/copilot")
        XCTAssertEqual(matched.first { $0.id == "gemini" }?.evidence, [.config])
        XCTAssertEqual(matched.first { $0.id == "windsurf" }?.applicationPath, "/Applications/Devin.app")
        XCTAssertNil(matched.first { $0.id == "cursor" })
    }

    func testIsolatedLaunchesStayInsideAccountDockAndDoNotCarrySecrets() throws {
        let grok = try XCTUnwrap(AgentProfiles.make(tool: XCTUnwrap(AgentRegistry.tool(id: "grok")), name: "Work"))
        let plan = try XCTUnwrap(AgentLaunch.plan(profile: grok, userHome: home, project: "/Work/it's here", executable: "/opt/homebrew/bin/grok"))
        let directory = grok.home(in: home).path
        XCTAssertEqual(directory, "/Users/example/Library/Application Support/Account Dock/Companions/\(grok.id)")
        XCTAssertEqual(plan.environment, ["GROK_HOME": directory])
        XCTAssertFalse(directory.contains("/.grok"))
        XCTAssertEqual(plan.shellCommand, "cd -- '/Work/it'\\''s here' && GROK_HOME='\(directory)' '/opt/homebrew/bin/grok'")
        XCTAssertFalse(plan.shellCommand.contains("API_KEY"))
        XCTAssertFalse(plan.shellCommand.contains("TOKEN"))

        let hermes = try XCTUnwrap(AgentProfiles.make(tool: XCTUnwrap(AgentRegistry.tool(id: "hermes")), name: "Work"))
        XCTAssertEqual(AgentLaunch.plan(profile: hermes, userHome: home, project: "/Work", executable: "hermes")?.environment.keys.sorted(), ["HERMES_HOME"])

        let gemini = try XCTUnwrap(AgentProfiles.make(tool: XCTUnwrap(AgentRegistry.tool(id: "gemini")), name: "Work"))
        let geminiPlan = try XCTUnwrap(AgentLaunch.plan(profile: gemini, userHome: home, project: "/Work", executable: "gemini"))
        XCTAssertEqual(geminiPlan.environment.keys.sorted(), ["GEMINI_CLI_HOME"])
        XCTAssertFalse(geminiPlan.shellCommand.contains("GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"))
        XCTAssertTrue(gemini.accountCaption.contains("Keychain storage stays off"))

        let opencode = try XCTUnwrap(AgentProfiles.make(tool: XCTUnwrap(AgentRegistry.tool(id: "opencode")), name: "Work"))
        let database = try XCTUnwrap(AgentLaunch.plan(profile: opencode, userHome: home, project: "/Work", executable: "opencode")?.environment["OPENCODE_DB"])
        XCTAssertEqual(database, opencode.home(in: home).appendingPathComponent("opencode.db").path)
        XCTAssertFalse(database.contains(".local/share/opencode"))

        for id in ["copilot", "aider", "amp", "cursor-cli", "cursor", "windsurf", "goose"] {
            let tool = try XCTUnwrap(AgentRegistry.tool(id: id))
            let profile = try XCTUnwrap(AgentProfiles.make(tool: tool, name: "Work"))
            let launched = try XCTUnwrap(AgentLaunch.plan(profile: profile, userHome: home, project: "/Work", executable: tool.preferredExecutable ?? "unused"))
            XCTAssertEqual(launched.environment, [:], id)
            XCTAssertTrue(profile.accountCaption.contains("Separate accounts aren't supported for \(tool.name)"), id)
            XCTAssertEqual(launched.opensDesktopApp, !tool.launchesInTerminal)
        }
        XCTAssertNil(AgentProfiles.make(tool: try XCTUnwrap(AgentRegistry.tool(id: "codex")), name: "Work"))
        XCTAssertNil(AgentProfiles.make(tool: try XCTUnwrap(AgentRegistry.tool(id: "claude")), name: "Work"))
        let codex = Profile(id: "default", name: "Personal", color: "377CF6")
        XCTAssertNil(AgentLaunch.plan(profile: codex, userHome: home, project: "/Work", executable: "codex"))
        XCTAssertEqual(codex.home(in: home).path, "/Users/example/.codex")
        XCTAssertNil(AgentLaunch.shellCommand(project: "/tmp/a\nb", environment: [:], executable: "grok"))
    }

    func testExistingProfilesStillDecodeAndClaudeCommandsStayTheSame() throws {
        let agent = try JSONDecoder().decode(TerminalAgent.self, from: Data("\"claude\"".utf8))
        XCTAssertEqual(agent, .claude)
        let encoded = try JSONEncoder().encode(TerminalAgent.codex)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"codex\"")
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"default","name":"Personal","color":"abcdef"}"#.utf8))
        XCTAssertEqual(profile.kind, .codex)
        XCTAssertNil(profile.agentID)
        XCTAssertNil(profile.isolatedAgentHome)
        XCTAssertEqual(profile.home(in: URL(fileURLWithPath: "/fixture")).path, "/fixture/.codex")
        XCTAssertEqual(profile.accountCaption, "Your sign-in and conversation history belong to this profile.")
        XCTAssertEqual(AgentLaunch.terminalCommand(project: "/Work", agent: .claude), "cd -- '/Work' && claude")
        XCTAssertEqual(AgentLaunch.terminalCommand(project: "/Work", agent: .codex), "cd -- '/Work' && codex")
        XCTAssertEqual(AgentLaunch.terminalCommand(project: "/Work", agent: nil), "cd -- '/Work'")
        let made = try XCTUnwrap(AgentProfiles.make(tool: XCTUnwrap(AgentRegistry.tool(id: "grok")), name: "Work"))
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(made))
        XCTAssertEqual(decoded, made)
        XCTAssertEqual(decoded.kind, .agent)
        XCTAssertTrue(decoded.usesIsolatedAgentHome)
        XCTAssertEqual(decoded.listDetail, "Grok · separate account")
        XCTAssertEqual(decoded.shortcutTitle, "Grok")
        XCTAssertEqual(profile.shortcutTitle, "ChatGPT")
    }
}
