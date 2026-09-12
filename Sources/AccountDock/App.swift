import AppKit
import SwiftUI
import Carbon
import DockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model: DockModel
    let previewMode = CommandLine.arguments.contains("--preview")
    let usage = UsageStore()
    let activity = ActivityMonitor()
    let loginItem = LoginItemModel()
    var islands: [IslandController] = []
    var status: NSStatusItem!
    var settingsWindow: NSWindow?
    var hotKeys: [EventHotKeyRef] = []
    var eventHandler: EventHandlerRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseEvents = 0

    override init() {
        if CommandLine.arguments.contains("--preview") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-preview-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = DockModel(home: directory)
        } else { model = DockModel() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One companion process, regardless of how often Finder or the Dock opens it.
        if !previewMode, let other = NSRunningApplication.runningApplications(withBundleIdentifier: "nl.breukr.account-dock").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("nl.breukr.account-dock.show"), object: nil)
            _ = other
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        usage.configure(model.preferences.profiles)
        usage.refreshAll()
        activity.configure(model.preferences.profiles, running: Set(model.running.keys))
        if !previewMode { rebuildIslands(); startMouseMonitoring() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "ProfileDock")
        status.button?.toolTip = "ProfileDock"
        status.button?.target = self
        status.button?.action = #selector(statusClick)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configureMenu()
        if !previewMode { registerHotKeys() }
        if model.preferences.profiles.isEmpty || CommandLine.arguments.contains("--settings") { showSettings() }
        model.onPreferencesChanged = { [weak self] in
            guard let self else { return }
            self.usage.configure(self.model.preferences.profiles)
            self.activity.configure(self.model.preferences.profiles, running: Set(self.model.running.keys))
            self.islands.forEach { $0.updateLayout() }; self.configureMenu(); if !self.previewMode { self.registerHotKeys() }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPanel), name: Notification.Name("nl.breukr.account-dock.show"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(writeDiagnostics), name: Notification.Name("nl.breukr.account-dock.diagnostics"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(measureAnimations(_:)), name: Notification.Name("nl.breukr.account-dock.measure"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.$message.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.islands.forEach { $0.updateLayout() } } }.store(in: &subscriptions)
        model.$running.dropFirst().sink { [weak self] running in
            guard let self else { return }
            self.activity.configure(self.model.preferences.profiles, running: Set(running.keys))
        }.store(in: &subscriptions)
    }

    private var subscriptions = Set<AnyCancellable>()

    private func startMouseMonitoring() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    private func pointerMoved() {
        mouseEvents += 1
        let point = NSEvent.mouseLocation
        islands.forEach { $0.pointerMoved(to: point) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        islands.forEach { $0.shutdown() }
        usage.shutdown()
        activity.shutdown()
    }

    func rebuildIslands() {
        islands.forEach { $0.shutdown() }
        islands = NSScreen.screens.map { screen in IslandController(screen: screen, model: model, usage: usage, activity: activity, settings: { [weak self] in self?.showSettings() }) }
    }

    @objc func screenChanged() { if !previewMode { rebuildIslands() } }
    @objc func showPanel() { islands.forEach { $0.showPanel() } }
    @objc func measureAnimations(_ notification: Notification) { islands.forEach { $0.measureAnimations = notification.object as? String == "start" } }
    @objc func writeDiagnostics(_ notification: Notification) {
        let destination = model.settingsURL.deletingLastPathComponent().appendingPathComponent("live-diagnostics.json")
        loginItem.refresh()
        let output: [String: Any] = ["requestID": notification.object as? String ?? "", "islands": islands.map(\.diagnostics), "usage": usage.diagnostics, "activity": activity.diagnostics, "mouseEvents": mouseEvents, "globalMouseMonitor": globalMouseMonitor != nil, "localMouseMonitor": localMouseMonitor != nil, "profileRefreshes": model.refreshCount, "loginItem": loginItem.statusName, "menuBarItem": status.isVisible, "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = statusMenu {
            status.menu = menu
            status.button?.performClick(nil)
            status.menu = nil
        } else { showSettings() }
    }

    var statusMenu: NSMenu?
    func menuWillOpen(_ menu: NSMenu) {
        model.refresh()
        loginItem.refresh()
        for item in menu.items {
            if item.action == #selector(toggleLoginItem) { item.state = loginItem.enabled ? .on : .off }
            guard let id = item.representedObject as? String else { continue }
            let isOpen = model.running[id]?.isEmpty == false
            item.image = isOpen ? NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                NSColor(srgbRed: 0.23, green: 0.9, blue: 0.42, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            } : nil
        }
    }

    func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        for (index, profile) in model.preferences.profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(menuSelect(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = profile.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ProfileDock", action: #selector(quit), keyEquivalent: "q").target = self
        statusMenu = menu
        let main = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = menu.copy() as? NSMenu
        main.addItem(appMenu)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func menuSelect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let profile = model.preferences.profiles.first(where: { $0.id == id }) else { return }
        model.select(profile)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleLoginItem() {
        loginItem.refresh()
        loginItem.setEnabled(!loginItem.enabled)
        if loginItem.requiresApproval || loginItem.error != nil { showSettings() }
    }

    @objc func showSettings() {
        loginItem.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ProfileDock"
            if previewMode { window.subtitle = "New installation preview" }
            window.contentView = NSHostingView(rootView: SettingsView(model: model, loginItem: loginItem, activity: activity, chooseImage: { [weak self, weak window] profile in self?.model.chooseImage(for: profile, window: window) }))
            window.minSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func registerHotKeys() {
        for key in hotKeys { UnregisterEventHotKey(key) }
        hotKeys.removeAll()
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
                MainActor.assumeIsolated {
                    let index = Int(id.id) - 1
                    if delegate.model.preferences.profiles.indices.contains(index) { delegate.model.select(delegate.model.preferences.profiles[index]) }
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for index in 0..<min(model.preferences.profiles.count, codes.count) {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(codes[index]), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x41444F43, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { hotKeys.append(reference) }
            else { model.message = "Shortcut ⌥⌘\(index + 1) is already in use. You can still use the profile buttons." }
        }
    }
}

import Combine

@main
struct AccountDock {
    static func main() {
        let application = NSApplication.shared
        if let id = Bundle.main.object(forInfoDictionaryKey: "ProfileDockProfileID") as? String {
            let model = DockModel()
            guard Profile.validID(id), let profile = model.preferences.profiles.first(where: { $0.id == id }) else {
                let alert = NSAlert(); alert.messageText = "This profile is no longer in ProfileDock."; alert.runModal(); return
            }
            model.select(profile)
            let deadline = Date().addingTimeInterval(32)
            while model.opening.contains(id), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            if let message = model.message { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
            return
        }
        if CommandLine.arguments.contains("--measure-animations") || CommandLine.arguments.contains("--stop-measuring-animations") {
            let value = CommandLine.arguments.contains("--measure-animations") ? "start" : "stop"
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("nl.breukr.account-dock.measure"), object: value, userInfo: nil, deliverImmediately: true)
            return
        }
        if CommandLine.arguments.contains("--enable-login-item") || CommandLine.arguments.contains("--login-item-status") {
            let loginItem = LoginItemModel()
            if CommandLine.arguments.contains("--enable-login-item") { loginItem.setEnabled(true) }
            let output: [String: Any] = ["status": loginItem.statusName, "error": loginItem.error as Any? ?? NSNull(), "app": Bundle.main.bundleURL.path]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let content = String(data: data, encoding: .utf8) { print(content) }
            if CommandLine.arguments.contains("--enable-login-item") && !loginItem.enabled { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--live-diagnostics") {
            let requestID = UUID().uuidString
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("nl.breukr.account-dock.diagnostics"), object: requestID, userInfo: nil, deliverImmediately: true)
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Account Dock/live-diagnostics.json")
            let deadline = Date().addingTimeInterval(2)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if let data = try? Data(contentsOf: file), let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any], output["requestID"] as? String == requestID, let content = String(data: data, encoding: .utf8) { print(content); return }
            } while Date() < deadline
            FileHandle.standardError.write(Data("No fresh response from the running ProfileDock.\n".utf8))
            exit(1)
        }
        if CommandLine.arguments.contains("--diagnostics") {
            let model = DockModel()
            let rows: [[String: Any]] = model.preferences.profiles.map { profile in
                ["id": profile.id, "name": profile.name, "pids": (model.running[profile.id] ?? []).map(\.processIdentifier), "active": model.activeProfile == profile.id]
            }
            let screens: [[String: Any]] = NSScreen.screens.map { screen in
                let layout = IslandController.layout(screen: screen, model: model)
                return ["name": screen.localizedName, "screen": NSStringFromRect(screen.frame), "notchHeight": screen.safeAreaInsets.top, "collapsed": NSStringFromRect(layout.collapsed), "expanded": NSStringFromRect(layout.expanded)]
            }
            let output: [String: Any] = ["profiles": rows, "unreadableProcesses": model.unreadableProcesses, "screens": screens]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
