import XCTest
@testable import ContextCore

final class ContextConnectionTests: XCTestCase {
    func testConnectUsesFixedCallerAndPreservesUnrelatedConfigurationAndRevokesOnDisconnect() throws {
        let f = try ContextFixture(); defer { f.remove() }
        let profile = try XCTUnwrap(f.registry.profiles().first { $0.id == "default" })
        let helper = f.home.appendingPathComponent("fixture-helper")
        try Data("fixture executable".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = ConnectionRecorder()
        let connection = ContextConnection(registry: f.registry, codex: URL(fileURLWithPath: "/fixture/codex"), run: { try runner.run($0, $1, $2) })
        XCTAssertFalse(try connection.isConnected(profile))
        try f.allow("default", "two")
        let skill = ContextConnection.skillMarker + "\nfixture skill"
        try connection.connect(profile, helper: helper, skill: skill)
        XCTAssertTrue(try connection.isConnected(profile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.root(in: f.home).appendingPathComponent("skills/\(ContextMentions.skillName(for: "two", alias: "@worktwo"))/SKILL.md").path))
        try connection.connect(profile, helper: helper, skill: skill)
        try Data("changed externally".utf8).write(to: f.registry.helperURL)
        XCTAssertThrowsError(try connection.connect(profile, helper: helper, skill: skill))
        XCTAssertEqual(runner.arguments.first { $0.first == "mcp" && $0[1] == "add" }, ["mcp", "add", "profiledock-context", "--", f.registry.helperURL.path, "mcp", "--profile", "default", "--home", f.home.path])
        XCTAssertTrue(runner.environments.allSatisfy { $0["CODEX_HOME"] == f.home.appendingPathComponent(".codex").path })
        try f.allow("default", "two")
        try connection.disconnect(profile)
        XCTAssertFalse(try connection.isConnected(profile)); XCTAssertFalse(try f.registry.access().allows(caller: "default", source: "two"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.root(in: f.home).appendingPathComponent("skills/profiledock-context/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.root(in: f.home).appendingPathComponent("skills/\(ContextMentions.skillName(for: "two", alias: "@worktwo"))/SKILL.md").path))
    }

    func testUnrelatedServerAndCustomSkillAreNeverOverwritten() throws {
        let f = try ContextFixture(); defer { f.remove() }
        let profile = try XCTUnwrap(f.registry.profiles().first { $0.id == "default" })
        let runner = ConnectionRecorder()
        runner.entry = ["enabled": true, "transport": ["type": "stdio", "command": "/custom/other", "args": []]]
        let connection = ContextConnection(registry: f.registry, codex: URL(fileURLWithPath: "/fixture/codex"), run: { try runner.run($0, $1, $2) })
        XCTAssertThrowsError(try connection.isConnected(profile))
        let helper = f.home.appendingPathComponent("fixture-helper")
        try Data("fixture".utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertThrowsError(try connection.connect(profile, helper: helper, skill: ContextConnection.skillMarker))
        XCTAssertFalse(runner.arguments.contains { $0.contains("add") })
        runner.entry = nil
        let skill = profile.root(in: f.home).appendingPathComponent("skills/profiledock-context/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("custom user instructions".utf8).write(to: skill)
        XCTAssertThrowsError(try connection.connect(profile, helper: helper, skill: ContextConnection.skillMarker))
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "custom user instructions")
    }
}

private final class ConnectionRecorder: @unchecked Sendable {
    var entry: [String: Any]?
    var arguments: [[String]] = []
    var environments: [[String: String]] = []
    private let lock = NSLock()
    func run(_ executable: URL, _ arguments: [String], _ environment: [String: String]) throws -> ContextCommandResult {
        lock.lock(); defer { lock.unlock() }
        self.arguments.append(arguments); environments.append(environment)
        if arguments[1] == "get" {
            guard let entry else { return ContextCommandResult(status: 1, output: "", error: "Error: No MCP server named 'profiledock-context' found.") }
            return ContextCommandResult(status: 0, output: String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self), error: "")
        }
        if arguments[1] == "add" { entry = ["enabled": true, "transport": ["type": "stdio", "command": arguments[4], "args": Array(arguments.dropFirst(5))]] }
        if arguments[1] == "remove" { entry = nil }
        return ContextCommandResult(status: 0, output: "", error: "")
    }
}
