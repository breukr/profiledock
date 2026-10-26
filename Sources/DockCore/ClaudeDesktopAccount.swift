import Foundation

/// The account a Claude Desktop instance is signed in to. Its Code tab passes that account's own token to each
/// session, so it can differ from Claude Code's CLI sign-in, which is what account usage reads.
public enum ClaudeDesktopAccount {
    /// The instance's data folder: a separate account's own folder, otherwise Claude's shared one. Nil for tiles without Claude Desktop.
    public static func dataDirectory(for profile: Profile, home: URL) -> URL? {
        guard profile.kind == .claude else { return nil }
        return profile.claudeUserDataDirectory(in: home) ?? home.appendingPathComponent("Library/Application Support/Claude")
    }

    /// `lastKnownAccountUuid` from the instance's `config.json`, lowercased. Nil when missing, oversized or not a UUID.
    public static func accountID(for profile: Profile, home: URL) -> String? {
        guard let folder = dataDirectory(for: profile, home: home),
              let id = json(folder.appendingPathComponent("config.json"))?["lastKnownAccountUuid"] as? String,
              UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    /// The email Claude Code recorded for `accountID` in the profile's configuration (`~/.claude.json` for the shared sign-in).
    /// Only pre-fills the sign-in page; nil when that configuration last saw another account.
    public static func email(for profile: Profile, accountID: String, home: URL) -> String? {
        let file = profile.claudeConfigDirectory(in: home)?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json")
        guard let account = json(file)?["oauthAccount"] as? [String: Any],
              (account["accountUuid"] as? String)?.lowercased() == accountID.lowercased(),
              let email = account["emailAddress"] as? String, email.count <= 254, email.contains("@"), !email.hasPrefix("-"),
              email.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return email
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
