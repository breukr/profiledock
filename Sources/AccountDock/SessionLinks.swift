import AppKit
import Carbon
import DockCore

/// Deep links that open one exact chat in its desktop app, the same links those apps use in their own menus:
/// Claude Desktop's `claude://code/continue?session=local_…` and the Codex app's `codex://threads/<id>`.
enum SessionLinks {
    /// Claude Desktop's own folder of Code-session records for an account (a separate account has its own app data).
    static func claudeSessionsRoot(for profile: Profile?, home: URL) -> URL {
        (profile?.claudeUserDataDirectory(in: home) ?? home.appendingPathComponent("Library/Application Support/Claude"))
            .appendingPathComponent("claude-code-sessions")
    }

    /// Claude Desktop's `local_…` id for a Claude Code session id. Desktop keeps one small JSON record per Code
    /// session (`<root>/<account>/<org>/local_<id>.json`) that lists the Claude Code session ids it has used; the
    /// newest records are searched first, and only files that contain the id are parsed.
    static func claudeLocalSession(forCLISession id: String, root: URL, limit: Int = 800) -> String? {
        guard id.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil else { return nil }
        let fm = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for organization in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: organization, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    files.append((file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
                }
            }
        }
        let needle = Data(id.utf8)
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(limit) {
            guard let data = try? Data(contentsOf: file.url), data.count < 4_000_000, data.range(of: needle) != nil,
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let local = record["sessionId"] as? String, validLocal(local) else { continue }
            let used = [record["cliSessionId"], record["lastAssistantCliSessionId"]].compactMap { $0 as? String }
                + ((record["previousCliSessionIds"] as? [String]) ?? [])
            if used.contains(id) { return local }
        }
        return nil
    }

    /// Desktop accepts only `local_` followed by up to 64 letters, digits and dashes.
    static func validLocal(_ id: String) -> Bool { id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil }
    static func claudeURL(local: String) -> URL? { validLocal(local) ? URL(string: "claude://code/continue?session=\(local)") : nil }
    static func codexURL(thread: String) -> URL? {
        thread.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) == nil ? nil : URL(string: "codex://threads/\(thread)")
    }

    /// Hands the link to one running app instance, because two Claude or ChatGPT copies (separate accounts) can run
    /// side by side and the system would pick either one. Without a known instance the system chooses the app.
    @MainActor static func open(_ url: URL, processIdentifier: pid_t?) {
        if let pid = processIdentifier {
            // kAEGetURL is the Apple Event macOS itself sends when a link is opened ("GURL"), aimed at one process.
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
            if (try? event.sendEvent(options: [.noReply], timeout: 2)) != nil {
                try? ApplicationReopen.activate(processIdentifier: pid)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}
