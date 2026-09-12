import Foundation
import XCTest
import DockCore
@testable import AccountDock

private final class PausedDownload: URLProtocol {
    static var started: XCTestExpectation?
    static var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 1024))
        Self.started?.fulfill()
        // Remain pending until the caller cancels. No real network or installed app is touched.
    }
    override func stopLoading() { Self.stopped?.fulfill() }
}

final class DownloadCancellationTests: XCTestCase {
    func testCancellingStopsNetworkAndNeverExtractsOrInstalls() async throws {
        let start = expectation(description: "download started"), stop = expectation(description: "download stopped")
        PausedDownload.started = start; PausedDownload.stopped = stop
        defer { PausedDownload.started = nil; PausedDownload.stopped = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PausedDownload.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>1</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
        <enclosure url="https://persistent.oaistatic.com/codex-app-prod/test.zip" sparkle:os="macos" sparkle:arch="arm64" length="1000000" sparkle:edSignature="\(Data(repeating: 0, count: 64).base64EncodedString())"/>
        </item></channel></rss>
        """
        let release = try XCTUnwrap(UpdateFeed.latest(data: Data(xml.utf8), architecture: "arm64", systemVersion: "14.0"))
        let task = Task { try await VendorDownload.prepare(release, in: root, configuration: config) }
        await fulfillment(of: [start], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download succeeded") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fulfillment(of: [stop], timeout: 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    @MainActor func testOldPreferencesKeepProfilesAndQuietSoundDefaults() throws {
        let old = Data("{\"profiles\":[{\"id\":\"default\",\"name\":\"Personal\",\"color\":\"377CF6\"}],\"scale\":1.3}".utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertEqual(preferences.profiles.first?.id, "default")
        XCTAssertEqual(preferences.scale, 1.3)
        XCTAssertNil(preferences.activitySounds)
        XCTAssertNil(preferences.activityCues)
    }
}
