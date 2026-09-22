import AppKit
import SwiftUI
import Carbon
import DockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let model: DockModel
    let previewMode = CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey: "ProfileDockContextPreview") as? Bool == true
    let usage = UsageStore()
    let insights = InsightsStore()
    let activity = ActivityMonitor()
    let loginItem = LoginItemModel()
    let appUpdates = AppUpdates()
    let selfUpdates = ProfileDockUpdates()
    let cues = ActivityCues()
    var islands: [IslandController] = []
    let iconAppearance = AppIconController()
    var status: NSStatusItem!
    var settingsWindow: NSWindow?
    private var settingsOpen = false
    var hotKeys: [EventHotKeyRef] = []
    var eventHandler: EventHandlerRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseEvents = 0

    override init() {
        let contextPreview = Bundle.main.object(forInfoDictionaryKey: "ProfileDockContextPreview") as? Bool == true
        if CommandLine.arguments.contains("--preview") || contextPreview {
            let arguments = CommandLine.arguments
            let supplied = arguments.firstIndex(of: "--preview-home").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
            let directory = supplied ?? FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-preview-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = DockModel(home: directory)
        } else { model = DockModel() }
        super.init()
        if previewMode, CommandLine.arguments.contains("--preview-notice"), let profile = model.preferences.profiles.first {
            // Keep notice/retry visual checks inside the isolated preview home.
            model.unreadableProcesses = true
            model.showProfileMessage("Couldn’t bring \(profile.name) to the front.", for: profile)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One companion process, regardless of how often Finder or the Dock opens it.
        if !previewMode, let other = NSRunningApplication.runningApplications(withBundleIdentifier: "nl.breukr.account-dock").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("nl.breukr.account-dock.show"), object: nil)
            _ = other
            NSApp.terminate(nil)
            return
        }
        applyVisibility()
        usage.configure(previewMode ? [] : model.preferences.profiles)
        insights.prepare(profiles: model.preferences.profiles, home: model.home)
        if !previewMode { usage.refreshAll() }
        activity.configure(previewMode ? [] : model.preferences.profiles, running: Set(model.running.keys))
        if !previewMode { rebuildIslands(); startMouseMonitoring() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = BrandArtwork.template(size: 16)
        status.button?.toolTip = "ProfileDock"
        status.button?.target = self
        status.button?.action = #selector(statusClick)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyVisibility()
        configureMenu()
        iconAppearance.update(model.preferences.appIconAppearance ?? .auto)
        selfUpdates.mayUpdate = { [weak self] in self?.appUpdates.busy == false && self?.model.nativeDockOperations.isEmpty == true }
        if !previewMode { selfUpdates.start() }
        activity.$event.compactMap { $0 }.sink { [weak self] event in
            guard let self, !self.previewMode else { return }
            self.cues.receive(event, model: self.model)
        }.store(in: &subscriptions)
        if !previewMode { registerHotKeys() }
        if model.preferences.profiles.isEmpty || previewMode || CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--context-settings") || CommandLine.arguments.contains("--search-chats") { showSettings() }
        model.onPreferencesChanged = { [weak self] in
            guard let self else { return }
            self.usage.configure(self.previewMode ? [] : self.model.preferences.profiles)
            self.insights.prepare(profiles: self.model.preferences.profiles, home: self.model.home)
            self.activity.configure(self.previewMode ? [] : self.model.preferences.profiles, running: Set(self.model.running.keys))
            if !self.previewMode, self.islands.first?.layout.placement != self.model.placement { self.cues.dismiss(); self.rebuildIslands() }
            else { self.islands.forEach { $0.updateLayout() } }
            self.applyVisibility()
            self.iconAppearance.update(self.model.preferences.appIconAppearance ?? .auto)
            self.configureMenu(); if !self.previewMode { self.registerHotKeys() }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPanel), name: Notification.Name("nl.breukr.account-dock.show"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(writeDiagnostics), name: Notification.Name("nl.breukr.account-dock.diagnostics"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(measureAnimations(_:)), name: Notification.Name("nl.breukr.account-dock.measure"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.$message.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.islands.forEach { $0.updateLayout() } } }.store(in: &subscriptions)
        model.$running.dropFirst().sink { [weak self] running in
            guard let self else { return }
            self.activity.configure(self.previewMode ? [] : self.model.preferences.profiles, running: Set(running.keys))
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
        iconAppearance.shutdown()
        cues.shutdown()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        islands.forEach { $0.shutdown() }
        usage.shutdown()
        insights.shutdown()
        activity.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !model.nativeDockOperations.isEmpty {
            model.message = "Keep ProfileDock open until the native Dock app finishes building."
            showSettings()
            return .terminateCancel
        }
        guard appUpdates.busy else { return .terminateNow }
        model.message = appUpdates.canCancel ? "Cancel the ChatGPT download before quitting ProfileDock." : "Keep ProfileDock open until the ChatGPT installation finishes."
        showSettings()
        return .terminateCancel
    }

    func rebuildIslands() {
        islands.forEach { $0.shutdown() }
        islands = NSScreen.screens.map { screen in IslandController(screen: screen, model: model, usage: usage, activity: activity, insights: insights, settings: { [weak self] in self?.showSettings() }) }
    }

    @objc func screenChanged() { cues.dismiss(); if !previewMode { rebuildIslands() } }
    @objc func showPanel() { islands.forEach { $0.showPanel() } }
    @objc func measureAnimations(_ notification: Notification) { islands.forEach { $0.measureAnimations = notification.object as? String == "start" } }
    @objc func writeDiagnostics(_ notification: Notification) {
        let destination = model.settingsURL.deletingLastPathComponent().appendingPathComponent("live-diagnostics.json")
        loginItem.refresh()
        let output: [String: Any] = ["requestID": notification.object as? String ?? "", "islands": islands.map(\.diagnostics), "usage": usage.diagnostics, "activity": activity.diagnostics, "mouseEvents": mouseEvents, "globalMouseMonitor": globalMouseMonitor != nil, "localMouseMonitor": localMouseMonitor != nil, "profileRefreshes": model.refreshCount, "loginItem": loginItem.statusName, "menuBarItem": status.isVisible, "pid": ProcessInfo.processInfo.processIdentifier, "iconAppearance": (model.preferences.appIconAppearance ?? .auto).rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }

    @objc func statusClick() {
        guard let menu = statusMenu else { return }
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil
    }

    var statusMenu: NSMenu?
    func menuWillOpen(_ menu: NSMenu) {
        model.refresh()
        for item in menu.items {
            guard let id = item.representedObject as? String,
                  let profile = model.preferences.profiles.first(where: { $0.id == id }) else { continue }
            item.state = model.activeProfile == id ? .on : .off
            let isOpen = model.running[id]?.isEmpty == false
            item.toolTip = isOpen ? "Show \(profile.name) — already open" : "Open \(profile.name)"
        }
    }

    func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(.sectionHeader(title: "Switch Profile"))
        if model.preferences.profiles.isEmpty { menu.addItem(withTitle: "No profiles yet", action: nil, keyEquivalent: "") }
        for (index, profile) in model.preferences.profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(menuSelect(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = profile.id
            item.target = self
            let image = model.image(for: profile)
            var menuProfile = profile
            if image != nil { menuProfile.dockIconStyle = .image }
            let artwork = NativeProfileArtwork.preview(profile: menuProfile, image: image, vendor: nil)
            item.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                artwork.draw(in: rect)
                return true
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open ProfileDock…", action: #selector(showProfiles), keyEquivalent: "0").target = self
        menu.addItem(withTitle: "Add Profile…", action: #selector(addProfile), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Search Chats…", action: #selector(showSearch), keyEquivalent: "f").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Updates…", action: #selector(showUpdateSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showGeneralSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ProfileDock", action: #selector(quit), keyEquivalent: "q").target = self
        statusMenu = menu
        let main = NSMenu()
        let application = NSMenu(title: "ProfileDock")
        application.addItem(withTitle: "About ProfileDock", action: #selector(about), keyEquivalent: "").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Settings…", action: #selector(showGeneralSettings), keyEquivalent: ",").target = self
        application.addItem(withTitle: "Check ProfileDock for Updates…", action: #selector(checkProfileDockUpdates), keyEquivalent: "").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Hide ProfileDock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit ProfileDock", action: #selector(quit), keyEquivalent: "q").target = self
        application.delegate = self
        let appMenu = NSMenuItem(title: "ProfileDock", action: nil, keyEquivalent: "")
        appMenu.submenu = application
        main.addItem(appMenu)
        let profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        let profiles = NSMenu(title: "Profiles")
        for item in menu.items where item.representedObject is String { if let copy = item.copy() as? NSMenuItem { profiles.addItem(copy) } }
        profiles.addItem(.separator())
        profiles.addItem(withTitle: "Add Profile…", action: #selector(addProfile), keyEquivalent: "n").target = self
        profiles.addItem(withTitle: "Manage Profiles…", action: #selector(showProfiles), keyEquivalent: "0").target = self
        profiles.addItem(withTitle: "Search Chats…", action: #selector(showSearch), keyEquivalent: "f").target = self
        profiles.delegate = self
        profilesItem.submenu = profiles; main.addItem(profilesItem)
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
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "ProfileDock Help", action: #selector(showHelp), keyEquivalent: "?").target = self
        help.addItem(withTitle: "Support ProfileDock…", action: #selector(showSupport), keyEquivalent: "").target = self
        help.addItem(withTitle: "About ProfileDock…", action: #selector(about), keyEquivalent: "").target = self
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = help; main.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkProfileDockUpdates) { return selfUpdates.canCheck && !appUpdates.busy && model.nativeDockOperations.isEmpty }
        return true
    }
    @objc func about() { showDestination(.profileDockShowAbout) }
    private func showDestination(_ notification: Notification.Name) {
        showSettings()
        DispatchQueue.main.async { NotificationCenter.default.post(name: notification, object: nil) }
    }
    @objc func showProfiles() { showDestination(.profileDockShowProfiles) }
    @objc func addProfile() { showDestination(.profileDockAddProfile) }
    @objc func showSearch() { showDestination(.profileDockShowSearch) }
    @objc func showSupport() { showDestination(.profileDockShowSupport) }
    @objc func showHelp() { NSWorkspace.shared.open(AppBrand.repository.appendingPathComponent("blob/main/docs/GUIDE.md")) }
    @objc func showGeneralSettings() {
        showSettings()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .profileDockShowGeneralSettings, object: nil) }
    }
    @objc func showUpdateSettings() {
        showSettings()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .profileDockShowUpdates, object: nil) }
    }
    private func applyVisibility() {
        let policy = AppVisibility.activationPolicy(preferences: model.preferences, settingsOpen: settingsOpen)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        status?.isVisible = model.preferences.showMenuBarIcon != false
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsOpen = false; applyVisibility()
    }
    @objc func checkProfileDockUpdates() { selfUpdates.check() }
    @objc func supportProfileDock() { NSWorkspace.shared.open(AppBrand.donation) }

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
            let compact = previewMode && CommandLine.arguments.contains("--compact-preview")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compact ? 760 : 920, height: compact ? 560 : 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ProfileDock"
            if previewMode, let index = CommandLine.arguments.firstIndex(of: "--preview-appearance"), CommandLine.arguments.indices.contains(index + 1) {
                window.appearance = NSAppearance(named: CommandLine.arguments[index + 1] == "light" ? .aqua : .darkAqua)
            }
            if previewMode { window.subtitle = Bundle.main.object(forInfoDictionaryKey: "ProfileDockContextPreview") as? Bool == true ? "Context preview" : "New installation preview" }
            window.contentView = NSHostingView(rootView: SettingsView(model: model, loginItem: loginItem, activity: activity, updates: appUpdates, selfUpdates: selfUpdates, insights: insights, cues: cues, chooseImage: { [weak self, weak window] profile in self?.model.chooseImage(for: profile, window: window) }))
            window.minSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            if !previewMode {
                window.setFrameAutosaveName("ProfileDock.Settings")
                window.setFrameUsingName("ProfileDock.Settings")
            }
            settingsWindow = window
        }
        settingsOpen = true
        applyVisibility()
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
        if CommandLine.arguments.dropFirst().first == "--prepare-native-dock" {
            guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[3]), pid == getppid() else { exit(1) }
            let model = DockModel(), id = CommandLine.arguments[2]
            guard let profile = model.preferences.profiles.first(where: { $0.id == id }),
                  let expected = model.nativeDockURL(for: profile),
                  NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().path == expected.path else { exit(1) }
            var done = false, succeeded = false
            Task { @MainActor in
                do { try await model.setNativeDockIcon(for: profile, enabled: true, launchingPID: pid); succeeded = true }
                catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)) }
                done = true
            }
            while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            exit(succeeded ? 0 : 1)
        }
        if CommandLine.arguments.contains("--validate-launcher") {
            guard let id = Bundle.main.object(forInfoDictionaryKey: "ProfileDockProfileID") as? String, Profile.validID(id) else { exit(1) }
            print(id); return
        }
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
