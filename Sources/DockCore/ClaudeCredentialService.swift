import Foundation
import CryptoKit

/// Claude Code's Keychain naming: one generic-password item per CLAUDE_CONFIG_DIR, account = the macOS user name.
public enum ClaudeCredentialService {
    public static let shared = "Claude Code-credentials"

    /// `configDirectory` must be the exact CLAUDE_CONFIG_DIR string. Claude Code hashes it after NFC normalization only,
    /// without resolving trailing slashes or symlinks, so callers pass the same string ProfileDock launches with.
    public static func name(configDirectory: String?) -> String {
        guard let configDirectory else { return shared }
        return shared + "-" + hex(SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8)).prefix(4))
    }

    /// Stable per-account identifier for ProfileDock's own saved-resets web session.
    public static func webDataStoreIdentifier(configDirectory: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("ProfileDock.ClaudeResetConnection\n" + configDirectory).utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0f | 0x50; bytes[8] = bytes[8] & 0x3f | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}
