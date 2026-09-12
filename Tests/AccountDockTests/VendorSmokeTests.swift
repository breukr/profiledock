import Foundation
import XCTest
import DockCore
@testable import AccountDock

final class VendorSmokeTests: XCTestCase {
    /// Explicit opt-in: downloads a large official archive and verifies it without touching installed apps.
    func testOfficialArchiveSignatureAndAppCopy() async throws {
        guard ProcessInfo.processInfo.environment["PROFILEDOCK_VERIFY_VENDOR"] == "1" else { throw XCTSkip("Opt-in vendor download verification") }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let (data, response) = try await URLSession.shared.data(from: VendorDownload.feed)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let release = try XCTUnwrap(UpdateFeed.latest(data: data, architecture: architecture, systemVersion: "26.0"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-vendor-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await VendorDownload.prepare(release, in: root)
        let copy = root.appendingPathComponent("Separate.app")
        try AppFiles.copyVendorApp(from: prepared, to: copy)
        XCTAssertEqual(AppUpdates.installedBuild(at: copy), release.build)
        try AppFiles.verifyVendorApp(copy)
    }
}
