import XCTest
@testable import DockCore

final class ManagementTests: XCTestCase {
    func testFreshProfilesHaveIndependentIDsAndRejectEmptyNames() {
        XCTAssertNil(ProfileLaunch.newProfile(name: "  "))
        XCTAssertNil(ProfileLaunch.newProfile(name: String(repeating: "x", count: 33)))
        let first = ProfileLaunch.newProfile(name: " Work ")!, second = ProfileLaunch.newProfile(name: "Work")!
        XCTAssertEqual(first.name, "Work")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(Profile.validID(first.id))
    }
    func testLaunchArgumentsScopeNewProfilesAndClearStockOverrides() {
        let home = URL(fileURLWithPath: "/Users/example"), app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let work = Profile(id: "work", name: "Work", color: "377CF6")
        let args = ProfileLaunch.arguments(profile: work, home: home, application: app)
        XCTAssertTrue(args.contains("CODEX_HOME=/Users/example/.codex-work"))
        XCTAssertTrue(args.contains("--user-data-dir=/Users/example/.codex-work/electron-user-data"))
        XCTAssertEqual(ProcessIdentity.profileID(arguments: [app.appendingPathComponent("Contents/MacOS/ChatGPT").path] + args, profiles: [work], home: home), "work")
        let stock = ProfileLaunch.arguments(profile: Profile(id: "default", name: "Personal", color: "377CF6"), home: home, application: app)
        XCTAssertTrue(stock.contains("CODEX_ELECTRON_USER_DATA_PATH="))
        XCTAssertTrue(stock.contains("-n"))
        XCTAssertFalse(stock.contains(where: { $0.hasPrefix("--user-data-dir") }))
    }
    func testSharedAppsAreOneRestartGroupAndSeparateCopiesStaySeparate() {
        let profiles = [Profile(id: "a", name: "A", color: "0"), Profile(id: "b", name: "B", color: "0"), Profile(id: "c", name: "C", color: "0", applicationPath: "/Applications/Separate.app")]
        let groups = AppUpdateGroup.make(profiles: profiles, defaultApplication: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.profiles.map(\.id), ["a", "b"])
        XCTAssertEqual(groups.last?.profiles.map(\.id), ["c"])
    }
    func testLayoutsFitNotebookAndExternalScreenGeometriesWithManyProfiles() {
        for width in [1024.0, 1280, 1440, 1728, 2560, 3440] {
            for notch in [0.0, 32, 38] {
                for menu in [24.0, 31, 38] {
                    let screen = CGRect(x: -width, y: -200, width: width, height: 800)
                    let layout = IslandLayout(screen: screen, notchHeight: notch, notchWidth: 220, count: 30, scale: 1.3, hasMessage: true, menuBarHeight: menu, showsResetDetails: true)
                    XCTAssertEqual(layout.collapsed.maxY, screen.maxY)
                    XCTAssertEqual(layout.collapsed.height, notch > 0 ? notch : menu)
                    XCTAssertLessThanOrEqual(layout.expanded.width, width - 32)
                    XCTAssertTrue(screen.contains(layout.expanded))
                }
            }
        }
    }
    func testFeedSkipsDeltasWrongArchitectureAndUnsupportedOS() throws {
        let signature = Data(repeating: 1, count: 64).base64EncodedString()
        func item(_ build: Int, arch: String = "arm64", os: String = "14.0") -> String {
            "<item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>1.\(build)</sparkle:shortVersionString><sparkle:hardwareRequirements>\(arch)</sparkle:hardwareRequirements><sparkle:minimumSystemVersion>\(os)</sparkle:minimumSystemVersion><enclosure url='https://persistent.oaistatic.com/codex-app-prod/full.zip' length='128' sparkle:edSignature='\(signature)'/><sparkle:deltas><enclosure url='https://persistent.oaistatic.com/codex-app-prod/wrong.delta' length='24'/></sparkle:deltas></item>"
        }
        let xml = "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel>" + item(10) + item(11, arch: "x86_64") + item(12, os: "99.0") + "</channel></rss>"
        let release = try UpdateFeed.latest(data: Data(xml.utf8), architecture: "arm64", systemVersion: "14.6")
        XCTAssertEqual(release?.build, 10)
        XCTAssertEqual(release?.url.lastPathComponent, "full.zip")
        XCTAssertNil(try UpdateFeed.latest(data: Data(xml.utf8), architecture: "ppc", systemVersion: "14.6"))
    }
    func testUpdateURLRejectsLookalikeHostsHTTPAndNonArchives() {
        for url in ["http://persistent.oaistatic.com/codex-app-prod/full.zip", "https://persistent.oaistatic.com.evil.example/codex-app-prod/full.zip", "https://persistent.oaistatic.com/codex-app-prod/update.delta", "https://persistent.oaistatic.com:443/codex-app-prod/full.zip"] {
            XCTAssertFalse(VendorRelease.allowedDownload(URL(string: url)!))
        }
    }
}
