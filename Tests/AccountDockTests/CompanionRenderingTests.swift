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

final class AgentRenderingTests: XCTestCase {
    /// `PROFILEDOCK_RENDER_AGENTS=<dir> swift test --filter AgentRenderingTests` writes every agent surface with fictional
    /// profiles: narrow, normal and wide; scales 0.85, 1 and 1.3; light and dark.
    @MainActor func testAgentProfilesDesktopLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_AGENTS"] else { throw XCTSkip("Opt-in agent previews") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), activity = ActivityMonitor(home: home), usage = UsageStore(), insights = InsightsStore()
        defer { activity.shutdown(); usage.shutdown(); insights.shutdown() }
        var codex = Profile(id: "default", name: "Personal", color: "377CF6"); codex.dockIconStyle = .chatgpt
        try FileManager.default.createDirectory(at: codex.home(in: home), withIntermediateDirectories: true)
        model.preferences.profiles = [codex]
        try model.createAgentProfile(toolID: "grok-bot", name: "Grok Bot", project: nil, separate: false, automatic: true)
        try model.createAgentProfile(toolID: "grok-bot", name: "Work", project: nil, separate: true)
        try model.createAgentProfile(toolID: "hermes", name: "Hermes", project: home, separate: false)
        try model.createAgentProfile(toolID: "gemini", name: "Client", project: home, separate: true)
        try model.createAgentProfile(toolID: "pi", name: "pi", project: home, separate: false)
        try model.createAgentProfile(toolID: "t3code", name: "T3 Code", project: nil, separate: false, automatic: true)
        let installed: [(String, String?, String?, String?)] = [
            ("claude", "\(home.path)/.local/bin/claude", nil, nil), ("codex", "/opt/homebrew/bin/codex", "/Applications/Codex.app", nil),
            ("grok-bot", nil, "/Applications/Grok Bot.app", nil), ("hermes", "\(home.path)/.local/bin/hermes", nil, nil),
            ("gemini", "\(home.path)/.nvm/versions/node/v22.11.0/bin/gemini", nil, nil), ("opencode", "/opt/homebrew/bin/opencode", nil, nil),
            ("kimi", "\(home.path)/.kimi-code/bin/kimi", nil, nil), ("qwen", "/opt/homebrew/bin/qwen", nil, nil),
            ("t3code", nil, "/Applications/T3 Code (Alpha).app", nil), ("antigravity", nil, "/Applications/Antigravity.app", nil),
            ("crush", nil, nil, "\(home.path)/.config/crush"), ("droid", nil, nil, "\(home.path)/.factory")
        ]
        model.installedAgents = installed.compactMap { id, command, app, config in
            AgentRegistry.tool(id: id).map { InstalledAgent(tool: $0, executablePath: command, applicationPath: app, configPath: config,
                                                            evidence: [command.map { _ in .executable }, app.map { _ in .application }, config.map { _ in .config }].compactMap { $0 },
                                                            applications: app.map { [AgentApplication(path: $0, bundleIdentifier: nil, name: "Fixture")] } ?? []) }
        }
        model.agentScannedAt = .distantFuture
        if let work = model.preferences.profiles.first(where: { $0.name == "Work" }) { model.agentsNeedingSignIn = [work.id] }
        model.companions.terminalStarted = 42
        model.companions.windows = [TerminalWindow(windowID: 7, tty: "/dev/ttys007", title: "Fixture", selected: false, front: false, agent: TerminalAgent(rawValue: "opencode"))]
        model.companions.hostedWindows = [
            TerminalWindow(windowID: 503, tty: "/dev/ttys011", title: "VS Code", selected: false, front: false, agent: .claude, host: "com.microsoft.VSCode", agentStarted: 1000),
            TerminalWindow(windowID: 702, tty: "/dev/ttys012", title: "tmux", selected: false, front: false, agent: TerminalAgent(rawValue: "hermes"), host: "tmux", agentStarted: 2000)
        ]
        model.reconcileDiscoveredTerminals()

        let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]
        let scales = [0.85, 1.0, 1.3]
        for (width, columns) in [(480.0, 3), (680.0, 4), (1040.0, 6)] {
            for scale in scales {
                model.preferences.scale = scale
                for (name, scheme) in schemes {
                    let presentation = IslandPresentation(expanded: true)
                    presentation.profileColumns = columns; presentation.profileRows = 3
                    let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                    try await render(view, size: CGSize(width: width, height: 760), scheme: scheme, to: directory.appendingPathComponent("strip-\(Int(width))-\(scale)-\(name).png"))
                }
            }
        }
        model.preferences.scale = 1
        let sizes = [CGSize(width: 760, height: 560), CGSize(width: 920, height: 700), CGSize(width: 1280, height: 800)]
        for destination in [SettingsDestination.profiles, .agents] {
            for size in sizes {
                for zoom in scales {
                    for (name, scheme) in schemes {
                        let view = SettingsView(model: model, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in }, destination: destination)
                        try await render(view, size: size, scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("\(destination == .agents ? "agents" : "profiles")-\(Int(size.width))-\(zoom)-\(name).png"))
                    }
                }
            }
        }
        for (label, start, separate) in [("detected", "hermes", false), ("separate", "gemini", true), ("missing", "pi", false), ("codex", "codex", false)] {
            for zoom in scales {
                for (name, scheme) in schemes {
                    let sheet = AddProfileSheet(model: model, start: start, separate: separate).background(Color(nsColor: .windowBackgroundColor))
                    // A sheet keeps its width when the display zooms, so the canvas grows with it.
                    try await render(sheet, size: CGSize(width: 640 * zoom, height: 720 * zoom), scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("add-\(label)-\(zoom)-\(name).png"))
                }
            }
        }
        for profile in model.preferences.profiles where profile.kind == .agent && profile.usesIsolatedAgentHome {
            for (name, scheme) in schemes {
                var trash = true
                let sheet = RemoveProfileSheet(model: model, profile: profile, trashData: Binding(get: { trash }, set: { trash = $0 }), done: {}).background(Color(nsColor: .windowBackgroundColor))
                try await render(sheet, size: CGSize(width: 480, height: 320), scheme: scheme, to: directory.appendingPathComponent("remove-\(profile.name)-\(name).png"))
            }
        }
        // Errors and empty states: a missing tool's notice, denied Terminal access, a first run with tools found, and a scan in progress.
        if let pi = model.preferences.profiles.first(where: { $0.agentID == "pi" }) { model.select(pi) }
        model.companions.terminalError = TerminalClientError.automationDenied.localizedDescription
        for zoom in scales {
            for (name, scheme) in schemes {
                try await render(VStack { ProfileMessageNotice(model: model) }.padding(20).background(Color(nsColor: .windowBackgroundColor)),
                                 size: CGSize(width: 760, height: 160), scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("error-missing-\(zoom)-\(name).png"))
                try await render(SettingsView(model: model, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in }, destination: .agents),
                                 size: CGSize(width: 920, height: 700), scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("error-automation-\(zoom)-\(name).png"))
            }
        }
        model.message = nil
        let firstHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: firstHome) }
        let first = DockModel(home: firstHome)
        first.installedAgents = model.installedAgents; first.agentScannedAt = .distantFuture
        let scanning = DockModel(home: firstHome)
        scanning.agentScanTask = Task {}
        for zoom in scales {
            for (name, scheme) in schemes {
                for size in sizes {
                    try await render(SettingsView(model: first, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in }, destination: .profiles),
                                     size: size, scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("empty-first-run-\(Int(size.width))-\(zoom)-\(name).png"))
                }
                try await render(SettingsView(model: scanning, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: insights, cues: ActivityCues(), chooseImage: { _ in }, destination: .agents),
                                 size: CGSize(width: 920, height: 700), scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("empty-scanning-\(zoom)-\(name).png"))
                let empty = IslandView(model: first, usage: usage, activity: activity, insights: insights, presentation: IslandPresentation(expanded: true), notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                try await render(empty, size: CGSize(width: 680, height: 320), scheme: scheme, zoom: zoom, to: directory.appendingPathComponent("empty-strip-\(zoom)-\(name).png"))
            }
        }
    }
    /// `zoom` lays the view out at a smaller or larger size and magnifies it, like zooming the display.
    @MainActor private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, zoom: CGFloat = 1, to url: URL) async throws {
        let content = view.environment(\.colorScheme, scheme).frame(width: size.width / zoom, height: size.height / zoom, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading).frame(width: size.width, height: size.height, alignment: .topLeading)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
