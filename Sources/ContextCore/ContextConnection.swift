import Foundation
import CryptoKit

public struct ContextCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public init(status: Int32, output: String, error: String) { self.status = status; self.output = output; self.error = error }
}

public struct ContextConnection: Sendable {
    public static let serverName = "profiledock-context"
    public static let skillMarker = "<!-- ProfileDock managed context skill v1 -->"
    public let registry: ContextRegistry
    public let codex: URL
    private let run: @Sendable (URL, [String], [String: String]) throws -> ContextCommandResult
    public init(registry: ContextRegistry, codex: URL, run: @escaping @Sendable (URL, [String], [String: String]) throws -> ContextCommandResult = { try ContextConnection.runCommand($0, $1, $2) }) {
        self.registry = registry; self.codex = codex; self.run = run
    }
    private func environment(_ profile: ContextProfile) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.root(in: registry.home).path
        return environment
    }
    private func launchArguments(_ profile: ContextProfile) -> [String] {
        var arguments = ["mcp", "--profile", profile.id]
        if registry.home != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL {
            arguments += ["--home", registry.home.path]
        }
        return arguments
    }
    private func entry(_ profile: ContextProfile) throws -> [String: Any]? {
        if profile.kind != .codex {
            guard profile.kind == .claude else { throw ContextError.message("Connect through your Claude Desktop entry. Claude Code shares one user configuration across Terminal and Desktop.") }
            let config = registry.home.appendingPathComponent(".claude.json")
            guard FileManager.default.fileExists(atPath: config.path) else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else { throw ContextError.message("Claude configuration could not be read.") }
            guard let server = (json["mcpServers"] as? [String: [String: Any]])?[Self.serverName] else { return nil }
            var transport = server; transport["type"] = server["type"] ?? "stdio"
            return ["transport": transport, "enabled": true]
        }
        let response = try run(codex, ["mcp", "get", Self.serverName, "--json"], environment(profile))
        if response.status != 0 {
            if response.error.contains("No MCP server named") { return nil }
            throw ContextError.message("Could not check this profile's connection. Open its ChatGPT app and try again.")
        }
        guard let data = response.output.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContextError.message("The Codex connection response could not be read.") }
        return value
    }
    private func owns(_ entry: [String: Any], _ profile: ContextProfile) -> Bool {
        guard let transport = entry["transport"] as? [String: Any] else { return false }
        return transport["type"] as? String == "stdio" && transport["command"] as? String == registry.helperURL.path && transport["args"] as? [String] == launchArguments(profile)
    }
    public func isConnected(_ profile: ContextProfile) throws -> Bool {
        guard let entry = try entry(profile) else { return false }
        guard owns(entry, profile) else { throw ContextError.message("Another connection already uses the name profiledock-context. It was left unchanged.") }
        return entry["enabled"] as? Bool != false && FileManager.default.isExecutableFile(atPath: registry.helperURL.path) && FileManager.default.fileExists(atPath: skillURL(profile).path)
    }
    private func skillURL(_ profile: ContextProfile) -> URL { profile.root(in: registry.home).appendingPathComponent("skills/profiledock-context/SKILL.md") }
    public func connect(_ profile: ContextProfile, helper: URL, skill: String) throws {
        guard skill.contains(Self.skillMarker), FileManager.default.isExecutableFile(atPath: helper.path) else { throw ContextError.message("The packaged context helper is missing. Reinstall ProfileDock.") }
        if let entry = try entry(profile), !owns(entry, profile) { throw ContextError.message("Another connection already uses the name profiledock-context. It was left unchanged.") }
        let target = skillURL(profile), fm = FileManager.default
        if fm.fileExists(atPath: target.path), !(try String(contentsOf: target, encoding: .utf8)).contains(Self.skillMarker) { throw ContextError.message("A custom profiledock-context skill already exists. It was left unchanged.") }
        try registry.createPrivateDirectory()
        if helper.standardizedFileURL != registry.helperURL.standardizedFileURL {
            // Atomic replacement leaves already-running helpers intact until their next restart.
            let data = try Data(contentsOf: helper)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let receipt = registry.directory.appendingPathComponent("helper-sha256")
            if fm.fileExists(atPath: registry.helperURL.path) {
                let old = SHA256.hash(data: try Data(contentsOf: registry.helperURL)).map { String(format: "%02x", $0) }.joined()
                let recorded = try? String(contentsOf: receipt, encoding: .utf8)
                guard old == digest || recorded == old else { throw ContextError.message("The installed helper has been changed outside ProfileDock. It was left unchanged.") }
            }
            try data.write(to: registry.helperURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: registry.helperURL.path)
            try Data(digest.utf8).write(to: receipt, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(skill.utf8).write(to: target, options: [.atomic])
        let success: Bool
        if profile.kind == .claude { try updateClaude(profile, enabled: true); success = true }
        else { success = try run(codex, ["mcp", "add", Self.serverName, "--", registry.helperURL.path] + launchArguments(profile), environment(profile)).status == 0 }
        guard success, try isConnected(profile) else { throw ContextError.message("The helper was prepared, but the profile connection could not be verified. Try Connect again.") }
        try ContextMentions(registry: registry).synchronize(profile)
    }
    public func disconnect(_ profile: ContextProfile) throws {
        // Revoke first: existing sessions cannot retain access through a still-running helper.
        var policy = try registry.access(); policy.grants[profile.id] = []; try registry.save(policy)
        try ContextMentions(registry: registry).remove(profile)
        if let entry = try entry(profile) {
            guard owns(entry, profile) else { throw ContextError.message("Sharing was disabled. An unrelated connection with the same name was left unchanged.") }
            if profile.kind == .claude { try updateClaude(profile, enabled: false) }
            else {
                let response = try run(codex, ["mcp", "remove", Self.serverName], environment(profile))
                guard response.status == 0 else { throw ContextError.message("Sharing is disabled, but the saved connection could not be removed.") }
            }
        }
        let skill = skillURL(profile)
        if let text = try? String(contentsOf: skill, encoding: .utf8), text.contains(Self.skillMarker) { try FileManager.default.removeItem(at: skill) }
    }

    private func updateClaude(_ profile: ContextProfile, enabled: Bool) throws {
        let url = registry.home.appendingPathComponent(".claude.json"), fm = FileManager.default
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw ContextError.message("Linked Claude configuration was left unchanged.") }
        let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var json: [String: Any] = [:]
        if let original {
            guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw ContextError.message("Claude configuration could not be read.") }
            json = parsed
        }
        guard json["mcpServers"] == nil || json["mcpServers"] is [String: Any] else { throw ContextError.message("Claude MCP configuration has an unexpected format.") }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        if enabled { servers[Self.serverName] = ["type": "stdio", "command": registry.helperURL.path, "args": launchArguments(profile)] }
        else { servers.removeValue(forKey: Self.serverName) }
        json["mcpServers"] = servers
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw ContextError.message("Claude configuration changed. Try again to preserve those changes.") }
        if let original {
            let backup = registry.directory.appendingPathComponent("claude-config-backup-" + UUID().uuidString + ".json")
            try original.write(to: backup, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func runCommand(_ executable: URL, _ arguments: [String], _ environment: [String: String]) throws -> ContextCommandResult {
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("profiledock-connect-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("out"), errorURL = directory.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errorURL)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory; process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { process.terminate(); throw ContextError.message("The connection check timed out. Try again.") }
        return ContextCommandResult(status: process.terminationStatus, output: String(decoding: try Data(contentsOf: outURL).prefix(1024 * 1024), as: UTF8.self), error: String(decoding: try Data(contentsOf: errorURL).prefix(65536), as: UTF8.self))
    }
}
