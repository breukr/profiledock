import Foundation
import CryptoKit
import DockCore

struct ClaudeBridge {
    let home: URL
    /// Nil is the shared ~/.claude configuration; separate Claude accounts pass their own CLAUDE_CONFIG_DIR.
    var configDirectory: URL? = nil
    var directory: URL { home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeBridge") }
    var helper: URL { directory.appendingPathComponent("ProfileDockClaude") }
    var settings: URL { (configDirectory ?? home.appendingPathComponent(".claude")).appendingPathComponent("settings.json") }
    var originalStatusline: URL { directory.appendingPathComponent(ClaudeBridgeSettings.originalStatuslineName(configDirectory: configDirectory?.standardizedFileURL.path)) }
    private func installed(_ events: [String]) -> Bool { hooksPresent(events) && FileManager.default.isExecutableFile(atPath: helper.path) }
    private func hooksPresent(_ events: [String]) -> Bool {
        guard let data = try? Data(contentsOf: settings), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: [[String: Any]]] else { return false }
        return events.allSatisfy { event in
            (hooks[event] ?? []).contains { group in ((group["hooks"] as? [[String: Any]]) ?? []).contains { ClaudeBridgeSettings.isOurs($0, helper: helper) } }
        }
    }
    var enabled: Bool { installed(ClaudeBridgeSettings.coreEvents) }
    /// The user connected this configuration, even if the installed helper copy has since gone missing.
    var connected: Bool { hooksPresent(ClaudeBridgeSettings.coreEvents) }
    /// False for a connection made before subagent tracking existed. Connecting again adds the hooks and a newer helper.
    var tracksSubagents: Bool { installed(ClaudeBridgeSettings.events) }
    var hasCustomStatusline: Bool {
        guard let data = try? Data(contentsOf: settings), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["statusLine"] as? [String: Any] else { return false }
        return status["command"] as? String != ClaudeBridgeSettings.command(helper: helper, mode: "statusline")
    }
    func setEnabled(_ enabled: Bool, bundledHelper: URL?, hold: Int = AgentInbox.defaultHold) throws {
        let fm = FileManager.default
        for url in [directory, settings] where url.resolvingSymlinksInPath() != url.standardizedFileURL {
            throw CompanionError.message("Claude integration cannot modify a linked settings or helper path.")
        }
        let original = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        var changed = try ClaudeBridgeSettings.updating(original, helper: helper, enabled: enabled, hold: hold)
        let before = try original.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let status = before?["statusLine"] as? [String: Any]
        let ours = ClaudeBridgeSettings.command(helper: helper, mode: "statusline")
        var savedStatus: Data?
        if enabled, let status, status["command"] as? String != ours {
            guard status["type"] as? String == "command", status["command"] is String else { throw CompanionError.message("The existing Claude status line cannot be wrapped safely. Settings were kept.") }
            savedStatus = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            var wrapped = status; wrapped["command"] = ours
            var json = try JSONSerialization.jsonObject(with: changed) as! [String: Any]
            json["statusLine"] = wrapped
            changed = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        } else if !enabled, status?["command"] as? String == ours, fm.fileExists(atPath: originalStatusline.path) {
            guard originalStatusline.resolvingSymlinksInPath() == originalStatusline.standardizedFileURL,
                  let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: originalStatusline)) as? [String: Any] else { throw CompanionError.message("The saved status line could not be restored. Settings were kept.") }
            var json = try JSONSerialization.jsonObject(with: changed) as! [String: Any]
            json["statusLine"] = saved
            changed = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        }
        if enabled {
            guard let bundledHelper, fm.isExecutableFile(atPath: bundledHelper.path) else { throw CompanionError.message("Open the packaged ProfileDock app to connect Claude Code.") }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let savedStatus {
                guard originalStatusline.resolvingSymlinksInPath() == originalStatusline.standardizedFileURL else { throw CompanionError.message("The saved status-line path is linked elsewhere.") }
                try savedStatus.write(to: originalStatusline, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalStatusline.path)
            } else if status == nil, fm.fileExists(atPath: originalStatusline.path) {
                try fm.removeItem(at: originalStatusline)
            }
            try Data(contentsOf: bundledHelper).write(to: helper, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        try write(changed, replacing: original)
    }

    /// Brings a connection made by an older ProfileDock up to date at launch: replaces the installed helper when the
    /// bundled one differs (by SHA-256 hash, a fingerprint of the file's bytes) and adds missing hook groups or changed
    /// hold timeouts. The status line and other tools' hooks are left alone. True when something changed.
    @discardableResult func refresh(bundledHelper: URL?, hold: Int = AgentInbox.defaultHold) throws -> Bool {
        guard connected else { return false }
        let fm = FileManager.default
        for url in [directory, settings] where url.resolvingSymlinksInPath() != url.standardizedFileURL {
            throw CompanionError.message("Claude integration cannot modify a linked settings or helper path.")
        }
        var changed = false
        if let bundledHelper, fm.isExecutableFile(atPath: bundledHelper.path) {
            let bundled = try Data(contentsOf: bundledHelper)
            if (try? Data(contentsOf: helper)).map(Self.digest) != Self.digest(bundled) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bundled.write(to: helper, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                changed = true
            }
        }
        let original = try Data(contentsOf: settings)
        let updated = try ClaudeBridgeSettings.updating(original, helper: helper, enabled: true, hold: hold, statusline: false)
        if try JSONSerialization.jsonObject(with: original) as? NSDictionary != JSONSerialization.jsonObject(with: updated) as? NSDictionary {
            try write(updated, replacing: original)
            changed = true
        }
        return changed
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static let backupPrefix = "settings.profiledock-backup-"

    /// Writes new settings after backing up the old ones. Only the newest ProfileDock backup is kept.
    private func write(_ changed: Data, replacing original: Data?) throws {
        let fm = FileManager.default, folder = settings.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Compare immediately before writing, so concurrent editor changes are not silently overwritten.
        let current = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        guard current == original else { throw CompanionError.message("Claude settings changed during setup. Try again to keep those changes.") }
        if let original {
            let backup = folder.appendingPathComponent(Self.backupPrefix + UUID().uuidString + ".json")
            try original.write(to: backup, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            let older = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []).filter {
                $0.lastPathComponent.hasPrefix(Self.backupPrefix) && $0.pathExtension == "json" && $0.lastPathComponent != backup.lastPathComponent
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            for url in older { try? fm.removeItem(at: url) }
        }
        try changed.write(to: settings, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }
}
