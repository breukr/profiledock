import AppKit
import XCTest
import Sparkle

@MainActor private final class FeedProbe: NSObject, SPUUpdaterDelegate {
    var loaded: (() -> Void)?
    var failure: Error?
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { loaded?() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { failure = error }
}

final class ProfileDockUpdateTests: XCTestCase {
    @MainActor func testPackagedSparkleAcceptsPublicSignedFeedWithoutInstalling() async throws {
        guard let appPath = ProcessInfo.processInfo.environment["PROFILEDOCK_APP_PATH"],
              ProcessInfo.processInfo.environment["PROFILEDOCK_VERIFY_FEED"] == "1" else { throw XCTSkip("Opt-in public signed feed verification") }
        _ = NSApplication.shared
        let bundle = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: appPath)))
        let accepted = expectation(description: "Sparkle accepted signed public feed")
        let probe = FeedProbe(); probe.loaded = { accepted.fulfill() }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: probe)
        try updater.start()
        updater.checkForUpdateInformation()
        await fulfillment(of: [accepted], timeout: 30)
        withExtendedLifetime(updater) {}
    }
}
