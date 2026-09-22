import XCTest
@testable import DockCore

final class NativeDockTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/example")
    let profile = Profile(id: "work", name: "Work", color: "377CF6")
    var vendor: [String: Any] { ["CFBundleExecutable": "ChatGPT", "CFBundleName": "ChatGPT", "CFBundleIdentifier": "com.openai.codex", "CFBundleVersion": "100", "CFBundleIconName": "ChatGPT", "CFBundleURLTypes": [], "CFBundleDocumentTypes": [], "UTExportedTypeDeclarations": [], "SUFeedURL": "https://example.com/feed", "SUPublicEDKey": "example", "ElectronAsarIntegrity": ["hash": "unchanged"]] }

    func testWrapperIdentityPreservesElectronHelpersAndDropsVendorRegistrationsAndUpdateFeed() throws {
        let info = try NativeDock.patchedInfo(vendor, profile: profile, home: home, data: home.appendingPathComponent("data"))
        XCTAssertEqual(info["CFBundleName"] as? String, "ChatGPT")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, NativeDock.identifier(profile))
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "ChatGPT Work")
        XCTAssertEqual(info["ElectronAsarIntegrity"] as? [String: String], ["hash": "unchanged"])
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        for key in ["CFBundleIconName", "CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "SUFeedURL", "SUPublicEDKey"] { XCTAssertNil(info[key], key) }
        XCTAssertEqual(info[NativeDock.homeKey] as? String, "/Users/example/.codex-work")
    }

    func testShimCannotBeRedirectedByInheritedOrCommandLineProfileOverrides() throws {
        let info = try NativeDock.patchedInfo(vendor, profile: profile, home: home, data: home.appendingPathComponent("data with spaces"))
        let launch = try NativeDock.launchParameters(info: info, arguments: ["--user-data-dir=/wrong", "--user-data-dir", "/wrong again", "-psn_0_123", "--flag", "value"])
        XCTAssertEqual(launch.home, "/Users/example/.codex-work")
        XCTAssertEqual(launch.arguments, ["--user-data-dir=/Users/example/data with spaces", "--flag", "value"])
        for key in [NativeDock.profileKey, NativeDock.homeKey, NativeDock.dataKey, "CFBundleIdentifier"] {
            var bad = info; bad.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeDock.launchParameters(info: bad, arguments: []), key)
        }
        for path in ["relative/path", "", "/path\0elsewhere"] {
            var bad = info; bad[NativeDock.homeKey] = path
            XCTAssertThrowsError(try NativeDock.launchParameters(info: bad, arguments: []))
        }
    }

    func testEntitlementsRemoveTeamScopedAccessRecursivelyButKeepRuntimePermissions() {
        let result = NativeDock.entitlements(["com.apple.developer.team-identifier": "TEAM", "keychain-access-groups": ["TEAM.secret"], "com.apple.security.cs.allow-jit": true, "com.apple.security.device.camera": true, "extra": ["nested": ["TEAM.secret", "keep"]]], team: "TEAM")
        XCTAssertNil(result["com.apple.developer.team-identifier"])
        XCTAssertNil(result["keychain-access-groups"])
        XCTAssertEqual(result["com.apple.security.cs.allow-jit"] as? Bool, true)
        XCTAssertEqual(result["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertEqual(result["com.apple.security.cs.disable-library-validation"] as? Bool, true)
        XCTAssertEqual(result["extra"] as? [String: [String]], ["nested": ["keep"]])
    }

    func testOldProfilesRemainOptedOutAndNativeCopiesStayInTheirSourceUpdateGroup() throws {
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"work","name":"Work","color":"377CF6"}"#.utf8))
        XCTAssertNil(old.dockApplicationPath)
        var native = profile; native.dockApplicationPath = "/some/copy.app"
        let groups = AppUpdateGroup.make(profiles: [native, Profile(id: "default", name: "Personal", color: "377CF6")], defaultApplication: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        XCTAssertEqual(groups.flatMap(\.profiles).map(\.id), ["work", "default"])
        XCTAssertEqual(groups[0].application.path, "/Applications/ChatGPT.app")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(native)), native)
    }

    func testAnExternalSourceUpdateTriggersLaunchTimeRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Contents/Info.plist")
        func write(_ version: String) throws { try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0).write(to: file) }
        let info: [String: Any] = [NativeDock.sourceKey: root.path, NativeDock.versionKey: "100"]
        try write("100"); XCTAssertFalse(NativeDock.sourceChanged(info))
        try write("101"); XCTAssertTrue(NativeDock.sourceChanged(info))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(NativeDock.sourceChanged(info), "A missing source must not destroy the working copy")
    }
}
