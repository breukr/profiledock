import AppKit
import DockCore

enum NativeDockStage: Int, Comparable, Sendable {
    case preparingIcon, checkingSource, copying, signing, verifyingCopy, installing, restoring

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var label: String {
        switch self {
        case .preparingIcon: return "Preparing your icon…"
        case .checkingSource: return "Checking the original ChatGPT app…"
        case .copying: return "Copying ChatGPT…"
        case .signing: return "Signing your profile’s copy…"
        case .verifyingCopy: return "Verifying the Dock app…"
        case .installing: return "Installing the Dock app…"
        case .restoring: return "Switching back to the signed app…"
        }
    }
}

/// Local wrapper construction adapted from ai-profiles 1.2.0 (MIT).
/// Vendor files are only read. Re-sign only the moved executable and outer
/// bundle; keep nested vendor frameworks and their signatures intact.
enum NativeDockApp {
    static func info(_ app: URL) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    static func build(source: URL, profile: Profile, home: URL, data: URL, destination: URL, shim: URL, icon: Data,
                      sourceIdentity: URL? = nil, manager: URL? = nil,
                      verifySource: (URL) throws -> Void = AppFiles.verifyVendorApp,
                      progress: @Sendable (NativeDockStage) -> Void = { _ in }) throws {
        progress(.checkingSource)
        try verifySource(source)
        let vendor = try info(source)
        var patched = try NativeDock.patchedInfo(vendor, profile: profile, home: home, data: data)
        patched[NativeDock.sourceKey] = (sourceIdentity ?? source).path
        patched[NativeDock.managerKey] = manager?.path
        guard let executable = vendor["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: shim.path),
              !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".profiledock-native-\(UUID().uuidString).app")
        let entitlementFile = staging.appendingPathExtension("entitlements.plist")
        defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: entitlementFile) }
        // APFS clone: independent files without a full additional copy of every resource.
        progress(.copying)
        _ = try AppFiles.run("/bin/cp", ["-cR", source.path, staging.path])
        let contents = staging.appendingPathComponent("Contents")
        let main = contents.appendingPathComponent("MacOS/\(executable)")
        let binary = main.appendingPathExtension("bin")
        guard !fm.fileExists(atPath: binary.path),
              main.resolvingSymlinksInPath() == main.standardizedFileURL,
              contents.resolvingSymlinksInPath() == contents.standardizedFileURL else { throw CocoaError(.fileWriteNoPermission) }
        let entitlementsOutput = try AppFiles.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", source.path])
        let text = String(decoding: entitlementsOutput, as: UTF8.self)
        var entitlements: [String: Any] = [:]
        if let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") {
            let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
            guard let parsed = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            entitlements = parsed
        }
        let stripped = NativeDock.entitlements(entitlements, team: "2DC432GLL2")
        try writePlist(stripped, to: entitlementFile)
        try writePlist(patched, to: contents.appendingPathComponent("Info.plist"))
        try icon.write(to: contents.appendingPathComponent("Resources/ProfileDockProfile.icns"))
        try fm.moveItem(at: main, to: binary)
        try fm.copyItem(at: shim, to: main)
        progress(.signing)
        for target in [binary, staging] {
            _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementFile.path, target.path])
        }
        progress(.verifyingCopy)
        _ = try AppFiles.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging.path])
        try fm.moveItem(at: staging, to: destination)
    }

    private static func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
    }

    @MainActor static func icon(profile: Profile, image: NSImage?, vendor: NSImage? = nil) throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-icon-\(UUID().uuidString)")
        let iconset = root.appendingPathComponent("Profile.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NativeProfileArtwork.draw(profile: profile, image: image, vendor: vendor, dimension: CGFloat(pixels))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
            }
        }
        let output = root.appendingPathComponent("Profile.icns")
        _ = try AppFiles.run("/usr/bin/iconutil", ["--convert", "icns", "--output", output.path, iconset.path])
        return try Data(contentsOf: output)
    }
}

@MainActor extension DockModel {
    var nativeDockDirectory: URL { home.appendingPathComponent("Applications/ProfileDock Dock Apps") }

    func nativeDockURL(for profile: Profile) -> URL? {
        guard Profile.validID(profile.id), let path = profile.dockApplicationPath else { return nil }
        let app = URL(fileURLWithPath: path).standardizedFileURL
        let expected = nativeDockDirectory.appendingPathComponent(profile.id).appendingPathComponent("ChatGPT.app").standardizedFileURL
        guard app.path == expected.path, app.resolvingSymlinksInPath().path == expected.path,
              let info = try? NativeDockApp.info(app),
              info[NativeDock.profileKey] as? String == profile.id,
              info[NativeDock.homeKey] as? String == profile.home(in: home).path,
              let data = info[NativeDock.dataKey] as? String,
              (profile.id == "default" ? ["Library/Application Support/Codex", "Library/Application Support/ChatGPT"].map { home.appendingPathComponent($0).path } : [profile.home(in: home).appendingPathComponent("electron-user-data").path]).contains(data),
              info["CFBundleIdentifier"] as? String == NativeDock.identifier(profile) else { return nil }
        return app
    }

    func nativeDockNeedsRebuild(_ profile: Profile) -> Bool {
        guard let app = nativeDockURL(for: profile), let info = try? NativeDockApp.info(app),
              let source = applicationURL(for: profile), let vendor = try? NativeDockApp.info(source) else { return true }
        return info[NativeDock.versionKey] as? String != vendor["CFBundleVersion"] as? String
            || info[NativeDock.artworkVersionKey] as? Int != NativeDock.artworkVersion
            || info["CFBundleDisplayName"] as? String != "ChatGPT \(profile.name)"
            || info["ProfileDockNativeColor"] as? String != profile.color
            || info["ProfileDockNativeImage"] as? String != (profile.iconFilename ?? "")
            || info["ProfileDockNativeIconText"] as? String != profile.dockLetters
            || info["ProfileDockNativeIconStyle"] as? String != profile.profileIconStyle.rawValue
            || info[NativeDock.sourceKey] as? String != source.path
    }

    /// Preparing a different bundle is safe while the signed source is running.
    /// Replacing or removing the bundle that owns a live process is not.
    func nativeDockChangeBlocker(for profile: Profile, launchingPID: pid_t? = nil, ownPreparation: Bool = false) -> String? {
        if opening.contains(profile.id) { return "Wait for this profile to finish opening." }
        if !ownPreparation, nativeDockOperations.contains(profile.id) { return "This profile’s Dock app is being prepared." }
        if !updatingApplications.isEmpty { return "Wait for the app update to finish." }
        if unreadableProcesses { return "ProfileDock could not check all running apps. Try again when they finish opening." }
        let source = applicationURL(for: profile)?.resolvingSymlinksInPath().standardizedFileURL
        let copy = URL(fileURLWithPath: profile.dockApplicationPath ?? nativeDockDirectory.appendingPathComponent(profile.id).appendingPathComponent("ChatGPT.app").path).resolvingSymlinksInPath().standardizedFileURL
        let unsafe = (running[profile.id] ?? []).contains { app in
            if app.processIdentifier == launchingPID { return false }
            guard let url = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else { return true }
            return url == copy || url != source || app.bundleIdentifier?.hasPrefix(NativeDock.prefix) == true
        }
        return unsafe ? "Quit this profile’s Dock app before changing its Dock mode. Finish any active tasks first." : nil
    }

    func nativeDockAwaitsRelaunch(_ profile: Profile) -> Bool {
        profile.dockApplicationPath != nil && running[profile.id]?.isEmpty == false
            && nativeDockChangeBlocker(for: profile) == nil
    }

    func setNativeDockIcon(for requested: Profile, enabled: Bool, launchingPID: pid_t? = nil,
                           verifySource: @escaping @Sendable (URL) throws -> Void = { try AppFiles.verifyVendorApp($0) },
                           trashCopy: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async throws {
        refresh(preparingNativePID: launchingPID)
        guard let profile = preferences.profiles.first(where: { $0.id == requested.id }) else {
            throw AppOperationError.message("This profile is no longer available.")
        }
        if let reason = nativeDockChangeBlocker(for: profile, launchingPID: launchingPID) { throw AppOperationError.message(reason) }
        nativeDockOperations.insert(profile.id)
        nativeDockProgress[profile.id] = enabled ? .preparingIcon : .checkingSource
        defer { nativeDockProgress.removeValue(forKey: profile.id); nativeDockOperations.remove(profile.id) }
        let parent = nativeDockDirectory.appendingPathComponent(profile.id)
        guard parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lock = try NativeDockLock(directory: parent)
        defer { lock.release() }
        if !enabled {
            // Do not discard the working copy unless its original is still available
            // and signed by OpenAI. Switching mode never moves or removes account data.
            guard let source = applicationURL(for: profile) else {
                throw AppOperationError.message("The original ChatGPT app is missing. Reinstall it before disabling the Dock copy. Your copy and profile data have been kept.")
            }
            do { try await Task.detached { try verifySource(source) }.value }
            catch { throw AppOperationError.message("The original ChatGPT app could not be verified. Reinstall the official app before switching back. Your Dock copy and profile data have been kept.") }
            refresh(preparingNativePID: launchingPID)
            guard nativeDockChangeBlocker(for: profile, launchingPID: launchingPID, ownPreparation: true) == nil,
                  preferences.profiles.first(where: { $0.id == profile.id }) == profile,
                  applicationURL(for: profile) == source else {
                throw AppOperationError.message("This profile changed or its Dock app opened. Close the Dock app and try again.")
            }
            nativeDockProgress[profile.id] = .restoring
            // Remove the executable wrapper as well: a pinned stale icon must not reopen it.
            guard let app = nativeDockURL(for: profile) else {
                if let path = profile.dockApplicationPath, FileManager.default.fileExists(atPath: path) {
                    throw AppOperationError.message("This Dock app could not be verified. It was left in place.")
                }
                var updated = profile; updated.dockApplicationPath = nil; update(updated); return
            }
            try trashCopy(app)
            var updated = profile; updated.dockApplicationPath = nil; update(updated)
            return
        }
        guard let source = applicationURL(for: profile) else { throw AppOperationError.message("Install the signed ChatGPT app first.") }
        let destination = nativeDockDirectory.appendingPathComponent(profile.id).appendingPathComponent("ChatGPT.app")
        let exists = FileManager.default.fileExists(atPath: destination.path)
        guard !exists || nativeDockURL(for: profile)?.path == destination.path else { throw CocoaError(.fileWriteFileExists) }
        let prepared = parent.appendingPathComponent(".prepared-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: prepared) }
        try await prepareNativeDockCopy(profile: profile, source: source, sourceIdentity: source, destination: prepared, verifySource: verifySource)
        // A Finder/Dock click may have launched a profile while the copy was building.
        refresh(preparingNativePID: launchingPID)
        guard nativeDockChangeBlocker(for: profile, launchingPID: launchingPID, ownPreparation: true) == nil,
              preferences.profiles.first(where: { $0.id == profile.id }) == profile else {
            throw AppOperationError.message("This profile changed or its Dock app opened while building. Close the Dock app and try again.")
        }
        nativeDockProgress[profile.id] = .installing
        if exists { try AppReplacement.swap(prepared: prepared, destination: destination) }
        else { try FileManager.default.moveItem(at: prepared, to: destination) }
        if profile.dockApplicationPath != destination.path {
            var updated = profile; updated.dockApplicationPath = destination.path; update(updated)
        }
        NSWorkspace.shared.noteFileSystemChanged(destination.path)
    }

    func prepareNativeDockCopy(profile: Profile, source: URL, sourceIdentity: URL, destination: URL,
                               verifySource: @escaping @Sendable (URL) throws -> Void = { try AppFiles.verifyVendorApp($0) }) async throws {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("ProfileDockShim"), Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ProfileDockShim")]
        guard let shim = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppOperationError.message("The profile helper is missing. Rebuild or reinstall ProfileDock.")
        }
        let icon = try NativeDockApp.icon(profile: profile, image: image(for: profile), vendor: NSWorkspace.shared.icon(forFile: source.path))
        let data: URL
        if let existing = nativeDockURL(for: profile), let info = try? NativeDockApp.info(existing), let path = info[NativeDock.dataKey] as? String { data = URL(fileURLWithPath: path) }
        else if profile.id == "default" {
            let candidates = ["Library/Application Support/Codex", "Library/Application Support/ChatGPT"].map { home.appendingPathComponent($0) }
            data = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? candidates[0]
        } else { data = profile.home(in: home).appendingPathComponent("electron-user-data") }
        let userHome = home, manager = Bundle.main.executableURL
        let progress: @Sendable (NativeDockStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard let self, self.nativeDockOperations.contains(profile.id),
                      let current = self.nativeDockProgress[profile.id], stage > current else { return }
                self.nativeDockProgress[profile.id] = stage
            }
        }
        try await Task.detached {
            try NativeDockApp.build(source: source, profile: profile, home: userHome, data: data, destination: destination, shim: shim, icon: icon, sourceIdentity: sourceIdentity, manager: manager, verifySource: verifySource, progress: progress)
        }.value
    }
}

/// Shared by the updater and launch-time repair, including other ProfileDock processes.
final class NativeDockLock {
    private var descriptor: Int32
    init(directory: URL) throws {
        descriptor = Darwin.open(directory.appendingPathComponent(".build.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw AppOperationError.message("Another process is updating this Dock app. Try again shortly.")
        }
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { release() }
}
