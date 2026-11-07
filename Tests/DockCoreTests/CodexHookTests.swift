import XCTest
@testable import DockCore

final class CodexHookTests: XCTestCase {
    private let helper = URL(fileURLWithPath: "/fixture/helper")

    func testCodexHooksMergeIdempotentlyAndKeepOtherTools() throws {
        let original = Data(#"{"description":"Fixture hooks","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool stop","timeout":30}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-tool check"}]}]}}"#.utf8)
        let first = try CodexBridgeSettings.updating(original, helper: helper, enabled: true)
        XCTAssertEqual(first, try CodexBridgeSettings.updating(first, helper: helper, enabled: true))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(json["description"] as? String, "Fixture hooks")
        XCTAssertEqual(Set(hooks.keys), ["Stop", "PreToolUse", "PermissionRequest"])
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        for event in CodexBridgeSettings.events {
            let ours = try XCTUnwrap(hooks[event]?.last?["hooks"] as? [[String: Any]]).first
            XCTAssertEqual(ours?["command"] as? String, "[ -x '/fixture/helper' ] && '/fixture/helper' codex; exit 0")
            // Only Stop waits (for a reply); permission requests are reported and return at once.
            XCTAssertEqual(ours?["timeout"] as? Int, event == "Stop" ? 615 : 5)
        }
        XCTAssertTrue(CodexBridgeSettings.isConnected(first, helper: helper)); XCTAssertFalse(CodexBridgeSettings.isConnected(original, helper: helper))
        // Entries from the earlier plain command are recognized, reported as outdated and replaced in place.
        let legacy = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/fixture/helper' codex","timeout":5}]}]}}"#.utf8)
        XCTAssertTrue(CodexBridgeSettings.hasEntries(legacy, helper: helper)); XCTAssertFalse(CodexBridgeSettings.isConnected(legacy, helper: helper))
        let upgraded = try parsedCodexHooks(CodexBridgeSettings.updating(legacy, helper: helper, enabled: true))
        XCTAssertEqual(upgraded["Stop"]?.count, 1)
        let removed = try CodexBridgeSettings.updating(first, helper: helper, enabled: false)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        XCTAssertThrowsError(try CodexBridgeSettings.updating(Data(#"{"hooks":{"Stop":{}}}"#.utf8), helper: helper, enabled: true))
        XCTAssertThrowsError(try CodexBridgeSettings.updating(Data("[]".utf8), helper: helper, enabled: true))
    }

    private func parsedCodexHooks(_ data: Data) throws -> [String: [[String: Any]]] {
        try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
    }

    func testApplyWritesAPrivateFileAndRefusesLinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex"), file = codex.appendingPathComponent("hooks.json")
        try CodexBridgeSettings.apply(codexHome: codex, helper: helper, enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Disconnecting never creates the file")
        try CodexBridgeSettings.apply(codexHome: codex, helper: helper, enabled: true)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["hooks"])
        try CodexBridgeSettings.apply(codexHome: codex, helper: helper, enabled: false)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["hooks"] as? NSDictionary, [:])

        let target = home.appendingPathComponent("elsewhere.json"), linked = home.appendingPathComponent("linked")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("hooks.json"), withDestinationURL: target)
        XCTAssertThrowsError(try CodexBridgeSettings.apply(codexHome: linked, helper: helper, enabled: true))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
    }

    func testCodexEventsBecomeDisplayOnlyItems() {
        let request: [String: Any] = ["session_id": "thr-fixture", "cwd": "/fixture/project", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                      "tool_input": ["command": "make fixture", "description": "Needs network access"]]
        guard case .attention(let item, nil)? = CodexAttentionHook.message(payload: request, codexHome: "/fixture/.codex") else { return XCTFail() }
        XCTAssertEqual(item.source, "codex"); XCTAssertEqual(item.kind, .permission); XCTAssertNil(item.deadline)
        XCTAssertEqual(item.title, "Run a command?"); XCTAssertEqual(item.preview, "make fixture"); XCTAssertEqual(item.message, "Needs network access")
        XCTAssertEqual(item.configDirectory, "/fixture/.codex"); XCTAssertEqual(item.cwd, "/fixture/project")
        guard case .attention(let patch, _)? = CodexAttentionHook.message(payload: request.merging(["tool_name": "apply_patch", "tool_input": ["command": "*** Begin Patch"]]) { _, new in new }, codexHome: nil) else { return XCTFail() }
        XCTAssertEqual(patch.title, "Edit files?"); XCTAssertEqual(patch.message, "Codex wants to use apply_patch.")
        guard case .attention(let done, _)? = CodexAttentionHook.message(payload: ["session_id": "thr-fixture", "hook_event_name": "Stop", "last_assistant_message": "Finished"], codexHome: "relative") else { return XCTFail() }
        XCTAssertEqual(done.kind, .finished); XCTAssertEqual(done.message, "Finished"); XCTAssertNil(done.configDirectory)
        XCTAssertNil(CodexAttentionHook.message(payload: request.merging(["agent_id": "sub"]) { _, new in new }, codexHome: nil))
        XCTAssertNil(CodexAttentionHook.message(payload: ["session_id": "thr-fixture", "hook_event_name": "PreToolUse"], codexHome: nil))
        XCTAssertNil(CodexAttentionHook.message(payload: ["hook_event_name": "Stop"], codexHome: nil))
    }
}
