import AppKit
import SwiftUI
import Combine
import ApplicationServices
import DockCore

@MainActor
final class DesktopDockStore: ObservableObject {
    @Published private(set) var entries: [DesktopDockEntry] = []
    @Published private(set) var frontmostPID: Int32?
    let model: DockModel
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var iconCache: [String: NSImage] = [:]
    private let observesWorkspace: Bool

    init(model: DockModel, observesWorkspace: Bool = true) {
        self.model = model; self.observesWorkspace = observesWorkspace
        if observesWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            subscription = model.$running.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        refresh()
    }

    func shutdown() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); subscription?.cancel()
    }

    func refresh() {
        let applications = observesWorkspace ? NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "nl.breukr.account-dock"
        } : []
        let managedPIDs = Set(model.running.values.flatMap { $0.map(\.processIdentifier) })
        let managedPaths = Set(model.preferences.profiles.compactMap { model.applicationURL(for: $0)?.standardizedFileURL.path })
        var result: [DesktopDockEntry] = []
        if observesWorkspace {
            // Read Apple's pins without changing them. Our grouping is a view over this list.
            for tile in UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? [] {
                guard let data = tile["tile-data"] as? [String: Any],
                      let file = data["file-data"] as? [String: Any],
                      let rawURL = file["_CFURLString"] as? String,
                      let url = URL(string: rawURL), url.isFileURL, url.pathExtension == "app",
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                let id = Bundle(url: url)?.bundleIdentifier ?? ""
                guard id != "nl.breukr.account-dock" else { continue }
                if managedPaths.contains(url.standardizedFileURL.path) || id.hasPrefix("nl.breukr.profiledock.launcher.") { continue }
                let running = applications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
                result.append(DesktopDockEntry(id: "app:" + url.standardizedFileURL.path, name: (data["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent, bundleIdentifier: id, applicationPath: url.path, processID: running?.processIdentifier, isRunning: running != nil, isChatGPT: DesktopDockLayout.isChatGPT(bundleIdentifier: id)))
            }
        }
        let profiles = model.preferences.profiles.map { profile in
            DesktopDockEntry(id: "profile:" + profile.id, name: profile.name, applicationPath: model.applicationURL(for: profile)?.path, processID: model.running[profile.id]?.first?.processIdentifier, profileID: profile.id, isRunning: model.running[profile.id]?.isEmpty == false, isChatGPT: true)
        }
        result.append(contentsOf: profiles)
        for app in applications {
            guard !managedPIDs.contains(app.processIdentifier), let url = app.bundleURL else { continue }
            let family = DesktopDockLayout.isChatGPT(bundleIdentifier: app.bundleIdentifier ?? "")
            // Unmanaged ChatGPT copies remain individually reachable with grouping off.
            let id = family ? "process:\(app.processIdentifier)" : "app:" + url.standardizedFileURL.path
            if family { result.removeAll { $0.applicationPath == url.path && $0.profileID == nil && $0.processID == app.processIdentifier } }
            result.append(DesktopDockEntry(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, bundleIdentifier: app.bundleIdentifier ?? "", applicationPath: url.path, processID: app.processIdentifier, isRunning: true, isChatGPT: family))
        }
        let projected = DesktopDockLayout.items(result, grouped: model.preferences.groupChatGPTApps != false)
        if entries != projected { entries = projected }
        frontmostPID = observesWorkspace ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
    }

    func image(for entry: DesktopDockEntry) -> NSImage {
        if let id = entry.profileID, let profile = model.preferences.profiles.first(where: { $0.id == id }), let image = model.image(for: profile) { return image }
        let path = entry.id == DesktopDockEntry.groupID ? model.defaultApplication?.path : entry.applicationPath
        guard let path else { return BrandArtwork.template(size: 44) }
        if let image = iconCache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 128, height: 128); iconCache[path] = image
        return image
    }

    func open(_ entry: DesktopDockEntry) {
        if entry.id == DesktopDockEntry.groupID { showGroupMenu(); return }
        if let id = entry.profileID, let profile = model.preferences.profiles.first(where: { $0.id == id }) { model.select(profile); return }
        if let pid = entry.processID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            app.unhide(); let accepted = app.activate(options: [.activateAllWindows])
            do { try ApplicationReopen.send(processIdentifier: pid); if accepted { model.message = nil } }
            catch { model.message = "macOS could not reopen \(entry.name)." }
        } else if let path = entry.applicationPath {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { [weak model] _, error in
                if let error { Task { @MainActor in model?.message = error.localizedDescription } }
            }
        }
    }

    private func showGroupMenu() {
        model.refresh()
        let menu = NSMenu(title: "ChatGPT")
        for profile in model.preferences.profiles {
            let item = DockActionItem(profile.name) { [weak model] in model?.select(profile) }
            item.image = model.image(for: profile)?.copy() as? NSImage
            item.image?.size = NSSize(width: 18, height: 18)
            item.state = model.activeProfile == profile.id ? .on : .off
            menu.addItem(item)
            let windows = (model.running[profile.id] ?? []).flatMap { DesktopDockWindows.windows(processID: $0.processIdentifier) }
            if windows.count > 1 {
                let parent = NSMenuItem(title: "\(profile.name) windows", action: nil, keyEquivalent: "")
                parent.submenu = windowMenu(windows); menu.addItem(parent)
            }
        }
        let managedPIDs = Set(model.running.values.flatMap { $0.map(\.processIdentifier) })
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !managedPIDs.contains($0.processIdentifier) && DesktopDockLayout.isChatGPT(bundleIdentifier: $0.bundleIdentifier ?? "")
        }
        if !menu.items.isEmpty && !others.isEmpty { menu.addItem(.separator()) }
        for app in others {
            let entry = DesktopDockEntry(id: "process:\(app.processIdentifier)", name: app.localizedName ?? "ChatGPT", applicationPath: app.bundleURL?.path, processID: app.processIdentifier, isRunning: true, isChatGPT: true)
            menu.addItem(DockActionItem(entry.name) { [weak self] in self?.open(entry) })
            let windows = DesktopDockWindows.windows(processID: app.processIdentifier)
            if !windows.isEmpty {
                let item = NSMenuItem(title: "\(entry.name) windows", action: nil, keyEquivalent: "")
                item.submenu = windowMenu(windows); menu.addItem(item)
            }
        }
        if menu.items.isEmpty, let url = model.defaultApplication {
            menu.addItem(DockActionItem("Open ChatGPT") { NSWorkspace.shared.open(url) })
        }
        menu.addItem(.separator())
        menu.addItem(DockActionItem("Show separate ChatGPT tiles") { [weak model] in model?.preferences.groupChatGPTApps = false; model?.save() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func windowMenu(_ windows: [DesktopDockWindows.Window]) -> NSMenu {
        let menu = NSMenu()
        for window in windows { menu.addItem(DockActionItem(window.title) { DesktopDockWindows.focus(window) }) }
        return menu
    }

    func chooseWindow(_ entry: DesktopDockEntry) {
        guard let pid = entry.processID else { return }
        guard AXIsProcessTrusted() else {
            model.message = "Enable Accessibility for ProfileDock in System Settings to choose individual windows. Opening apps and profiles works without it."
            return
        }
        let windows = DesktopDockWindows.windows(processID: pid)
        guard !windows.isEmpty else { open(entry); return }
        windowMenu(windows).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class DockActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Not used") }
    @objc private func invoke() { handler() }
}

@MainActor
enum DesktopDockWindows {
    struct Window { let title: String; let processID: Int32; let element: AXUIElement }
    static func windows(processID: Int32) -> [Window] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let elements = value as? [AXUIElement] else { return [] }
        return elements.enumerated().map { index, element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            let text = title as? String ?? ""
            return Window(title: text.isEmpty ? "Window \(index + 1)" : text, processID: processID, element: element)
        }
    }
    static func focus(_ window: Window) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        NSRunningApplication(processIdentifier: window.processID)?.activate(options: [])
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }
}

@MainActor
final class DesktopDockController {
    let panel: NSPanel
    let store: DesktopDockStore
    private var subscription: AnyCancellable?
    private let screen: NSScreen
    init(screen: NSScreen, model: DockModel, store: DesktopDockStore, settings: @escaping () -> Void) {
        self.screen = screen; self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DesktopDockView(model: model, store: store, settings: settings))
        subscription = store.$entries.sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
        layout(); panel.orderFrontRegardless()
    }
    func layout() {
        let size = CGFloat(48 * modelScale)
        let width = min(screen.visibleFrame.width - 32, max(180, CGFloat(store.entries.count) * (size + 8) + 116))
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 12, width: width, height: size + 28), display: true)
    }
    private var modelScale: Double { min(1.3, max(0.85, store.model.preferences.scale)) }
    func close() { subscription?.cancel(); panel.orderOut(nil); panel.close() }
}

private struct DesktopDockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: DesktopDockStore
    let settings: () -> Void
    private var tileSize: CGFloat { CGFloat(48 * min(1.3, max(0.85, model.preferences.scale))) }
    var body: some View {
        HStack(spacing: 10) {
            Button(action: settings) { BrandMark(size: 26).frame(width: 36, height: tileSize) }
                .buttonStyle(.plain).help("ProfileDock settings").accessibilityLabel("ProfileDock settings")
            Divider().frame(height: 32)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(store.entries) { entry in
                        Button { store.open(entry) } label: {
                            VStack(spacing: 3) {
                                Image(nsImage: store.image(for: entry)).resizable().scaledToFit().frame(width: tileSize, height: tileSize)
                                Circle().fill(entry.isRunning ? Color.primary.opacity(0.7) : .clear).frame(width: 4, height: 4)
                            }
                        }.buttonStyle(.plain).help(entry.name).accessibilityLabel(entry.name)
                        .contextMenu {
                            Button("Open") { store.open(entry) }
                            if entry.id != DesktopDockEntry.groupID {
                                if entry.processID != nil { Button("Choose window…") { store.chooseWindow(entry) } }
                                if let path = entry.applicationPath { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                                if let pid = entry.processID {
                                    Divider()
                                    Button("Hide") { NSRunningApplication(processIdentifier: pid)?.hide() }
                                    Button("Quit") {
                                        if let id = entry.profileID, let profile = model.preferences.profiles.first(where: { $0.id == id }) { model.requestQuit(profile) }
                                        else { NSRunningApplication(processIdentifier: pid)?.terminate() }
                                    }
                                }
                            } else { Button("Show separate ChatGPT tiles") { model.preferences.groupChatGPTApps = false; model.save() } }
                        }
                    }
                }.padding(.vertical, 2)
            }.scrollIndicators(.hidden)
            Button { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) } label: {
                Image(systemName: "trash").font(.system(size: 24)).frame(width: 32, height: tileSize)
            }.buttonStyle(.plain).help("Open Trash").accessibilityLabel("Open Trash")
        }.padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }
}
