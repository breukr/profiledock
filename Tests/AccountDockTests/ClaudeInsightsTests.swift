import XCTest
import DockCore
@testable import AccountDock

final class ClaudeInsightsTests: XCTestCase {
    func testStreamingDuplicatesAreCountedOnceAndProjectOwnsSharedHistory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var desktop = Profile(id: "desktop", name: "Assistant", color: "123456"); desktop.provider = .claude
        var project = Profile(id: "project", name: "Project", color: "123456"); project.provider = .claudeCode; project.projectPath = "/fixture"
        var data = Data()
        for output in [1, 10, 10] {
            let record: [String: Any] = ["type": "assistant", "cwd": "/fixture", "timestamp": "2026-09-23T08:00:00Z", "message": ["id": "same-response", "model": "claude-sonnet-5", "usage": ["input_tokens": 100, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 40, "output_tokens": output]]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        try data.write(to: folder.appendingPathComponent("session-one.jsonl"))
        try Data("invalid-json\n".utf8).write(to: folder.appendingPathComponent("damaged-session.jsonl"))
        let result = try ClaudeInsights.scan(profiles: [desktop, project], home: home, cutoff: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertTrue(result.warnings[project.id]?.contains("could not be read") == true)
        let sample = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(sample.profileID, project.id)
        XCTAssertEqual(sample.tokens.input, 340)
        XCTAssertEqual(sample.tokens.output, 10)
        XCTAssertEqual(try XCTUnwrap(sample.estimatedCost), 0.00044, accuracy: 0.0000001)
        XCTAssertNil(ClaudePricing.estimate(model: "unknown", usage: [:], tokens: sample.tokens))
        XCTAssertNil(ClaudePricing.estimate(model: "claude-sonnet-5", usage: ["speed": "fast"], tokens: sample.tokens))
    }
}
