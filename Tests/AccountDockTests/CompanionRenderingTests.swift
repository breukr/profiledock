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
        model.companions.terminalStarted = 42
        for index in model.preferences.profiles.indices where model.preferences.profiles[index].kind.usesTerminal {
            var profile = model.preferences.profiles[index]
            profile.terminalTTY = "/dev/ttys12\(index)"; profile.terminalWindowID = index; profile.terminalProcessStarted = 42
            model.update(profile)
            model.companions.windows.append(TerminalWindow(windowID: index, tty: profile.terminalTTY!, title: "Fixture", selected: false, front: false, agent: profile.kind == .claudeCode ? .claude : .codex))
        }
        for width in [360.0, 680, 1040] {
            for scale in [0.85, 1, 1.3] {
                model.preferences.scale = scale
                let presentation = IslandPresentation(expanded: true)
                presentation.profileColumns = width < 500 ? 2 : 4; presentation.profileRows = width < 500 ? 2 : 1
                let height = width < 500 ? 800.0 : 720.0
                let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation,
                                      notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                try await render(view, size: CGSize(width: width, height: height), to: directory.appendingPathComponent("strip-\(Int(width))-\(scale).png"))
            }
        }
        try await render(ActivityConnectionsView(model: model, activity: activity).padding(20).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 600, height: 940), to: directory.appendingPathComponent("connectors.png"))
        model.preferences.terminalsExpanded = false
        let collapsedPresentation = IslandPresentation(expanded: true)
        collapsedPresentation.profileColumns = 4
        try await render(IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: collapsedPresentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black), size: CGSize(width: 680, height: 440), to: directory.appendingPathComponent("terminals-collapsed.png"))
        for size in [CGSize(width: 760, height: 560), CGSize(width: 920, height: 700), CGSize(width: 1280, height: 800)] {
            let view = SettingsView(model: model, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in })
            try await render(view, size: size, to: directory.appendingPathComponent("settings-\(Int(size.width)).png"))
        }
    }
    @MainActor func testCustomGridDesktopLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_GRIDS"] else { throw XCTSkip("Opt-in grid previews") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), usage = UsageStore(), activity = ActivityMonitor(home: home), insights = InsightsStore()
        defer { usage.shutdown(); activity.shutdown(); insights.shutdown() }
        model.preferences.profiles = (1...9).map { index in
            var profile = Profile(id: "fixture-\(index)", name: "Profile \(index)", color: "377CF6")
            profile.dockIconStyle = .chatgpt
            return profile
        }
        for grid in ProfileGrid.presets {
            model.preferences.profileGrid = grid
            for scale in [0.85, 1.0, 1.3] {
                model.preferences.scale = scale
                let layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: 9, scale: scale, hasMessage: false, terminalCount: 0, grid: grid)
                let presentation = IslandPresentation(expanded: true)
                presentation.profileColumns = layout.profileColumns; presentation.profileRows = layout.profileRows
                let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                try await render(view, size: layout.expanded.size, to: directory.appendingPathComponent("grid-\(grid.columns)x\(grid.rows)-\(scale).png"))
            }
            try await render(ProfileGridSettings(model: model).padding(20).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 540, height: 320), to: directory.appendingPathComponent("settings-\(grid.columns)x\(grid.rows).png"))
        }
        model.preferences.showTerminalsSection = false; model.preferences.showInsightsSection = false
        model.preferences.scale = 1
        let presentation = IslandPresentation(expanded: true)
        presentation.profileColumns = 3; presentation.profileRows = 2
        try await render(IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black), size: CGSize(width: 460, height: 670), to: directory.appendingPathComponent("sections-hidden.png"))
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height, alignment: .topLeading))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
