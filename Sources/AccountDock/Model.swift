import AppKit
import SwiftUI
import DockCore
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct Preferences: Codable {
    var profiles: [Profile] = []
    var discoverTerminals: Bool?
    var terminalsExpanded: Bool?
    var codexActivityEnabled: Bool?
    var claudeReadAt: [String: Date]? = [:]
    var scale: Double = 1
    var iconSetVersion: Int?
    var hiddenProfileIDs: [String]?
    var removedProfiles: [Profile]?
    var activityCues: Bool?
    var activitySounds: Bool?
    var activitySoundVolume: Double?
    var placement: DockPlacement?
    var floatingPositions: [String: FloatingPosition]?
    var showDockIcon: Bool?
    var showMenuBarIcon: Bool?
    var appIconAppearance: AppIconAppearance?
    var insightsExpansion: InsightsExpansion?
    var insightsAccount: String?
    var insightsPeriod: Int?
    var insightsMetric: String?
    var compactWidth: Double?
    var expandedWidth: Double?
    var profileGrid: ProfileGrid?
    var showTerminalsSection: Bool?
    var showInsightsSection: Bool?
}

struct ProfileMessageRecovery: Equatable {
    let profileID: String
    let title: String
}

@MainActor
final class DockModel: ObservableObject {
    @Published var preferences = Preferences()
    var placement: DockPlacement { preferences.placement == nil || preferences.placement == .topCenter ? .topCenter : .free }
    func floatingPosition(for screenID: String) -> FloatingPosition {
        preferences.floatingPositions?[screenID] ?? FloatingPosition(x: preferences.placement == .bottomLeft ? 0 : preferences.placement == .bottomRight ? 1 : 0.5, y: preferences.placement == .bottomLeft || preferences.placement == .bottomRight ? 0 : 0.1)
    }
    func savePosition(_ position: FloatingPosition, for screenID: String) {
        preferences.floatingPositions = (preferences.floatingPositions ?? [:]).merging([screenID: position]) { _, new in new }
        save()
    }
    @Published var running: [String: [RunningProfileApplication]] = [:]
    private(set) var observedApplications: [RunningProfileApplication] = []
    @Published var activeProfile: String?
    @Published var opening: Set<String> = []
    @Published var closing: Set<String> = []
    @Published var message: String? {
        didSet {
            messageRecovery = nil
            messageID = UUID()
        }
    }
    @Published private(set) var messageRecovery: ProfileMessageRecovery?
    private(set) var messageID = UUID()
    @Published var unreadableProcesses = false
    @Published var updatingApplications: Set<String> = []
    @Published var nativeDockOperations: Set<String> = []
    @Published var nativeDockProgress: [String: NativeDockStage] = [:]
    let home: URL
    private let tracksApplications: Bool
    private var readinessTimer: Timer?
    private var readinessAttempts = 0
    private(set) var refreshCount = 0
    private var launches: [String: Process] = [:]
    lazy var companions = CompanionMonitor(model: self)
    @Published var companionRevision = 0
    @Published var draggingProfileID: String?
    var settingsURL: URL { home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json") }
    var onPreferencesChanged: (() -> Void)?
    lazy var contextSettings = ContextSettingsStore(home: home)
    private var imageCache: [String: NSImage] = [:]
    private var artworkCache: [String: (profile: Profile, source: String, image: NSImage)] = [:]
    private var terminalAgentArt: [TerminalAgent: NSImage] = [:]
    func terminalAgentArtwork(_ agent: TerminalAgent) -> NSImage {
        if let cached = terminalAgentArt[agent] { return cached }
        var profile = Profile(id: agent.rawValue, name: agent == .claude ? "Cl" : "Cx", color: agent == .claude ? "C97B5D" : "202020")
        profile.dockIconStyle = .chatgpt
        let vendor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier).map { NSWorkspace.shared.icon(forFile: $0.path) }
        let image = NativeProfileArtwork.preview(profile: profile, image: nil, vendor: vendor, margin: 0)
        terminalAgentArt[agent] = image
        return image
    }

    var iconsDirectory: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("Icons") }

    func image(for profile: Profile) -> NSImage? {
        guard let filename = profile.iconFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        if let cached = imageCache[filename] { return cached }
        guard let image = NSImage(contentsOf: iconsDirectory.appendingPathComponent(filename)) else { return nil }
        imageCache[filename] = image
        return image
    }

    /// One choice drives the editor, notch, profile list and menu, independently of Dock mode.
    func artwork(for profile: Profile, style: DockIconStyle? = nil, margin: CGFloat = 0.1) -> NSImage {
        var value = profile
        if let style { value.dockIconStyle = style }
        let source = applicationURL(for: value)
        let version = source.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String } ?? ""
        let sourceKey = (source?.path ?? "") + ":" + version
        let key = "\(profile.id):\(value.profileIconStyle.rawValue):\(margin)"
        if let cached = artworkCache[key], cached.profile == value, cached.source == sourceKey { return cached.image }
        let vendor = source.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let image = NativeProfileArtwork.preview(profile: value, image: image(for: value), vendor: vendor, margin: margin)
        artworkCache[key] = (value, sourceKey, image)
        return image
    }

    func importImage(from source: URL, for profile: Profile) throws {
        guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(sourceImage, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else {
            throw NSError(domain: "AccountDock", code: 1, userInfo: [NSLocalizedDescriptionKey: "This image cannot be opened. Choose a PNG, JPG, HEIC, or TIFF."])
        }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        let filename = "\(profile.id)-\(UUID().uuidString).png"
        try png.write(to: iconsDirectory.appendingPathComponent(filename), options: .atomic)
        imageCache[filename] = NSImage(cgImage: thumbnail, size: .zero)
        var changed = profile
        changed.iconFilename = filename
        changed.iconIsTile = false
        changed.dockIconStyle = .image
        update(changed)
    }

    func chooseImage(for profile: Profile, window: NSWindow?) {
        let chooser = NSOpenPanel()
        chooser.title = "Picture for \(profile.name)"
        chooser.message = "Choose a logo or picture. ProfileDock keeps a local copy for this profile."
        chooser.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp]
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.prompt = "Use picture"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let source = chooser.url, let self else { return }
            do { try self.importImage(from: source, for: profile) }
            catch { self.message = error.localizedDescription }
        }
        if let window { chooser.beginSheetModal(for: window, completionHandler: completion) }
        else { chooser.begin(completionHandler: completion) }
    }

    func removeImage(for profile: Profile) {
        var changed = profile
        changed.iconFilename = nil
        changed.iconIsTile = nil
        update(changed)
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        tracksApplications = home.resolvingSymlinksInPath() == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: settingsURL))
            }
            let saved = preferences.profiles.filter { Profile.validID($0.id) && ($0.discoveredTerminal == true || FileManager.default.fileExists(atPath: $0.home(in: home).path)) }
            let discovered = try ProfileCatalog.discover(home: home).filter { !(preferences.hiddenProfileIDs ?? []).contains($0.id) }
            preferences.profiles = ProfileCatalog.merge(discovered: discovered + saved.filter { item in !discovered.contains(where: { $0.id == item.id }) }, saved: saved)
            preferences.scale = min(1.3, max(0.85, preferences.scale))
        } catch {
            message = "Could not load preferences: \(error.localizedDescription)"
            preferences.profiles = (try? ProfileCatalog.discover(home: home)) ?? []
        }
        // Decode existing logos once at startup, before the first hover needs them.
        for profile in preferences.profiles { _ = image(for: profile) }
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard tracksApplications else { return }
        if notification.name == NSWorkspace.didActivateApplicationNotification {
            companions.refresh()
            refreshActiveProfile()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              ["com.openai.codex", "com.anthropic.claudefordesktop", "com.apple.Terminal"].contains(app.bundleIdentifier ?? "") || app.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true else { return }
        readinessAttempts = 0
        refresh()
    }

    private func refreshActiveProfile() {
        let active = preferences.profiles.first(where: { profile in
            guard running[profile.id]?.contains(where: \.isActive) == true else { return false }
            return !profile.kind.usesTerminal || companions.window(for: profile).map { $0.selected && $0.front } == true
        })?.id
        if activeProfile != active { activeProfile = active }
    }

    static func arguments(pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 8 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return ProcessIdentity.arguments(from: data.prefix(size))
    }

    func refresh(applications: [NSRunningApplication]? = nil, preparingNativePID: pid_t? = nil) {
        refreshCount += 1
        guard tracksApplications || applications != nil else { return }
        var result: [String: [RunningProfileApplication]] = [:]
        let snapshot = RunningProfileApplication.snapshot(applications: applications ?? NSWorkspace.shared.runningApplications)
        observedApplications = snapshot.applications
        var unreadable = snapshot.unresolved
        for app in observedApplications {
            if app.processIdentifier == preparingNativePID,
               let profile = preferences.profiles.first(where: { NativeDock.identifier($0) == app.bundleIdentifier }),
               let expected = nativeDockURL(for: profile),
               app.bundleURL?.resolvingSymlinksInPath().path == expected.path,
               let executable = try? NativeDockApp.info(expected)["CFBundleExecutable"] as? String,
               RunningProfileApplication.executablePath(pid: app.processIdentifier) == expected.appendingPathComponent("Contents/MacOS/\(executable)").resolvingSymlinksInPath().path {
                // The verified parent shim is waiting for this preparation process.
                // A Finder launch has no user-data argument until the shim execs;
                // do not mistake that one parent for an unidentified ChatGPT app.
                continue
            }
            guard let args = Self.arguments(pid: app.processIdentifier) else {
                if !app.isTerminated { unreadable = true }
                continue
            }
            let id: String?
            if app.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true {
                guard let profile = preferences.profiles.first(where: { NativeDock.identifier($0) == app.bundleIdentifier }),
                      let expected = nativeDockURL(for: profile),
                      app.bundleURL?.resolvingSymlinksInPath().path == expected.path,
                      let info = try? NativeDockApp.info(expected),
                      let data = info[NativeDock.dataKey] as? String,
                      args.contains("--user-data-dir=\(data)") else { unreadable = true; continue }
                id = profile.id
            } else { id = ProcessIdentity.profileID(arguments: args, profiles: preferences.profiles, home: home) }
            guard let id else { continue }
            result[id, default: []].append(app)
        }
        result.merge(companionApplications(applications ?? NSWorkspace.shared.runningApplications)) { _, new in new }
        // Avoid invalidating every SwiftUI view when only an unrelated application activates.
        if running.mapValues({ $0.map(\.processIdentifier).sorted() }) != result.mapValues({ $0.map(\.processIdentifier).sorted() }) { running = result }
        if unreadableProcesses != unreadable { unreadableProcesses = unreadable }
        refreshActiveProfile()
        for id in Array(opening) where result[id]?.isEmpty == false { opening.remove(id) }
        for id in Array(closing) where result[id]?.isEmpty != false { closing.remove(id) }
        if unreadable, readinessAttempts < 12, readinessTimer == nil {
            readinessAttempts += 1
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readinessTimer = nil
                    self?.refresh()
                }
            }
            readinessTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !unreadable {
            readinessTimer?.invalidate()
            readinessTimer = nil
            readinessAttempts = 0
        }
    }

    func showProfileMessage(_ text: String, for profile: Profile, actionTitle: String = "Try Again") {
        message = text
        messageRecovery = ProfileMessageRecovery(profileID: profile.id, title: actionTitle)
    }

    func retryMessage(selectProfile: ((Profile) -> Void)? = nil) {
        let recovery = messageRecovery
        message = nil
        // Resolve the current profile by identity: reordering, renaming or removing an
        // account must never make a recovery button open a different account.
        guard let recovery, let profile = preferences.profiles.first(where: { $0.id == recovery.profileID }) else { return }
        if let selectProfile { selectProfile(profile) }
        else { select(profile) }
    }

    func completeActivation(of profile: Profile, attemptID: UUID, accepted: Bool, reopened: Bool, isActive: Bool) {
        // A delayed result must not replace a newer message or another profile action.
        guard messageID == attemptID else { return }
        if !reopened {
            showProfileMessage("Couldn’t reopen the window for \(profile.name).", for: profile)
        } else if !accepted && !isActive {
            showProfileMessage("Couldn’t bring \(profile.name) to the front.", for: profile)
        }
    }

    func requestQuit(_ profile: Profile) {
        if profile.kind != .codex { closeCompanion(profile); return }
        refresh()
        guard !closing.contains(profile.id), let apps = running[profile.id], !apps.isEmpty else { return }
        closing.insert(profile.id)
        message = nil
        // Send each matched process a normal quit request. ChatGPT retains control over save/confirmation dialogs.
        let accepted = apps.map { $0.terminate() }.allSatisfy { $0 }
        if !accepted {
            closing.remove(profile.id)
            showProfileMessage("\(profile.name) could not close. Check its ChatGPT window for a confirmation.", for: profile, actionTitle: "Show Window")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.refresh()
            if self.closing.remove(profile.id) != nil {
                self.showProfileMessage("\(profile.name) is still open. ChatGPT may be waiting for a confirmation.", for: profile, actionTitle: "Show Window")
            }
        }
    }

    func select(_ profile: Profile) {
        if profile.kind != .codex { selectCompanion(profile); return }
        guard !nativeDockOperations.contains(profile.id) else {
            showProfileMessage("This profile’s Dock app is still being prepared. Wait for it to finish, then try again.", for: profile)
            return
        }
        if let app = applicationURL(for: profile), updatingApplications.contains(app.resolvingSymlinksInPath().standardizedFileURL.path) {
            message = "This app is being updated. It will reopen when the update finishes."
            return
        }
        guard !closing.contains(profile.id) else { return }
        refresh()
        if let apps = running[profile.id], !apps.isEmpty {
            let app = apps.first(where: \.isActive) ?? apps.sorted(by: { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }).first!
            message = nil
            let attemptID = messageID
            app.unhide()
            let accepted = app.activate(options: [.activateAllWindows])
            let reopened: Bool
            do {
                try ApplicationReopen.send(processIdentifier: app.processIdentifier)
                reopened = true
            } catch {
                reopened = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.refresh()
                self.completeActivation(of: profile, attemptID: attemptID, accepted: accepted, reopened: reopened, isActive: app.isActive)
            }
            return
        }
        guard !opening.contains(profile.id) else { return }
        if profile.dockApplicationPath != nil, nativeDockNeedsRebuild(profile) {
            Task {
                do {
                    try await setNativeDockIcon(for: profile, enabled: true)
                    if let updated = preferences.profiles.first(where: { $0.id == profile.id }) { select(updated) }
                } catch { showProfileMessage("Could not update this profile’s Dock app: \(error.localizedDescription)", for: profile) }
            }
            return
        }
        guard !unreadableProcesses else {
            showProfileMessage("ProfileDock couldn’t identify a running ChatGPT app. Wait a moment, then try again.", for: profile)
            return
        }
        guard let appURL = applicationURL(for: profile),
              FileManager.default.fileExists(atPath: profile.home(in: home).path), Profile.validID(profile.id) else {
            message = "Install the current ChatGPT desktop app first."
            return
        }
        let launchURL: URL
        if profile.dockApplicationPath != nil {
            guard let wrapper = nativeDockURL(for: profile) else {
                message = "This profile's Dock app is missing or invalid. Rebuild it from the profile options."
                return
            }
            launchURL = wrapper
        } else { launchURL = appURL }
        message = nil
        opening.insert(profile.id)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ProfileLaunch.arguments(profile: profile, home: home, application: launchURL)
        process.currentDirectoryURL = home
        // A GUI launcher must not inherit another account's CLI authentication or profile overrides.
        process.environment = ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.launches.removeValue(forKey: profile.id)
                if process.terminationStatus != 0 {
                    self.opening.remove(profile.id)
                    let detail = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.showProfileMessage(detail.isEmpty ? "Could not open \(profile.name)." : detail, for: profile)
                }
                self.refresh()
            }
        }
        do {
            launches[profile.id] = process
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.opening.contains(profile.id) else { return }
                self.refresh()
                if self.opening.remove(profile.id) != nil { self.showProfileMessage("\(profile.name) has not appeared yet. Check its ChatGPT window before trying again.", for: profile) }
            }
        } catch {
            launches.removeValue(forKey: profile.id)
            opening.remove(profile.id)
            showProfileMessage("Could not open \(profile.name): \(error.localizedDescription)", for: profile)
        }
    }

    func update(_ profile: Profile) {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var changed = profile
        if changed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        changed.name = String(changed.name.prefix(32))
        preferences.profiles[index] = changed
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == id }), preferences.profiles.indices.contains(index + delta) else { return }
        preferences.profiles.swapAt(index, index + delta)
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: settingsURL, options: .atomic)
            onPreferencesChanged?()
        } catch { message = "Could not save: \(error.localizedDescription)" }
    }

    func state(_ profile: Profile) -> String {
        if closing.contains(profile.id) { return "Closing…" }
        if opening.contains(profile.id) { return "Opening…" }
        if profile.kind.usesTerminal, companions.terminalError != nil { return "Status unavailable" }
        if profile.kind.usesTerminal, let window = companions.window(for: profile), window.agent == nil { return "No coding session" }
        if activeProfile == profile.id { return "Active" }
        return running[profile.id]?.isEmpty == false ? "Open" : "Closed"
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x377CF6
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var rgbHex: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
