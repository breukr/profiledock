import AppKit
import SwiftUI
import DockCore
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct Preferences: Codable {
    var profiles: [Profile] = []
    var scale: Double = 1
    var iconSetVersion: Int?
    var hiddenProfileIDs: [String]?
    var removedProfiles: [Profile]?
}

@MainActor
final class DockModel: ObservableObject {
    @Published var preferences = Preferences()
    @Published var running: [String: [NSRunningApplication]] = [:]
    @Published var activeProfile: String?
    @Published var opening: Set<String> = []
    @Published var closing: Set<String> = []
    @Published var message: String?
    @Published var unreadableProcesses = false
    @Published var updatingApplications: Set<String> = []
    let home: URL
    private let tracksApplications: Bool
    private var readinessTimer: Timer?
    private var readinessAttempts = 0
    private(set) var refreshCount = 0
    private var launches: [String: Process] = [:]
    var settingsURL: URL { home.appendingPathComponent("Library/Application Support/Account Dock/preferences.json") }
    var onPreferencesChanged: (() -> Void)?
    private var imageCache: [String: NSImage] = [:]

    var iconsDirectory: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("Icons") }

    func image(for profile: Profile) -> NSImage? {
        guard let filename = profile.iconFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        if let cached = imageCache[filename] { return cached }
        guard let image = NSImage(contentsOf: iconsDirectory.appendingPathComponent(filename)) else { return nil }
        imageCache[filename] = image
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
        update(changed)
    }

    func chooseImage(for profile: Profile, window: NSWindow?) {
        let chooser = NSOpenPanel()
        chooser.title = "Picture for \(profile.name)"
        chooser.message = "Kies een logo of andere afbeelding. Er wordt een kopie voor de accountbalk saved."
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
            let saved = preferences.profiles.filter { Profile.validID($0.id) && FileManager.default.fileExists(atPath: $0.home(in: home).path) }
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
        if notification.name == NSWorkspace.didActivateApplicationNotification {
            refreshActiveProfile()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        readinessAttempts = 0
        refresh()
    }

    private func refreshActiveProfile() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let active = running.first(where: { $0.value.contains(where: { $0.processIdentifier == pid }) })?.key
        if activeProfile != active { activeProfile = active }
    }

    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 8 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return ProcessIdentity.arguments(from: data.prefix(size))
    }

    func refresh() {
        refreshCount += 1
        guard tracksApplications else { return }
        var result: [String: [NSRunningApplication]] = [:]
        var unreadable = false
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.openai.codex" {
            guard let args = Self.arguments(pid: app.processIdentifier) else {
                if !app.isTerminated { unreadable = true }
                continue
            }
            guard let id = ProcessIdentity.profileID(arguments: args, profiles: preferences.profiles, home: home) else { continue }
            result[id, default: []].append(app)
        }
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

    func requestQuit(_ profile: Profile) {
        refresh()
        guard !closing.contains(profile.id), let apps = running[profile.id], !apps.isEmpty else { return }
        closing.insert(profile.id)
        message = nil
        // Send each matched process a normal quit request. ChatGPT retains control over save/confirmation dialogs.
        let accepted = apps.map { $0.terminate() }.allSatisfy { $0 }
        if !accepted {
            closing.remove(profile.id)
            message = "\(profile.name) could not close. Check the ChatGPT window."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.refresh()
            if self.closing.remove(profile.id) != nil {
                self.message = "\(profile.name) staat nog open. ChatGPT waiting mogelijk op een bevestiging in het venster."
            }
        }
    }

    func select(_ profile: Profile) {
        if let app = applicationURL(for: profile), updatingApplications.contains(app.resolvingSymlinksInPath().standardizedFileURL.path) {
            message = "This app is being updated. It will reopen when the update finishes."
            return
        }
        guard !closing.contains(profile.id) else { return }
        refresh()
        if let apps = running[profile.id], !apps.isEmpty {
            let app = apps.first(where: \.isActive) ?? apps.sorted(by: { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }).first!
            app.unhide()
            let accepted = app.activate(options: [.activateAllWindows])
            message = accepted ? nil : "macOS could not bring \(profile.name) to the front. Try again."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
            return
        }
        guard !opening.contains(profile.id) else { return }
        guard !unreadableProcesses else {
            message = "A running ChatGPT profile is not yet identifiable. Try again once it finishes starting."
            return
        }
        guard let appURL = applicationURL(for: profile),
              FileManager.default.fileExists(atPath: profile.home(in: home).path), Profile.validID(profile.id) else {
            message = "Install the current ChatGPT desktop app first."
            return
        }
        message = nil
        opening.insert(profile.id)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ProfileLaunch.arguments(profile: profile, home: home, application: appURL)
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
                    self.message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not open the app."
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
                if self.opening.remove(profile.id) != nil { self.message = "\(profile.name) has not appeared yet. Check the ChatGPT window before trying again." }
            }
        } catch {
            launches.removeValue(forKey: profile.id)
            opening.remove(profile.id)
            message = error.localizedDescription
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
