import Foundation
import DockCore

struct ClaudeBridge {
    let home: URL
    var directory: URL { home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeBridge") }
    var helper: URL { directory.appendingPathComponent("ProfileDockClaude") }
    var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    var originalStatusline: URL { directory.appendingPathComponent("original-statusline.json") }
    var enabled: Bool {
        guard let data = try? Data(contentsOf: settings), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: [[String: Any]]] else { return false }
        return ClaudeBridgeSettings.events.allSatisfy { event in
            (hooks[event] ?? []).contains { group in ((group["hooks"] as? [[String: Any]]) ?? []).contains { ClaudeBridgeSettings.isOurs($0, helper: helper) } }
        } && FileManager.default.isExecutableFile(atPath: helper.path)
    }
    var hasCustomStatusline: Bool {
        guard let data = try? Data(contentsOf: settings), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["statusLine"] as? [String: Any] else { return false }
        return status["command"] as? String != ClaudeBridgeSettings.command(helper: helper, mode: "statusline")
    }
    func setEnabled(_ enabled: Bool, bundledHelper: URL?) throws {
        let fm = FileManager.default
        for url in [directory, settings] where url.resolvingSymlinksInPath() != url.standardizedFileURL {
            throw CompanionError.message("Claude integration cannot modify a linked settings or helper path.")
        }
        let original = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        var changed = try ClaudeBridgeSettings.updating(original, helper: helper, enabled: enabled)
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
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Compare immediately before writing, so concurrent editor changes are not silently overwritten.
        let current = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        guard current == original else { throw CompanionError.message("Claude settings changed during setup. Try again to keep those changes.") }
        if let original {
            let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.profiledock-backup-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try changed.write(to: settings, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }
}
