import AppKit
import SwiftUI
import XCTest
import DockCore
@testable import AccountDock

/// Fictional usage for strip renders: a 5-hour and a weekly window, two saved resets, and fixed errors per profile id.
actor StripFixtureUsage: UsageFetching {
    let failures: [String: UsageLoadError]
    init(failures: [String: UsageLoadError] = [:]) { self.failures = failures }
    func identity(for profile: Profile) async throws -> String { profile.id }
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot {
        if let failure = failures[profile.id] { throw failure }
        let now = Date(), seed = Double(abs(profile.id.hashValue % 70))
        return UsageSnapshot(identity: expectedIdentity, plan: "fixture",
                             windows: [UsageWindow(id: "five_hour", duration: 18000, usedPercent: 12 + seed, resetsAt: now.addingTimeInterval(2 * 3600 + 840)),
                                       UsageWindow(id: "seven_day", duration: 604800, usedPercent: 30 + seed * 0.9, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600))],
                             bankedResets: 2, applicableResets: 1, resetExpiries: [now.addingTimeInterval(3 * 86400 + 600), now.addingTimeInterval(9 * 86400)], fetchedAt: now)
    }
}

/// Frames the strip reports through `StripFramesKey`, collected outside SwiftUI.
final class StripFrameBox: @unchecked Sendable { var frames: [String: CGRect] = [:] }

@MainActor func settleUsage(_ usage: UsageStore) async throws {
    let deadline = Date().addingTimeInterval(3)
    while usage.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

final class CompanionRenderingTests: XCTestCase {
    /// Cards in one row share a height, every section starts on the header's left edge, and the panel is exactly
    /// as tall as its content (no empty band at the bottom).
    @MainActor func testStripCardsShareRowHeightsLeadingEdgeAndExactPanelHeight() async throws {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), activity = ActivityMonitor(home: home), insights = InsightsStore()
        let fixture = StripFixtureUsage(failures: ["fixture-2": .network, "fixture-4": .claudeTokenStale])
        let usage = UsageStore(client: fixture, claudeClient: fixture, claudeAccountClient: { _ in fixture })
        defer { activity.shutdown(); usage.shutdown(); insights.shutdown() }
        model.preferences.profiles = ["Noordhaven", "Veldkamp", "Atlas", "Rijnstaal", "Meridian"].enumerated().map { index, name in
            var profile = Profile(id: "fixture-\(index + 1)", name: name, color: "377CF6"); profile.dockIconStyle = .initials
            return profile
        }
        usage.configure(model.preferences.profiles); usage.refreshAll()
        try await settleUsage(usage)
        activity.entries["fixture-1"] = ActivitySummary(unread: 0, working: 2, liveAvailable: true, appOpen: true)
        activity.entries["fixture-3"] = ActivitySummary(unread: 0, waiting: 1, liveAvailable: true, appOpen: true)
        model.activeProfile = "fixture-1"
        for (width, scale) in [(360.0, 0.85), (680.0, 1.0), (1040.0, 1.3), (1040.0, 0.85)] {
            model.preferences.scale = scale
            let layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: model.displayedProfiles.count, scale: scale,
                                      hasMessage: false, usageRows: usage.cardUsageRows, expandedWidth: width, terminalCount: model.liveTerminalProfiles.count)
            let presentation = IslandPresentation(expanded: true)
            presentation.profileColumns = layout.profileColumns; presentation.profileRows = layout.profileRows
            let box = StripFrameBox()
            let size = layout.expanded.size
            let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in })
                .onPreferenceChange(StripFramesKey.self) { box.frames = $0 }
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            defer { window.close() }
            let label = "\(Int(width)) x \(scale)"
            let cards = box.frames.filter { $0.key.hasPrefix("card:") }.map(\.value)
            XCTAssertEqual(cards.count, min(5, layout.profileColumns * layout.profileRows), label)
            let header = try XCTUnwrap(box.frames["header"], label), content = try XCTUnwrap(box.frames["content"], label)
            let terminals = try XCTUnwrap(box.frames["terminals"], label)
            let expectedWidth = WidgetSizing.cardWidth(columns: layout.profileColumns, available: size.width - 32, scale: scale)
            for card in cards {
                XCTAssertEqual(card.width, expectedWidth, accuracy: 0.5, label)
                XCTAssertEqual(card.height, CardMetrics.height(usageRows: usage.cardUsageRows, scale: scale), accuracy: 0.5, label)
                for other in cards where abs(other.minY - card.minY) < 0.5 { XCTAssertEqual(other.height, card.height, accuracy: 0.5, "Equal heights per row at \(label)") }
            }
            let leading = try XCTUnwrap(cards.map(\.minX).min())
            XCTAssertEqual(leading, header.minX, accuracy: 1, "Cards start on the header's left edge at \(label)")
            XCTAssertEqual(terminals.minX, header.minX, accuracy: 1, "Terminals start on the header's left edge at \(label)")
            XCTAssertEqual(header.minX, 16, accuracy: 1, label)
            XCTAssertEqual(content.height + IslandLayout.topInset + IslandLayout.bottomInset, size.height, accuracy: 1, "The panel is exactly as tall as its content at \(label)")
        }
    }

    @MainActor func testMixedProviderDesktopLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_COMPANIONS"] else { throw XCTSkip("Opt-in mixed provider previews") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = StripFixtureUsage()
        let model = DockModel(home: home), activity = ActivityMonitor(home: home), usage = UsageStore(client: fixture, claudeClient: fixture, claudeAccountClient: { _ in fixture }), insights = InsightsStore()
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
        usage.configure(model.preferences.profiles); usage.refreshAll()
        try await settleUsage(usage)
        activity.entries["default"] = ActivitySummary(unread: 0, working: 2, liveAvailable: true, appOpen: true)
        if let claude = model.preferences.profiles.first(where: { $0.kind == .claude }) { activity.entries[claude.id] = ActivitySummary(unread: 1, liveAvailable: true, appOpen: true) }
        if let code = model.preferences.profiles.first(where: { $0.kind == .claudeCode }) { activity.entries[code.id] = ActivitySummary(waiting: 1, liveAvailable: true, appOpen: true) }
        model.activeProfile = "default"
        for width in [360.0, 680, 1040] {
            for scale in [0.85, 1, 1.3] {
                model.preferences.scale = scale
                // Columns, rows and height come from the real layout for this width, so the render shows any empty band.
                let layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: model.displayedProfiles.count, scale: scale,
                                          hasMessage: false, usageRows: usage.cardUsageRows, expandedWidth: width, terminalCount: model.liveTerminalProfiles.count)
                let presentation = IslandPresentation(expanded: true)
                presentation.profileColumns = layout.profileColumns; presentation.profileRows = layout.profileRows
                let view = IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation,
                                      notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black)
                try await render(view, size: layout.expanded.size, to: directory.appendingPathComponent("strip-\(Int(width))-\(scale).png"))
            }
        }
        // One card with its saved-reset expiry list open.
        let details = IslandPresentation(expanded: true)
        details.profileColumns = 3; details.profileRows = 2
        details.toggleResetDetails("default")
        model.preferences.scale = 1
        let detailsLayout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: model.displayedProfiles.count, scale: 1,
                                         hasMessage: false, showsResetDetails: true, usageRows: usage.cardUsageRows, expandedWidth: 880, terminalCount: model.liveTerminalProfiles.count)
        details.profileColumns = detailsLayout.profileColumns; details.profileRows = detailsLayout.profileRows
        try await render(IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: details, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black),
                         size: detailsLayout.expanded.size, to: directory.appendingPathComponent("strip-reset-details.png"))
        try await render(ActivityConnectionsView(model: model, activity: activity).padding(20).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 600, height: 940), to: directory.appendingPathComponent("connectors.png"))
        model.preferences.terminalsExpanded = false
        let collapsedPresentation = IslandPresentation(expanded: true)
        let collapsedLayout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: model.displayedProfiles.count, scale: 1,
                                           hasMessage: false, usageRows: usage.cardUsageRows, expandedWidth: 680, terminalCount: 0)
        collapsedPresentation.profileColumns = collapsedLayout.profileColumns; collapsedPresentation.profileRows = collapsedLayout.profileRows
        model.preferences.scale = 1
        try await render(IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: collapsedPresentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black), size: collapsedLayout.expanded.size, to: directory.appendingPathComponent("terminals-collapsed.png"))
        // The collapsed strip on a display without a notch: attention count instead of "Agents".
        for width in [194.0, 300] {
            if width > 200 { activity.entries["default"] = ActivitySummary(unread: 0, waiting: 2, liveAvailable: true, appOpen: true) }
            try await render(CompactIslandView(model: model, activity: activity, presentation: IslandPresentation(), drag: { _, _ in }), size: CGSize(width: width, height: 44), to: directory.appendingPathComponent("compact-\(Int(width)).png"))
        }
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
        let fixture = StripFixtureUsage(failures: ["fixture-3": .claudeTokenStale, "fixture-6": .network])
        let model = DockModel(home: home), usage = UsageStore(client: fixture, claudeClient: fixture, claudeAccountClient: { _ in fixture }), activity = ActivityMonitor(home: home), insights = InsightsStore()
        defer { usage.shutdown(); activity.shutdown(); insights.shutdown() }
        model.preferences.profiles = (1...9).map { index in
            var profile = Profile(id: "fixture-\(index)", name: "Profile \(index)", color: "377CF6")
            profile.dockIconStyle = .chatgpt
            return profile
        }
        usage.configure(model.preferences.profiles); usage.refreshAll()
        try await settleUsage(usage)
        for grid in ProfileGrid.presets {
            model.preferences.profileGrid = grid
            for scale in [0.85, 1.0, 1.3] {
                model.preferences.scale = scale
                let layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: 9, scale: scale, hasMessage: false, usageRows: usage.cardUsageRows, terminalCount: 0, grid: grid)
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
        let hiddenLayout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notchHeight: 0, notchWidth: 0, count: 9, scale: 1, hasMessage: false, usageRows: usage.cardUsageRows,
                                        expandedWidth: 860, grid: ProfileGrid(columns: 3, rows: 2), showsInsightsSection: false)
        presentation.profileColumns = hiddenLayout.profileColumns; presentation.profileRows = hiddenLayout.profileRows
        try await render(IslandView(model: model, usage: usage, activity: activity, insights: insights, presentation: presentation, notchHeight: 0, settings: {}, drag: { _, _ in }).background(.black), size: hiddenLayout.expanded.size, to: directory.appendingPathComponent("sections-hidden.png"))
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
