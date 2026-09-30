import AppKit
import SwiftUI
import XCTest
import DockCore
@testable import AccountDock

private actor DisconnectedUsage: UsageFetching {
    func identity(for profile: Profile) async throws -> String { throw UsageLoadError.notSignedIn }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot { throw UsageLoadError.notSignedIn }
}

final class AccountConnectionRenderingTests: XCTestCase {
    @MainActor func testConnectionNoticeRendersBothProvidersAtNarrowAndWideSizes() async throws {
        _ = NSApplication.shared
        let client = DisconnectedUsage()
        let usage = UsageStore(client: client, claudeClient: client)
        defer { usage.shutdown() }
        var claude = Profile(id: "claude", name: "Claude", color: "377CF6"); claude.provider = .claude
        let codex = Profile(id: "client", name: "Client workspace", color: "377CF6")
        usage.configure([claude, codex]); usage.refreshAll()
        let deadline = Date().addingTimeInterval(2)
        while usage.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(usage.disconnectedProfiles.count, 2)
        for width in [320.0, 440.0, 700.0] {
            let view = NSHostingView(rootView: AccountConnectionNoticeView(usage: usage, home: URL(fileURLWithPath: "/fixture"), dismiss: {}).environment(\.colorScheme, .dark).frame(width: width, height: 280).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 280), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 280)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.height, 280, "The notice must not grow into a full-height window")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let folder = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_CONNECTIONS"] {
                let destination = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("reconnect-\(Int(width)).png"))
            }
            window.close()
        }
    }
}
