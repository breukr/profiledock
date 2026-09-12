import XCTest
@testable import DockCore

final class ProfileTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/example")
    let profiles = [Profile(id: "default", name: "Personal", color: "377CF6"), Profile(id: "test", name: "Work", color: "009B87"), Profile(id: "test-2", name: "Second", color: "955CE5")]
    let executable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

    func testExactProfileMatchAndNoPrefixCollisions() {
        XCTAssertEqual(ProcessIdentity.profileID(arguments: [executable, "--user-data-dir=/Users/example/.codex-test/electron-user-data"], profiles: profiles, home: home), "test")
        XCTAssertEqual(ProcessIdentity.profileID(arguments: [executable, "--user-data-dir", "/Users/example/.codex-test-2/electron-user-data"], profiles: profiles, home: home), "test-2")
        XCTAssertNil(ProcessIdentity.profileID(arguments: [executable, "--user-data-dir=/tmp/unknown"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.profileID(arguments: [executable, "--user-data-dir"], profiles: profiles, home: home))
    }

    func testDefaultAndHelpers() {
        XCTAssertEqual(ProcessIdentity.profileID(arguments: [executable], profiles: profiles, home: home), "default")
        XCTAssertEqual(ProcessIdentity.profileID(arguments: [executable, "--user-data-dir=/Users/example/Library/Application Support/Codex"], profiles: profiles, home: home), "default")
        XCTAssertNil(ProcessIdentity.profileID(arguments: ["/Applications/ChatGPT.app/Contents/Frameworks/ChatGPT (Renderer)"], profiles: profiles, home: home))
        XCTAssertNil(ProcessIdentity.profileID(arguments: [], profiles: profiles, home: home))
    }

    func testArgvDecoderStopsBeforeEnvironmentAndHandlesSpaces() {
        let argv = [executable, "--user-data-dir=/Users/example/Library/Application Support/Codex", ""]
        var data = Data([3, 0, 0, 0])
        data.append(Data((executable + "\0\0\0" + argv.joined(separator: "\0") + "\0SECRET=must-not-be-returned\0").utf8))
        XCTAssertEqual(ProcessIdentity.arguments(from: data), argv)
        XCTAssertNil(ProcessIdentity.arguments(from: Data([1, 0, 0, 0, 65])))
    }

    func testCatalogUsesRealLaunchersAndKeepsCustomOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent(".config/codex-profile/launchers")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        for path in [".codex", ".codex-test"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try "test\nChatGPT Work\nteal\n/Applications/Example.app\n".write(to: registry.appendingPathComponent("test.state"), atomically: true, encoding: .utf8)
        try "missing\nMissing\npurple\n/example\n".write(to: registry.appendingPathComponent("missing.state"), atomically: true, encoding: .utf8)
        let discovered = try ProfileCatalog.discover(home: root)
        XCTAssertEqual(discovered.map(\.id), ["default", "test"])
        let custom = Profile(id: "test", name: "Custom", color: "ABCDEF")
        let merged = ProfileCatalog.merge(discovered: discovered, saved: [custom, custom, Profile(id: "removed", name: "Old", color: "000000")])
        XCTAssertEqual(merged.map(\.id), ["test", "default"])
        XCTAssertEqual(merged.first, custom)
    }
}
