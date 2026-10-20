import Foundation

/// One line of `ps -axo pid=,ppid=,tpgid=,tty=,stat=,comm=`.
public struct ProcessRow: Sendable, Equatable {
    public var pid: Int32
    public var parent: Int32
    public var group: Int32
    public var tty: String
    public var state: String
    public var command: String

    public static func rows(_ table: String) -> [ProcessRow] {
        table.split(separator: "\n").compactMap { line in
            let fields = line.drop { $0.isWhitespace }.split(maxSplits: 5, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 6, let pid = Int32(fields[0]), let parent = Int32(fields[1]), let group = Int32(fields[2]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, group: group, tty: fields[3], state: fields[4], command: fields[5].trimmingCharacters(in: .whitespaces))
        }
    }

    /// The same rows in the `pid tpgid tty stat comm` form the agent table reads.
    public static func agentTable(_ rows: [ProcessRow]) -> String {
        rows.map { "\($0.pid) \($0.group) \($0.tty) \($0.state) \($0.command)" }.joined(separator: "\n")
    }
}

/// Where a coding session runs: the app that owns its terminal, or a terminal multiplexer.
public struct AgentHost: Sendable, Equatable, Hashable {
    /// The outermost `.app` bundle in the session's parent chain. Nil inside tmux or screen, or when no app owns it.
    public var applicationPath: String?
    /// `tmux` or `screen` when the session runs inside one; ProfileDock cannot switch to a pane there.
    public var multiplexer: String?
    /// A known helper outside any bundle, such as iTerm2's session server in Application Support.
    public var bundleIdentifier: String?
    /// The app's own main process, so the right instance comes forward when several run (separate accounts).
    public var processIdentifier: Int32?
    public init(applicationPath: String?, multiplexer: String?, bundleIdentifier: String? = nil, processIdentifier: Int32? = nil) {
        self.applicationPath = applicationPath
        self.multiplexer = multiplexer
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
    /// A session ProfileDock can name and bring forward.
    public var isKnown: Bool { applicationPath != nil || multiplexer != nil || bundleIdentifier != nil }
}

/// A foreground agent in any terminal app, found by TTY. Only process names, parents and paths are used.
public struct HostedAgentSession: Sendable, Equatable {
    public var tty: String
    public var pid: Int32
    public var tool: AgentTool
    public var host: AgentHost
}

public enum AgentHosts {
    static let multiplexers: Set<String> = ["tmux", "screen"]
    /// Session servers that run from outside their app bundle and are reparented to launchd.
    static let servers = ["itermserver": "com.googlecode.iterm2"]

    /// The `.app` that owns a process, from its executable path: `/Applications/iTerm.app/Contents/MacOS/iTermServer-3`
    /// gives `/Applications/iTerm.app`. Helpers nested in another app resolve to the outer app.
    public static func application(of command: String) -> String? {
        guard command.hasPrefix("/"), let range = command.range(of: ".app/") else { return nil }
        return String(command[..<range.lowerBound]) + ".app"
    }

    /// Walks up from the TTY's session leader. The first app bundle, known session server or multiplexer on the way
    /// names the host. `isApplication` tells which pid is a running app, so its exact instance is recorded.
    public static func host(of tty: String, rows: [ProcessRow], isApplication: (Int32) -> Bool = { _ in false }) -> AgentHost {
        let short = tty.replacingOccurrences(of: "/dev/", with: "")
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let inTTY = rows.filter { $0.tty == short }
        guard let leader = inTTY.first(where: { $0.state.contains("s") }) ?? inTTY.min(by: { $0.pid < $1.pid }) else {
            return AgentHost(applicationPath: nil, multiplexer: nil)
        }
        var current = byPID[leader.parent]
        var seen = Set<Int32>()
        while let row = current, row.pid > 1, seen.insert(row.pid).inserted {
            let name = URL(fileURLWithPath: row.command).lastPathComponent.lowercased()
            if multiplexers.contains(where: { name.hasPrefix($0) }) { return AgentHost(applicationPath: nil, multiplexer: name.hasPrefix("tmux") ? "tmux" : "screen") }
            if let server = servers.first(where: { name.hasPrefix($0.key) })?.value { return AgentHost(applicationPath: nil, multiplexer: nil, bundleIdentifier: server) }
            if let app = application(of: row.command) {
                // Helpers sit below the app's main process; keep walking to it for the exact instance.
                var owner: Int32?
                var step: ProcessRow? = row
                var visited = Set<Int32>()
                while let candidate = step, candidate.pid > 1, visited.insert(candidate.pid).inserted, application(of: candidate.command) == app {
                    if isApplication(candidate.pid) { owner = candidate.pid; break }
                    step = byPID[candidate.parent]
                }
                return AgentHost(applicationPath: app, multiplexer: nil, processIdentifier: owner)
            }
            current = byPID[row.parent]
        }
        return AgentHost(applicationPath: nil, multiplexer: nil)
    }

    /// Agents in every TTY with their host. `skip` leaves out hosts handled elsewhere (Terminal.app while it can be scripted).
    public static func sessions(rows: [ProcessRow], tools: [AgentTool] = AgentRegistry.tools, installs: [String: String] = [:],
                                inspect: (Int32) -> AgentProcessLaunch?, executablePath: (Int32) -> String? = { _ in nil },
                                resolve: (String) -> String, isApplication: (Int32) -> Bool = { _ in false },
                                skip: (AgentHost) -> Bool = { _ in false }) -> [HostedAgentSession] {
        AgentProcessTable.agents(ProcessRow.agentTable(rows), tools: tools, installs: installs, inspect: inspect, executablePath: executablePath, resolve: resolve)
            .values.compactMap { agent in
                let host = host(of: agent.tty, rows: rows, isApplication: isApplication)
                // SSH logins into this Mac and orphaned sessions have no app to bring forward.
                return !host.isKnown || skip(host) ? nil : HostedAgentSession(tty: agent.tty, pid: agent.pid, tool: agent.tool, host: host)
            }
            .sorted { $0.tty < $1.tty }
    }
}
