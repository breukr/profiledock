import XCTest
import DockCore
@testable import ContextCore

final class ContextMentionsTests: XCTestCase {
    private func caller(_ f: ContextFixture) throws -> ContextProfile { try XCTUnwrap(f.registry.profiles().first { $0.id == "default" }) }
    private func url(_ f: ContextFixture, _ path: String) -> URL {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return f.home.appendingPathComponent(".codex/skills") }
        return f.home.appendingPathComponent(".codex/skills/" + ContextMentions.skillName(for: first) + "/" + parts.dropFirst().joined(separator: "/"))
    }
    private func rename(_ f: ContextFixture, two: String, other: String = "Private") throws {
        let profiles = [Profile(id: "default", name: "Work One", color: "000000"), Profile(id: "two", name: two, color: "000000"), Profile(id: "private", name: other, color: "000000")]
        struct Preferences: Encodable { let profiles: [Profile] }
        try JSONEncoder().encode(Preferences(profiles: profiles)).write(to: f.home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json"))
    }

    func testAllowedSourcesCreateDiscoverableSkillsWithFixedSourceAndCaller() throws {
        let f = try ContextFixture(); defer { f.remove() }
        let c = try caller(f), mentions = ContextMentions(registry: f.registry)
        XCTAssertEqual(try mentions.synchronize(c), [])
        try f.allow("default", "two")
        XCTAssertEqual(try mentions.synchronize(c), ["worktwo"])
        let skill = try String(contentsOf: url(f, "two/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.contains("name: \(ContextMentions.skillName(for: "two"))\n"))
        XCTAssertTrue(skill.contains("source profile ID `two` for receiving profile ID `default`"))
        let metadata = try String(contentsOf: url(f, "two/agents/openai.yaml"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("value: \"profiledock-context\""))
        XCTAssertTrue(metadata.contains("display_name: \"worktwo\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(f, "private/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".codex-two/skills/worktwo/SKILL.md").path))
        XCTAssertEqual(try mentions.synchronize(c), ["worktwo"])
    }

    func testRenameAndRevocationRemoveOldMentionsButKeepExtraUserFiles() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        let c = try caller(f), mentions = ContextMentions(registry: f.registry)
        try mentions.synchronize(c)
        try Data("personal notes".utf8).write(to: url(f, "two/notes.txt"))
        try rename(f, two: "Research")
        XCTAssertEqual(try mentions.synchronize(c), ["research"])
        XCTAssertTrue(try String(contentsOf: url(f, "two/agents/openai.yaml"), encoding: .utf8).contains("display_name: \"research\""))
        XCTAssertEqual(try String(contentsOf: url(f, "two/notes.txt"), encoding: .utf8), "personal notes")
        var access = try f.registry.access(); access.set(caller: "default", source: "two", allowed: false); try f.registry.save(access)
        XCTAssertEqual(try mentions.synchronize(c), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(f, "two/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(f, "two/agents/openai.yaml").path))
        try f.allow("default", "two"); try mentions.synchronize(c); try mentions.remove(c)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(f, "two/SKILL.md").path))
    }

    func testCustomOrEditedSkillsAreNeverOverwritten() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        let c = try caller(f), mentions = ContextMentions(registry: f.registry), custom = url(f, "two/SKILL.md")
        try FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing skill".utf8).write(to: custom)
        XCTAssertThrowsError(try mentions.synchronize(c))
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "existing skill")
        try FileManager.default.removeItem(at: custom)
        try mentions.synchronize(c)
        let metadata = url(f, "two/agents/openai.yaml")
        try Data("custom metadata".utf8).write(to: metadata)
        XCTAssertThrowsError(try mentions.synchronize(c))
        XCTAssertThrowsError(try mentions.remove(c))
        XCTAssertEqual(try String(contentsOf: metadata, encoding: .utf8), "custom metadata")
    }

    func testAmbiguousLongAndUnicodeAliasesHaveDistinctValidNames() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two"); try f.allow("default", "private")
        let c = try caller(f), mentions = ContextMentions(registry: f.registry)
        try rename(f, two: "Research", other: "Research")
        let names = try mentions.synchronize(c)
        XCTAssertEqual(Set(names).count, 2)
        XCTAssertEqual(names, ["research · two", "research · private"])
        try rename(f, two: String(repeating: "a", count: 80), other: "研究")
        XCTAssertEqual(try mentions.synchronize(c), [String(repeating: "a", count: 64), "研究"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(f, "two/SKILL.md").path))
    }

    func testSymlinkedSkillDirectoriesAndForgedReceiptPathsAreRejected() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two")
        let c = try caller(f), mentions = ContextMentions(registry: f.registry), fm = FileManager.default
        let outside = f.home.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: url(f, ""), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url(f, "two"), withDestinationURL: outside)
        XCTAssertThrowsError(try mentions.synchronize(c))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        try fm.removeItem(at: url(f, "two"))
        try f.registry.createPrivateDirectory()
        let receipt = f.registry.directory.appendingPathComponent("mentions-default.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "files": ["skills/../../outside/SKILL.md": "bad"]]).write(to: receipt)
        XCTAssertThrowsError(try mentions.remove(c))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testReusingAProfileNameNeverRebindsAnExistingMentionPath() throws {
        let f = try ContextFixture(); defer { f.remove() }; try f.allow("default", "two"); try f.allow("default", "private")
        let c = try caller(f), mentions = ContextMentions(registry: f.registry)
        try mentions.synchronize(c)
        let selectedPath = url(f, "two/SKILL.md")
        try rename(f, two: "Research", other: "Work Two")
        try mentions.synchronize(c)
        let selected = try String(contentsOf: selectedPath, encoding: .utf8)
        XCTAssertTrue(selected.contains("source profile ID `two`"))
        XCTAssertFalse(selected.contains("source profile ID `private`"))
        XCTAssertTrue(try String(contentsOf: url(f, "private/SKILL.md"), encoding: .utf8).contains("source profile ID `private`"))
        XCTAssertTrue(try String(contentsOf: url(f, "private/agents/openai.yaml"), encoding: .utf8).contains("display_name: \"worktwo\""))
    }
}
