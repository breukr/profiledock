import XCTest
@testable import DockCore

final class ClaudeCredentialServiceTests: XCTestCase {
    private let vector = "/Users/sambreuker/Library/Application Support/Account Dock/Companions/profile-dfa4faef-a862-48db-b40b-24bb0c93922d/claude-config"

    func testServiceNameMatchesClaudeCodeRule() {
        XCTAssertEqual(ClaudeCredentialService.name(configDirectory: nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudeCredentialService.name(configDirectory: vector), "Claude Code-credentials-61c5286b")
        // No path normalization: a trailing slash is a different CLAUDE_CONFIG_DIR, and therefore a different item.
        XCTAssertNotEqual(ClaudeCredentialService.name(configDirectory: vector + "/"), ClaudeCredentialService.name(configDirectory: vector))
        // Unicode is NFC-normalized first, so composed and decomposed spellings name the same item.
        XCTAssertEqual(ClaudeCredentialService.name(configDirectory: "/Users/r\u{e9}my/claude"), ClaudeCredentialService.name(configDirectory: "/Users/re\u{301}my/claude"))
    }

    func testLaunchEnvironmentAndCredentialUseTheSameConfigString() throws {
        var profile = Profile(id: "profile-dfa4faef-a862-48db-b40b-24bb0c93922d", name: "Work", color: "C97B5D")
        profile.provider = .claude; profile.separateClaudeAccount = true
        let home = URL(fileURLWithPath: "/Users/sambreuker")
        let arguments = try XCTUnwrap(ProfileLaunch.claudeArguments(profile: profile, home: home, application: URL(fileURLWithPath: "/Applications/Claude.app")))
        let launched = try XCTUnwrap(arguments.first { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }).dropFirst("CLAUDE_CONFIG_DIR=".count)
        XCTAssertEqual(String(launched), profile.claudeConfigPath(in: home))
        XCTAssertEqual(String(launched), vector)
        XCTAssertEqual(ClaudeCredentialService.name(configDirectory: profile.claudeConfigPath(in: home)), "Claude Code-credentials-61c5286b")
        var shared = profile; shared.separateClaudeAccount = nil
        XCTAssertNil(shared.claudeConfigPath(in: home))
        XCTAssertEqual(ClaudeCredentialService.name(configDirectory: shared.claudeConfigPath(in: home)), "Claude Code-credentials")
    }

    func testWebDataStoreIdentifierIsStablePerAccount() {
        let first = ClaudeCredentialService.webDataStoreIdentifier(configDirectory: vector)
        XCTAssertEqual(first, ClaudeCredentialService.webDataStoreIdentifier(configDirectory: vector))
        XCTAssertNotEqual(first, ClaudeCredentialService.webDataStoreIdentifier(configDirectory: vector + "-other"))
        XCTAssertEqual(first.uuidString[first.uuidString.index(first.uuidString.startIndex, offsetBy: 14)], "5")
    }
}
