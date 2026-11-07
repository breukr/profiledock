import Foundation
import DockCore

/// Connects and disconnects ProfileDock's notch hooks in other agents' own settings: Codex (`hooks.json`), Gemini CLI,
/// Cursor, Copilot CLI, Factory Droid, Qwen Code and OpenCode (`AgentHookTarget`). Claude Code keeps `ClaudeBridge`.
/// Every change is explicit (Settings → Coding Agents), idempotent (running it twice changes nothing more), keeps
/// every other tool's entries, refuses linked files, and keeps one backup of an edited file next to it: the oldest
/// (the settings from before ProfileDock first connected) and the newest.
struct AgentHookBridge: Sendable {
    let home: URL
    var helper: URL { ClaudeBridge(home: home).helper }

    enum Status: Equatable, Sendable {
        case connected
        /// Entries from an older ProfileDock, or the helper copy is missing: connecting again updates them.
        case outdated
        case notConnected
        /// The settings file could not be read as ProfileDock expects; nothing will be changed in it.
        case unreadable(String)
    }

    /// Bridge ids in display order. "claude" is handled by `ClaudeBridge`, the rest here.
    static let ids = ["claude", "codex"] + AgentHookTarget.all.map(\.id)
    /// Registry ids whose install makes a bridge id relevant ("cursor" also covers the Cursor CLI).
    static func tools(for id: String) -> [String] { AgentHookTarget.target(id: id)?.tools ?? [id] }

    func file(_ id: String) -> URL? {
        if id == "codex" { return home.appendingPathComponent(".codex/hooks.json") }
        return AgentHookTarget.target(id: id)?.file(home: home)
    }

    func status(_ id: String) -> Status {
        guard let url = file(id) else { return .notConnected }
        let data: Data?
        do { data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil } catch { return .unreadable(error.localizedDescription) }
        let helperReady = FileManager.default.isExecutableFile(atPath: helper.path)
        if id == "codex" {
            if CodexBridgeSettings.isConnected(data, helper: helper) { return helperReady ? .connected : .outdated }
            if let data, (try? CodexBridgeSettings.updating(data, helper: helper, enabled: true)) == nil { return .unreadable("Codex hooks have an unexpected format.") }
            return CodexBridgeSettings.hasEntries(data, helper: helper) ? .outdated : .notConnected
        }
        guard let target = AgentHookTarget.target(id: id) else { return .notConnected }
        let name = url.lastPathComponent
        if AgentHookConfig.isConnected(data, target: target, helper: helper, fileName: name) { return helperReady ? .connected : .outdated }
        if target.format != .ownedFile, (try? AgentHookConfig.updating(data, target: target, helper: helper, enabled: true, fileName: name)) == nil {
            return .unreadable("The settings file has an unexpected format.")
        }
        return AgentHookConfig.hasEntries(data, target: target, helper: helper, fileName: name) ? .outdated : .notConnected
    }

    /// Adds or removes ProfileDock's entries for one agent. Connecting also installs the hook helper.
    func setConnected(_ id: String, _ enabled: Bool, bundledHelper: URL?) throws {
        guard let url = file(id) else { throw CompanionError.message("ProfileDock cannot connect this agent.") }
        if enabled { try installHelper(bundledHelper: bundledHelper) }
        let fm = FileManager.default
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw CompanionError.message("ProfileDock does not change settings through a linked file. Nothing was changed.") }
        let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard enabled || original != nil else { return }
        let changed: Data?
        if id == "codex" {
            changed = try CodexBridgeSettings.updating(original, helper: helper, enabled: enabled)
        } else {
            guard let target = AgentHookTarget.target(id: id) else { return }
            if target.format == .ownedFile, let original, !Self.isOwnedFile(original, id: id) {
                throw CompanionError.message("\(url.lastPathComponent) was not written by ProfileDock, so it was kept.")
            }
            changed = try AgentHookConfig.updating(original, target: target, helper: helper, enabled: enabled, fileName: url.lastPathComponent)
        }
        if let changed, let original, AgentHookConfig.sameJSON(changed, original) || changed == original { return }
        let owned = AgentHookTarget.target(id: id)?.format == .ownedFile
        try write(changed, to: url, replacing: original, backup: !owned)
    }

    /// At launch: brings connected agents up to date (helper copy and entries). Never connects anything new.
    func refreshConnected(bundledHelper: URL?) {
        for id in Self.ids where id != "claude" {
            switch status(id) {
            case .outdated: try? setConnected(id, true, bundledHelper: bundledHelper)
            case .connected: try? installHelper(bundledHelper: bundledHelper)
            default: break
            }
        }
    }

    /// Copies the bundled helper next to Claude's, when it is missing or differs (compared by SHA-256 hash).
    func installHelper(bundledHelper: URL?) throws {
        let fm = FileManager.default, directory = helper.deletingLastPathComponent()
        guard let bundledHelper, fm.isExecutableFile(atPath: bundledHelper.path) else {
            if fm.isExecutableFile(atPath: helper.path) { return }
            throw CompanionError.message("Open the packaged ProfileDock app to connect agents.")
        }
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw CompanionError.message("The helper folder is linked elsewhere.") }
        let bundled = try Data(contentsOf: bundledHelper)
        guard (try? Data(contentsOf: helper)).map(ClaudeBridge.digest) != ClaudeBridge.digest(bundled) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bundled.write(to: helper, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    static func isOwnedFile(_ data: Data, id: String) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return id == "opencode" ? text.contains("profiledock-opencode-plugin") : text.contains("ProfileDockClaude") && text.contains("agent " + id)
    }

    static let backupMarker = ".profiledock-backup-"

    /// Writes `changed` (nil removes the file) after checking nobody edited it meanwhile. An edited file keeps its
    /// permissions and gets a backup; an owned file (Copilot's, OpenCode's plugin) gets none, because those folders load
    /// every file in them.
    private func write(_ changed: Data?, to url: URL, replacing original: Data?, backup: Bool) throws {
        let fm = FileManager.default, folder = url.deletingLastPathComponent()
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw CompanionError.message("The settings changed while connecting. Try again to keep those changes.") }
        guard let changed else { try fm.removeItem(at: url); return }
        let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if backup, let original {
            let stem = url.deletingPathExtension().lastPathComponent, prefix = stem + Self.backupMarker
            let copy = folder.appendingPathComponent(prefix + UUID().uuidString + "." + (url.pathExtension.isEmpty ? "json" : url.pathExtension))
            try original.write(to: copy, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            let older = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey])) ?? []).filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent != copy.lastPathComponent
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }.sorted { Self.created($0) < Self.created($1) }
            // Keep the oldest (the original settings) and the one just written.
            for stale in older.dropFirst() { try? fm.removeItem(at: stale) }
        }
        try changed.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture }
}
