import Foundation

/// What a running process was started as: the kernel's executable path and its argv. Never its environment.
public struct AgentProcessLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Decides which registry tool a process is without guessing. A command name that several programs share
/// (`pi`, `agent`, `cn`, `droid`) needs its resolved install path to name the tool's package.
public enum AgentIdentity {
    /// Runtimes that npm, pip and Bun commands run under. The command itself is then the script in argv.
    public static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["node", "bun", "deno", "ruby"].contains(name) || name.range(of: "^python[0-9.]*$", options: .regularExpression) != nil
    }

    /// Flags that take the next argument as their value, so it is not the script.
    private static let valueFlags: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-X", "-W", "--env-file", "--conditions", "-C"]
    /// Inline code has no script to identify.
    private static let inlineFlags: Set<String> = ["-e", "--eval", "-p", "--print", "-c"]

    static let sourceExtensions = [".js", ".mjs", ".cjs", ".ts", ".mts", ".py"]

    /// The script an interpreter runs, from argv only. `python -m tool` gives the module name and no path.
    public static func script(arguments: [String]) -> (name: String, path: String?)? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if inlineFlags.contains(argument) { return nil }
            if argument == "-m", index + 1 < arguments.count {
                let module = arguments[index + 1].split(separator: ".").first.map(String.init) ?? arguments[index + 1]
                return (module.replacingOccurrences(of: "_", with: "-"), nil)
            }
            if valueFlags.contains(argument) { index += 2; continue }
            // `bun run <script>` and `bun x <package>`.
            if (argument == "run" || argument == "x") && index == 1 { index += 1; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            var name = URL(fileURLWithPath: argument).lastPathComponent
            for suffix in sourceExtensions where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return (name, argument)
        }
        return nil
    }

    /// `resolve` follows symlinks of an absolute path; tests pass a table instead of the file system.
    /// `installs` maps install paths the last scan confirmed (for example Factory's `~/.local/bin/droid`) to their tool.
    public static func tool(launch: AgentProcessLaunch, tools: [AgentTool] = AgentRegistry.tools, installs: [String: String] = [:], resolve: (String) -> String) -> AgentTool? {
        var name = URL(fileURLWithPath: launch.executable).lastPathComponent.lowercased()
        var paths = [launch.executable]
        if isInterpreter(name) {
            if let script = script(arguments: launch.arguments) {
                // Only an installed command counts by name: the absolute path a shebang passes, without a source
                // extension. `python3 gemini.py` or `node ./codex.mjs` is someone's script, unless its package proves the tool.
                let installed = script.path.map { path in path.hasPrefix("/") && !sourceExtensions.contains { path.lowercased().hasSuffix($0) } } ?? true
                name = installed ? script.name.lowercased() : ""
                if let path = script.path { paths.insert(path, at: 0) }
            } else {
                // Inline code or no script: only a bundled runtime inside a tool's own folder can identify it.
                name = ""
            }
        }
        let candidates = paths.flatMap { path -> [String] in
            guard path.hasPrefix("/") else { return [path.lowercased()] }
            return [path.lowercased(), resolve(path).lowercased()]
        }
        for path in paths where path.hasPrefix("/") {
            if let id = installs[path] ?? installs[resolve(path)], let tool = tools.first(where: { $0.id == id }) { return tool }
        }
        let marked = tools.filter { tool in tool.packageMarkers.contains { marker in candidates.contains { $0.contains(marker) } } }
        if marked.count == 1 { return marked[0] }
        if marked.count > 1 { return marked.first { $0.executables.contains(name) } }
        guard !name.isEmpty, let tool = tools.first(where: { $0.executables.contains(name) }) else { return nil }
        return tool.ambiguousExecutables.contains(name) ? nil : tool
    }

    /// Whether a process name could be an agent at all, so only those are looked at further.
    public static func worthInspecting(_ name: String, tools: [AgentTool] = AgentRegistry.tools) -> Bool {
        let name = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        return isInterpreter(name) || tools.contains { $0.executables.contains(name) }
    }

    /// Argv is read only where it decides the answer: a runtime running a script, or a shared command name that
    /// needs its full executable path. `claude "<prompt>"` and other plain commands are matched by name alone.
    public static func needsLaunch(_ name: String, tools: [AgentTool] = AgentRegistry.tools) -> Bool {
        let name = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        return isInterpreter(name) || tools.contains { $0.ambiguousExecutables.contains(name) }
    }
}

/// A foreground agent in one TTY, from `ps -axo pid=,tty=,stat=,comm=`.
public struct AgentTerminalProcess: Sendable, Equatable {
    public var pid: Int32
    public var tty: String
    public var tool: AgentTool
}

public enum AgentProcessTable {
    /// Only foreground, running or sleeping processes count, never idle shells, stopped jobs or zombies.
    /// When several agents share a TTY's foreground group, the earliest process (the one the shell started) wins.
    /// Lines are `pid tpgid tty stat comm`; older callers omit tpgid, or both numbers.
    /// `executablePath` gives the kernel's path of a process without its arguments. It identifies tools that rename
    /// their process title (Kimi Code shows as `kimi-code`), against confirmed installs and package markers only.
    public static func agents(_ table: String, tools: [AgentTool] = AgentRegistry.tools, installs: [String: String] = [:],
                              inspect: (Int32) -> AgentProcessLaunch?, executablePath: (Int32) -> String? = { _ in nil },
                              resolve: (String) -> String) -> [String: AgentTerminalProcess] {
        var result: [String: AgentTerminalProcess] = [:]
        var leaders = Set<String>()
        for line in table.split(separator: "\n") {
            let trimmed = line.drop { $0.isWhitespace }
            var fields = trimmed.split(maxSplits: 4, whereSeparator: { $0.isWhitespace }).map(String.init)
            var pid: Int32 = 0, group: Int32 = -1
            if fields.count == 5, let value = Int32(fields[0]), let foreground = Int32(fields[1]) {
                pid = value; group = foreground; fields.removeFirst(2)
            } else {
                fields = trimmed.split(maxSplits: 3, whereSeparator: { $0.isWhitespace }).map(String.init)
                if fields.count == 4, let value = Int32(fields[0]) { pid = value; fields.removeFirst() }
                else { fields = trimmed.split(maxSplits: 2, whereSeparator: { $0.isWhitespace }).map(String.init) }
            }
            guard fields.count == 3, fields[1].contains("+"), !fields[1].contains("T"), !fields[1].contains("Z") else { continue }
            let tty = "/dev/" + fields[0]
            guard ClaudeSession.validTTY(tty) else { continue }
            let command = fields[2].trimmingCharacters(in: .whitespaces)
            let launch: AgentProcessLaunch
            if AgentIdentity.worthInspecting(command, tools: tools) {
                launch = (pid > 0 && AgentIdentity.needsLaunch(command, tools: tools) ? inspect(pid) : nil) ?? AgentProcessLaunch(executable: command, arguments: [])
            } else {
                // A renamed title: only its real executable path, and only a confirmed install or package counts.
                let name = URL(fileURLWithPath: command).lastPathComponent.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                guard pid > 0, !shells.contains(name), let path = executablePath(pid), path.hasPrefix("/") else { continue }
                let resolved = resolve(path).lowercased()
                guard installs[path] != nil || installs[resolve(path)] != nil
                        || tools.contains(where: { $0.packageMarkers.contains { resolved.contains($0) } }) else { continue }
                launch = AgentProcessLaunch(executable: path, arguments: [])
            }
            guard let tool = AgentIdentity.tool(launch: launch, tools: tools, installs: installs, resolve: resolve), tool.launchesInTerminal else { continue }
            // The job the shell started leads the TTY's foreground group; an agent it spawned does not replace it.
            let leads = pid > 0 && pid == group
            if let existing = result[tty] {
                let existingLeads = leaders.contains(tty)
                if existingLeads && !leads { continue }
                if existingLeads == leads && existing.pid <= pid { continue }
            }
            if leads { leaders.insert(tty) }
            result[tty] = AgentTerminalProcess(pid: pid, tty: tty, tool: tool)
        }
        return result
    }
}

/// Foreground processes that are never an agent, so their path is not looked up.
let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "login", "tmux", "screen", "ssh", "sudo", "su", "top", "less", "man", "vim", "nvim", "git"]

/// Which tools ProfileDock adds by itself, and which it only offers.
public enum AgentAutoAdd {
    public struct RunningApp: Sendable, Equatable {
        public var bundleIdentifier: String
        public var arguments: [String]?
        public init(bundleIdentifier: String, arguments: [String]?) {
            self.bundleIdentifier = bundleIdentifier
            self.arguments = arguments
        }
    }

    /// A running desktop agent with the shared sign-in (no `--user-data-dir`) and no saved entry yet.
    /// Separate accounts are never created here. A tool the user removed stays removed.
    public static func toolsToAdd(running: [RunningApp], profiles: [Profile], dismissed: Set<String>, tools: [AgentTool] = AgentRegistry.tools) -> [AgentTool] {
        var result: [AgentTool] = []
        for app in running {
            guard let tool = tools.first(where: { $0.addsWhenRunning && !$0.legacy && $0.bundleIdentifiers.contains(app.bundleIdentifier) }),
                  !dismissed.contains(tool.id), !result.contains(where: { $0.id == tool.id }),
                  !profiles.contains(where: { $0.kind == .agent && $0.agentID == tool.id && !$0.usesIsolatedAgentHome }) else { continue }
            // An unreadable process or one started with its own data folder may be another account: leave it alone.
            guard let arguments = app.arguments, ProcessIdentity.userDataPath(arguments) == nil else { continue }
            result.append(tool)
        }
        return result
    }

    /// Installed tools without any entry, for one-click adding. Config folders alone are not offered.
    public static func offers(installed: [InstalledAgent], profiles: [Profile], dismissed: Set<String>) -> [InstalledAgent] {
        installed.filter { agent in
            !agent.tool.legacy && agent.isInstalled && !dismissed.contains(agent.tool.id)
                && !profiles.contains { $0.kind == .agent && $0.agentID == agent.tool.id }
        }
    }
}
