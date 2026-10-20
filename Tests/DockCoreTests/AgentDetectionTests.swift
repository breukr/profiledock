import XCTest
@testable import DockCore

final class AgentDetectionTests: XCTestCase {
    private func fixture(_ id: String, executables: [String], markers: [String] = [], ambiguous: [String] = [], bundles: [String] = [],
                         interface: AgentInterface = .terminal, addsWhenRunning: Bool = false, isolation: AgentIsolation = .unsupported("Fixture")) -> AgentTool {
        AgentTool(id: id, name: id.capitalized, executables: executables, bundleIdentifiers: bundles, applicationNames: [], configHomeEnvironment: nil,
                  defaultConfigDirectory: "", configMarkers: [], authNote: "Fixture", isolation: isolation, interface: interface, legacy: false,
                  color: "000000", documentation: "https://example.com", detail: nil, packageMarkers: markers, ambiguousExecutables: ambiguous,
                  installDirectories: [], installHint: nil, addsWhenRunning: addsWhenRunning, signInStatus: nil, vendorInstalls: [])
    }
    private var tools: [AgentTool] {
        [fixture("pi", executables: ["pi"], markers: ["node_modules/@fixture/pi-agent/"], ambiguous: ["pi"]),
         fixture("cursor-cli", executables: ["cursor-agent", "agent"], markers: ["/cursor-agent/"], ambiguous: ["agent"]),
         fixture("gemini", executables: ["gemini"], markers: ["node_modules/@google/gemini-cli/"]),
         fixture("hermes", executables: ["hermes"], markers: ["/hermes-agent/"]),
         fixture("aider", executables: ["aider"]),
         fixture("claude", executables: ["claude"])]
    }
    private let links = [
        "/opt/homebrew/bin/pi": "/opt/homebrew/lib/node_modules/@fixture/pi-agent/dist/cli.js",
        "/Users/f/.local/bin/agent": "/Users/f/.local/share/cursor-agent/versions/1/cursor-agent",
        "/Users/f/.nvm/versions/node/v22.1.0/bin/gemini": "/Users/f/.nvm/versions/node/v22.1.0/lib/node_modules/@google/gemini-cli/dist/index.js"
    ]
    private func resolve(_ path: String) -> String { links[path] ?? path }
    private func identify(_ executable: String, _ arguments: [String] = []) -> String? {
        AgentIdentity.tool(launch: AgentProcessLaunch(executable: executable, arguments: arguments), tools: tools, resolve: resolve)?.id
    }

    func testScriptClisAreIdentifiedFromTheirArgvScriptNotTheRuntime() {
        XCTAssertEqual(identify("/opt/homebrew/bin/node", ["node", "/Users/f/.nvm/versions/node/v22.1.0/bin/gemini", "--yolo"]), "gemini")
        XCTAssertEqual(identify("/Users/f/.hermes/hermes-agent/venv/bin/python", ["python", "/Users/f/.hermes/hermes-agent/hermes"]), "hermes")
        XCTAssertEqual(identify("/usr/bin/python3", ["python3", "-u", "/Users/f/.local/bin/aider", "--model", "x"]), "aider")
        XCTAssertEqual(identify("/usr/bin/python3", ["python3", "-m", "aider"]), "aider")
        XCTAssertEqual(identify("/opt/homebrew/bin/node", ["node", "--no-warnings", "-r", "/tmp/preload.js", "/opt/homebrew/bin/pi"]), "pi")
        XCTAssertEqual(identify("/Users/f/.bun/bin/bun", ["bun", "run", "/Users/f/.local/bin/claude"]), "claude")
        // A bundled runtime inside the tool's own folder still identifies it.
        XCTAssertEqual(identify("/Users/f/.local/share/cursor-agent/versions/1/node", ["node", "--use-system-ca", "index.js"]), "cursor-cli")
        // Inline code, unrelated scripts and bare runtimes are not agents.
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "-e", "require('gemini')"]))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "/Work/server.js"]))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node"]))
        XCTAssertNil(identify("/opt/homebrew/bin/python3", []))
        // Someone's own script named like a tool is not that tool.
        XCTAssertNil(identify("/usr/bin/python3", ["python3", "gemini.py"]))
        XCTAssertNil(identify("/usr/bin/python3", ["python3", "/Work/claude.py"]))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "./aider.js"]))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "/Work/scripts/hermes.mjs"]))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "aider"]))
        // Unless its package proves it.
        XCTAssertEqual(identify("/opt/homebrew/bin/node", ["node", "/Users/f/.nvm/versions/node/v22.1.0/lib/node_modules/@google/gemini-cli/dist/index.js"]), "gemini")
    }

    func testSharedCommandNamesNeedTheirPackageAndNeverGuess() {
        XCTAssertEqual(identify("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/pi"]), "pi")
        XCTAssertEqual(identify("/Users/f/.local/bin/agent"), "cursor-cli")
        XCTAssertEqual(identify("/Users/f/.local/bin/cursor-agent"), "cursor-cli")
        // Another program called `agent` or `pi`: no package marker, so no tool.
        XCTAssertNil(identify("/usr/local/bin/agent"))
        XCTAssertNil(identify("agent"))
        XCTAssertNil(identify("/opt/homebrew/bin/node", ["node", "/Work/agent.js"]))
        XCTAssertNil(identify("/usr/bin/python3", ["python3", "/Users/f/bin/pi"]))
        XCTAssertNil(identify("/usr/local/bin/pi"))
        XCTAssertEqual(identify("/opt/homebrew/bin/gemini"), "gemini")
    }

    func testProcessTablePicksForegroundAgentsAndInspectsOnlyCandidates() {
        let table = """
          101 ttys001 S+   /opt/homebrew/bin/node
          102 ttys001 S+   /opt/homebrew/bin/node
          200 ttys002 Ss+  /bin/zsh
          300 ttys003 S+   /Users/f/.local/bin/agent
          400 ttys004 S+   /usr/local/bin/agent
          500 ttys005 S    /opt/homebrew/bin/node
          600 ttys006 T+   /Users/f/.local/bin/claude
          700 ttys007 S+   /Users/f/Folder With Spaces/claude
          800 ??      S+   /Users/f/.local/bin/claude
          900 ttys009 S+   /usr/bin/git
        """
        var inspected: [Int32] = []
        let launches: [Int32: AgentProcessLaunch] = [
            101: AgentProcessLaunch(executable: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/bin/pi"]),
            102: AgentProcessLaunch(executable: "/opt/homebrew/bin/node", arguments: ["node", "/Users/f/.nvm/versions/node/v22.1.0/bin/gemini"]),
            500: AgentProcessLaunch(executable: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/bin/pi"])
        ]
        let found = AgentProcessTable.agents(table, tools: tools, inspect: { inspected.append($0); return launches[$0] }, resolve: resolve)
        XCTAssertEqual(found["/dev/ttys001"]?.tool.id, "pi", "the earliest foreground agent in a TTY wins")
        XCTAssertNil(found["/dev/ttys002"])
        XCTAssertEqual(found["/dev/ttys003"]?.tool.id, "cursor-cli")
        XCTAssertNil(found["/dev/ttys004"], "an unrelated `agent` command is not Cursor CLI")
        XCTAssertNil(found["/dev/ttys005"], "background jobs do not count")
        XCTAssertNil(found["/dev/ttys006"], "stopped jobs do not count")
        XCTAssertEqual(found["/dev/ttys007"]?.tool.id, "claude")
        XCTAssertEqual(found.count, 3)
        XCTAssertFalse(inspected.contains(200))
        XCTAssertFalse(inspected.contains(900))
        XCTAssertFalse(inspected.contains(700), "a plain command is matched by name; its argv may hold a prompt")

        // With tpgid, the job the shell started wins even when an agent it spawned has a lower pid.
        let grouped = """
          9000 9000 ttys011 S+ /Users/f/.local/bin/claude
           120 9000 ttys011 S+ /Users/f/.local/bin/aider
        """
        XCTAssertEqual(AgentProcessTable.agents(grouped, tools: tools, inspect: { _ in nil }, resolve: resolve)["/dev/ttys011"]?.tool.id, "claude")
        // A confirmed vendor install identifies a shared name.
        let droid = fixture("droid", executables: ["droid"], ambiguous: ["droid"])
        XCTAssertNil(AgentIdentity.tool(launch: AgentProcessLaunch(executable: "/Users/f/.local/bin/droid", arguments: []), tools: [droid], resolve: { $0 }))
        XCTAssertEqual(AgentIdentity.tool(launch: AgentProcessLaunch(executable: "/Users/f/.local/bin/droid", arguments: []), tools: [droid], installs: ["/Users/f/.local/bin/droid": "droid"], resolve: { $0 })?.id, "droid")
    }

    func testVendorInstallsCountOnlyWithTheVendorsFolderAndShimsUseTheirPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func executable(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let droid = try XCTUnwrap(AgentRegistry.tool(id: "droid"))
        try executable(".local/bin/droid")
        XCTAssertNil(AgentDetector.installed(AgentProbe.scan(home: root, path: "", tools: [droid]), tools: [droid]).first?.executablePath,
                     "another program's ~/.local/bin/droid")
        try fm.createDirectory(at: root.appendingPathComponent(".factory"), withIntermediateDirectories: true)
        XCTAssertEqual(AgentDetector.installed(AgentProbe.scan(home: root, path: "", tools: [droid]), tools: [droid]).first?.executablePath,
                       root.appendingPathComponent(".local/bin/droid").path)

        let pi = try XCTUnwrap(AgentRegistry.tool(id: "pi"))
        try executable(".volta/bin/pi")
        XCTAssertNil(AgentDetector.installed(AgentProbe.scan(home: root, path: "", tools: [pi]), tools: [pi]).first?.executablePath)
        try fm.createDirectory(at: root.appendingPathComponent(".volta/tools/image/packages/@earendil-works/pi-coding-agent"), withIntermediateDirectories: true)
        XCTAssertEqual(AgentDetector.installed(AgentProbe.scan(home: root, path: "", tools: [pi]), tools: [pi]).first?.executablePath,
                       root.appendingPathComponent(".volta/bin/pi").path)
    }

    func testVersionManagerInstallsRunWithTheirOwnNodeInEveryShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.11.0/bin")
        let script = root.appendingPathComponent(".nvm/versions/node/v22.11.0/lib/node_modules/@google/gemini-cli/dist/index.js")
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: script)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("gemini"), withDestinationURL: script)
        XCTAssertNil(AgentLaunch.runtime(for: bin.appendingPathComponent("gemini").path), "no node beside it")
        try Data().write(to: bin.appendingPathComponent("node"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("node").path)
        let node = try XCTUnwrap(AgentLaunch.runtime(for: bin.appendingPathComponent("gemini").path))
        let command = try XCTUnwrap(AgentLaunch.shellCommand(project: "/Work", environment: ["GEMINI_CLI_HOME": "/x"], executable: bin.appendingPathComponent("gemini").path, runtime: node))
        XCTAssertEqual(command, "cd -- '/Work' && GEMINI_CLI_HOME='/x' '\(node)' '\(bin.appendingPathComponent("gemini").path)'")
        XCTAssertFalse(command.contains("PATH="), "no PATH assignment, which fish rejects")
        XCTAssertNil(AgentLaunch.runtime(for: "/opt/homebrew/bin/gemini"))
    }

    func testVersionManagerAndUserBinFoldersAreSearchedNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for version in ["v18.20.0", "v22.11.0", "v9.0.0"] {
            try fm.createDirectory(at: root.appendingPathComponent(".nvm/versions/node/\(version)/bin"), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appendingPathComponent("Library/Application Support/fnm/node-versions/v20.0.0/installation/bin"), withIntermediateDirectories: true)
        let directories = AgentPaths.directories(home: root, path: "/usr/bin:/bin:relative", tools: tools)
        let nvm = directories.filter { $0.contains("/.nvm/") }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
        XCTAssertEqual(nvm, ["v22.11.0", "v18.20.0", "v9.0.0"])
        XCTAssertTrue(directories.contains(root.appendingPathComponent("Library/Application Support/fnm/node-versions/v20.0.0/installation/bin").path))
        for relative in [".volta/bin", ".bun/bin", ".npm-global/bin", ".local/share/mise/shims", ".asdf/shims", "Library/pnpm"] {
            XCTAssertTrue(directories.contains(root.appendingPathComponent(relative).path), relative)
        }
        XCTAssertEqual(directories.first, "/usr/bin")
        XCTAssertFalse(directories.contains("relative"))
        XCTAssertEqual(Set(directories).count, directories.count)

        // A real install inside nvm is found and its package proves the shared `pi` name.
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.11.0/bin")
        let package = root.appendingPathComponent(".nvm/versions/node/v22.11.0/lib/node_modules/@fixture/pi-agent/dist")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node".utf8).write(to: package.appendingPathComponent("cli.js"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.appendingPathComponent("cli.js").path)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("pi"), withDestinationURL: package.appendingPathComponent("cli.js"))
        // Another `pi` earlier on PATH, not from the package.
        let other = root.appendingPathComponent("other-bin")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("#!/bin/sh".utf8).write(to: other.appendingPathComponent("pi"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.appendingPathComponent("pi").path)
        let scan = AgentProbe.scan(home: root, path: other.path, tools: tools)
        let pi = try XCTUnwrap(AgentDetector.installed(scan, tools: tools).first { $0.id == "pi" })
        XCTAssertEqual(pi.executablePath, bin.appendingPathComponent("pi").path)
        // A non-executable file is not an install.
        try Data().write(to: other.appendingPathComponent("aider"))
        XCTAssertNil(AgentDetector.installed(AgentProbe.scan(home: root, path: other.path, tools: tools), tools: tools).first { $0.id == "aider" })
    }

    func testDuplicateAndRenamedAppsPreferTheApplicationsCopyAndSkipTrashAndOwnCopies() {
        let home = "/Users/f"
        let apps = [
            AgentApplication(path: "/Users/f/.Trash/Grok Bot.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "9.0"),
            AgentApplication(path: "/Volumes/Grok Bot/Grok Bot.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "9.0"),
            AgentApplication(path: "/Users/f/Downloads/Grok Bot.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "8.0"),
            AgentApplication(path: "/Users/f/Applications/Grok Bot.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "1.0"),
            AgentApplication(path: "/Applications/Bot (old).app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "0.9"),
            AgentApplication(path: "/Applications/Bot Renamed.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "0.10"),
            AgentApplication(path: "/Users/f/Library/Application Support/Account Dock/Apps/x/Bot.app", bundleIdentifier: "com.fixture.bot", name: "Grok Bot", version: "99")
        ]
        let ordered = AgentApplications.ordered(apps, home: home).map(\.path)
        // Read-only volumes (mounted installers) are dropped when Launch Services lists them; a path alone could be an external drive.
        XCTAssertEqual(ordered, ["/Applications/Bot Renamed.app", "/Applications/Bot (old).app", "/Users/f/Applications/Grok Bot.app", "/Volumes/Grok Bot/Grok Bot.app", "/Users/f/Downloads/Grok Bot.app"])
        let bot = fixture("bot", executables: [], bundles: ["com.fixture.bot"], interface: .desktop)
        let input = AgentScanInput(homePath: home, pathDirectories: [], existingPaths: [], applications: apps)
        let installed = AgentDetector.installed(bot, in: input)
        XCTAssertEqual(installed?.applicationPath, "/Applications/Bot Renamed.app")
        XCTAssertEqual(installed?.applications.count, 5)
        XCTAssertTrue(installed?.isInstalled == true)
    }

    func testAutoAddUsesTheExistingSignInOnlyAndRespectsRemovedTools() throws {
        // Registry id, so a separate profile resolves its isolation.
        let bot = fixture("grok-bot", executables: [], bundles: ["com.fixture.bot"], interface: .desktop, addsWhenRunning: true, isolation: .userDataDirectory)
        let editor = fixture("editor", executables: [], bundles: ["com.fixture.editor"], interface: .desktop)
        let all = [bot, editor]
        let shared = AgentAutoAdd.RunningApp(bundleIdentifier: "com.fixture.bot", arguments: ["/Applications/Bot.app/Contents/MacOS/Bot"])
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [shared, shared], profiles: [], dismissed: [], tools: all).map(\.id), ["grok-bot"])
        // Only dedicated agent apps add themselves; editors are offered instead.
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.fixture.editor", arguments: ["x"])], profiles: [], dismissed: [], tools: all), [])
        // A removed tool stays removed.
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [shared], profiles: [], dismissed: ["grok-bot"], tools: all), [])
        // An instance with its own data folder may be another account; one whose argv is unreadable is unknown.
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.fixture.bot", arguments: ["Bot", "--user-data-dir=/tmp/x"])], profiles: [], dismissed: [], tools: all), [])
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [AgentAutoAdd.RunningApp(bundleIdentifier: "com.fixture.bot", arguments: nil)], profiles: [], dismissed: [], tools: all), [])
        // An existing shared entry, even hidden, means nothing is added; a separate account alone still gets a shared tile.
        var existing = try XCTUnwrap(AgentProfiles.make(tool: bot, name: "Bot", separate: false))
        existing.hiddenFromStrip = true
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [shared], profiles: [existing], dismissed: [], tools: all), [])
        let separate = try XCTUnwrap(AgentProfiles.make(tool: bot, name: "Work", separate: true))
        XCTAssertEqual(AgentAutoAdd.toolsToAdd(running: [shared], profiles: [separate], dismissed: [], tools: all).map(\.id), ["grok-bot"])

        let installed = [InstalledAgent(tool: bot, executablePath: nil, applicationPath: "/Applications/Bot.app", configPath: nil, evidence: [.application]),
                         InstalledAgent(tool: editor, executablePath: nil, applicationPath: nil, configPath: "/Users/f/.editor", evidence: [.config])]
        XCTAssertEqual(AgentAutoAdd.offers(installed: installed, profiles: [], dismissed: []).map(\.id), ["grok-bot"], "a config folder alone is not an install")
        XCTAssertEqual(AgentAutoAdd.offers(installed: installed, profiles: [separate], dismissed: []).map(\.id), [])
        XCTAssertEqual(AgentAutoAdd.offers(installed: installed, profiles: [], dismissed: ["grok-bot"]).map(\.id), [])
    }

    func testArgvDecodingStopsBeforeTheEnvironment() throws {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/opt/homebrew/bin/pi".utf8) + [0]
        bytes += Array("SECRET_TOKEN=abc".utf8) + [0]
        let launch = try XCTUnwrap(ProcessIdentity.launch(from: Data(bytes)))
        XCTAssertEqual(launch.executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(launch.arguments, ["node", "/opt/homebrew/bin/pi"])
        XCTAssertEqual(ProcessIdentity.arguments(from: Data(bytes)), ["node", "/opt/homebrew/bin/pi"])
    }

    func testSignInStatusReadsOneBooleanFromASmallStatusFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let status = AgentSignInStatus(relativePath: "desktop-status.json", key: "signedIn")
        XCTAssertNil(AgentProbe.signedIn(status, userData: root))
        try Data(#"{"signedIn":false,"version":"1"}"#.utf8).write(to: root.appendingPathComponent("desktop-status.json"))
        XCTAssertEqual(AgentProbe.signedIn(status, userData: root), false)
        try Data(#"{"signedIn":true}"#.utf8).write(to: root.appendingPathComponent("desktop-status.json"))
        XCTAssertEqual(AgentProbe.signedIn(status, userData: root), true)
        try Data(#"{"signedIn":"yes"}"#.utf8).write(to: root.appendingPathComponent("desktop-status.json"))
        XCTAssertNil(AgentProbe.signedIn(status, userData: root))
        try Data(repeating: 32, count: 70_000).write(to: root.appendingPathComponent("desktop-status.json"))
        XCTAssertNil(AgentProbe.signedIn(status, userData: root))
        // A link is never followed, and a pipe never blocks.
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"signedIn":true}"#.utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: root.appendingPathComponent("desktop-status.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("desktop-status.json"), withDestinationURL: elsewhere)
        XCTAssertNil(AgentProbe.signedIn(status, userData: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("desktop-status.json"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("desktop-status.json").path, 0o600), 0)
        XCTAssertNil(AgentProbe.signedIn(status, userData: root))
    }
}

/// `PROFILEDOCK_LIVE_AGENTS=<file> swift test --filter AgentLiveReport` writes what this Mac has, read-only:
/// file existence, symlink targets, Info.plist and the argv of foreground TTY processes. Nothing is launched or changed.
final class AgentLiveReport: XCTestCase {
    func testWriteLiveReport() throws {
        guard let output = ProcessInfo.processInfo.environment["PROFILEDOCK_LIVE_AGENTS"] else { throw XCTSkip("Opt-in live report") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let scan = AgentProbe.scan(home: home, path: "/usr/bin:/bin:/usr/sbin:/sbin", applicationRoots: roots)
        var lines = ["# Live agent scan, GUI PATH only", ""]
        for agent in AgentDetector.installed(scan) {
            lines.append("- \(agent.tool.name) [\(agent.evidence.map(\.rawValue).joined(separator: ", "))]"
                + (agent.executablePath.map { " command: \($0)" } ?? "") + (agent.applicationPath.map { " app: \($0)" } ?? "")
                + (agent.configPath.map { " config: \($0)" } ?? "") + (agent.isInstalled ? "" : " (used before, not installed)"))
        }
        let ps = Process(), pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "pid=,tty=,stat=,comm="]; ps.standardOutput = pipe
        try ps.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()
        let agents = AgentProcessTable.agents(String(decoding: data, as: UTF8.self), inspect: { pid in
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]; var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = Data(count: size)
            guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0 else { return nil }
            return ProcessIdentity.launch(from: buffer.prefix(size))
        }, resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        lines += ["", "# Foreground agents in TTYs", ""] + agents.values.sorted { $0.tty < $1.tty }.map { "- \($0.tty): \($0.tool.name) (pid \($0.pid))" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
