import AppKit
import SwiftUI
import XCTest
import DockCore
@testable import AccountDock

final class SettingsRenderingTests: XCTestCase {
    @MainActor func testRenderSettingsAtDesktopSizes() async throws {
        guard let output = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_SETTINGS"] else {
            throw XCTSkip("Opt-in native settings previews")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DockModel(home: home), activity = ActivityMonitor(home: home)
        defer { activity.shutdown() }
        var profiles = [Profile(id: "profile-personal", name: "Personal", color: "377CF6"),
                        Profile(id: "profile-work", name: "Work", color: "D77620"),
                        Profile(id: "profile-research", name: "Research", color: "009B87"),
                        Profile(id: "profile-writing", name: "Writing & Planning", color: "955CE5"),
                        Profile(id: "profile-long", name: "A longer profile name for layout", color: "CA528B")]
        for profile in profiles { try FileManager.default.createDirectory(at: profile.home(in: home), withIntermediateDirectories: true) }
        profiles[3].dockIconStyle = .image
        model.preferences.profiles = profiles
        model.save()
        let source = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { bounds in
            NSColor.white.setFill(); bounds.fill()
            NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 32, dy: 32)).fill()
            return true
        }
        let fixture = home.appendingPathComponent("square-icon.tiff")
        try XCTUnwrap(source.tiffRepresentation).write(to: fixture)
        try model.importImage(from: fixture, for: profiles[3])
        profiles = model.preferences.profiles
        for scheme in [ColorScheme.dark, .light] {
            for size in [CGSize(width: 760, height: 560), CGSize(width: 920, height: 700), CGSize(width: 1280, height: 800)] {
                for destination in SettingsDestination.allCases {
                    let view = SettingsView(model: model, loginItem: LoginItemModel(), activity: activity,
                                            updates: AppUpdates(), selfUpdates: ProfileDockUpdates(), insights: InsightsStore(),
                                            cues: ActivityCues(), chooseImage: { _ in }, destination: destination)
                        .environment(\.colorScheme, scheme).frame(width: size.width, height: size.height)
                    try await render(view, size: size, scheme: scheme, to: directory.appendingPathComponent("\(destination.id)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        model.preferences.profiles = []
        let empty = SettingsView(model: model, loginItem: LoginItemModel(), activity: activity, updates: AppUpdates(),
                                 selfUpdates: ProfileDockUpdates(), insights: InsightsStore(), cues: ActivityCues(), chooseImage: { _ in })
            .frame(width: 1280, height: 800)
        try await render(empty, size: CGSize(width: 1280, height: 800), scheme: .dark, to: directory.appendingPathComponent("empty-wide.png"))
        model.preferences.profiles = profiles
        model.showProfileMessage("Couldn’t bring Writing & Planning to the front.", for: profiles[3])
        for width in [320.0, 680.0] {
            let notice = ProfileMessageNotice(model: model, compact: true).padding(16)
                .frame(width: width, height: 130).background(.black).environment(\.colorScheme, .dark)
            try await render(notice, size: CGSize(width: width, height: 130), scheme: .dark, to: directory.appendingPathComponent("notice-\(Int(width)).png"))
        }
        for scheme in [ColorScheme.dark, .light] {
            let editor = ProfileSettingsSheet(model: model, profileID: profiles[3].id, tagging: {})
                .environment(\.colorScheme, scheme)
            try await render(editor, size: CGSize(width: 600, height: 660), scheme: scheme,
                             to: directory.appendingPathComponent("profile-editor-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
