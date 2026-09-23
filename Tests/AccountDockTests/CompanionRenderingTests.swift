import AppKit
import SwiftUI
import XCTest
import DockCore
@testable import AccountDock

final class CompanionRenderingTests: XCTestCase {
    @MainActor func testMixedProviderDesktopLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_COMPANIONS"] else { throw XCTSkip("Opt-in mixed provider previews") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), activity = ActivityMonitor(home: home), usage = UsageStore(), insights = InsightsStore()
        defer { activity.shutdown(); usage.shutdown(); insights.shutdown() }
        var codex = Profile(id: "default", name: "Personal", color: "377CF6"); codex.dockIconStyle = .chatgpt
        try FileManager.default.createDirectory(at: codex.home(in: home), withIntermediateDirectories: true)
        model.preferences.profiles = [codex]
        try model.createCompanion(kind: .claude, name: "Claude", project: nil)
        try model.createCompanion(kind: .claudeCode, name: "Website project", project: home)
        try model.createCompanion(kind: .terminal, name: "Terminal", project: home)
        for width in [360.0, 680, 1040] {
            for scale in [0.85, 1, 1.3] {
                model.preferences.scale = scale
                let presentation = IslandPresentation(expanded: true)
                presentation.profileColumns = width < 500 ? 2 : 4; presentation.profileRows = width < 500 ? 2 : 1
                let height = width < 500 ? 660.0 : 410.0
                let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation,
                                      notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                try await render(view, size: CGSize(width: width, height: height), to: directory.appendingPathComponent("strip-\(Int(width))-\(scale).png"))
            }
        }
        for size in [CGSize(width: 760, height: 560), CGSize(width: 920, height: 700), CGSize(width: 1280, height: 800)] {
            let view = SettingsView(model: model, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in })
            try await render(view, size: size, to: directory.appendingPathComponent("settings-\(Int(size.width)).png"))
        }
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
