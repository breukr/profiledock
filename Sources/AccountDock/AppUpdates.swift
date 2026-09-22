import AppKit
import Combine
import CryptoKit
import Darwin
import DockCore

final class VendorDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let progress: @Sendable (DownloadProgress) -> Void
    private var lastReport = Date.distantPast
    init(expected: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) { self.expected = expected; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expected else { downloadTask.cancel(); return }
        guard totalBytesWritten == expected || Date().timeIntervalSince(lastReport) >= 0.1 else { return }
        lastReport = Date()
        progress(DownloadProgress(received: totalBytesWritten, expected: expected))
    }
}

enum VendorDownload {
    static let feed = URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")!
    // Public Ed25519 key shipped in OpenAI's desktop application, not a credential.
    static let publicKey = "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="

    static func prepare(_ release: VendorRelease, in directory: URL, configuration: URLSessionConfiguration = .ephemeral, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }, verifying: @escaping @Sendable () -> Void = {}) async throws -> URL {
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let observer = VendorDownloadObserver(expected: Int64(release.length), progress: progress)
        let (temporary, response) = try await session.download(from: release.url, delegate: observer)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let final = response.url, VendorRelease.allowedDownload(final) else { throw AppOperationError.message("The download was not served by OpenAI's update server.") }
        let archive = directory.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        verifying()
        let prepared = try await Task.detached {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey)!)
            guard data.count == release.length, key.isValidSignature(release.signature, for: data) else {
                throw AppOperationError.message("The update signature is invalid. Your apps have not been changed.")
            }
            let extracted = directory.appendingPathComponent("extracted")
            _ = try AppFiles.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
            let apps = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first else { throw AppOperationError.message("Unexpected update contents.") }
            try AppFiles.verifyVendorApp(app)
            guard AppUpdates.installedBuild(at: app) == release.build else { throw AppOperationError.message("The downloaded app does not match the advertised version.") }
            return app
        }.value
        try Task.checkCancellation()
        return prepared
    }
}

enum AppReplacement {
    struct Entry {
        let prepared: URL
        let destination: URL
        let native: Bool
    }

    /// A group includes its signed source and every enabled Dock copy. If any
    /// verification fails, restore all exchanged apps in reverse order.
    static func install(_ entries: [Entry], verify: (Entry) throws -> Void) throws {
        var exchanged: [Entry] = []
        do {
            for entry in entries {
                try swap(prepared: entry.prepared, destination: entry.destination)
                exchanged.append(entry)
                try verify(entry)
            }
        } catch {
            var recoveryFailed = false
            for entry in exchanged.reversed() {
                do { try swap(prepared: entry.prepared, destination: entry.destination) }
                catch { recoveryFailed = true }
            }
            if recoveryFailed {
                throw AppOperationError.message("The update could not be fully restored. Keep the hidden .profiledock-backup files beside the apps for recovery.")
            }
            throw error
        }
    }
    /// Exchange two directories atomically on the same filesystem. Keep the old app for recovery.
    static func swap(prepared: URL, destination: URL) throws {
        let result = prepared.path.withCString { source in
            destination.path.withCString { target in renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_SWAP)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

@MainActor
final class AppUpdates: ObservableObject {
    @Published var latest: VendorRelease?
    @Published var checking = false
    @Published var busy = false
    @Published var status: String?
    @Published var error: String?
    @Published var selected: Set<String> = []
    @Published private(set) var progress: DownloadProgress?
    @Published private(set) var canCancel = false
    @Published private(set) var cancelling = false
    @Published private(set) var verifying = false
    private var task: Task<Void, Never>?

    func cancel() {
        guard canCancel, !cancelling else { return }
        cancelling = true; canCancel = false
        status = "Cancelling… Your ChatGPT apps will stay open."
        task?.cancel()
    }

    nonisolated static func installedBuild(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    nonisolated static func installedVersion(at url: URL) -> String {
        (try? NativeDockApp.info(url)["CFBundleShortVersionString"] as? String) ?? "Unknown version"
    }

    func needsUpdate(_ group: AppUpdateGroup) -> Bool {
        guard let latest, let installed = Self.installedBuild(at: group.application) else { return false }
        return installed < latest.build
    }

    func check() async {
        guard !checking, !busy else { return }
        checking = true; error = nil
        defer { checking = false }
        do {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: VendorDownload.feed)
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { throw AppOperationError.message("OpenAI's update feed is unavailable.") }
            let architecture = "arm64"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            latest = try UpdateFeed.latest(data: data, architecture: architecture, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            status = latest.map { "Latest ChatGPT release: \($0.version)" } ?? "No compatible ChatGPT release is listed for this Mac. Use ChatGPT's own update menu."
        } catch { self.error = error.localizedDescription }
    }

    func install(groups: [AppUpdateGroup], model: DockModel, activity: ActivityMonitor) {
        guard !busy, model.nativeDockOperations.isEmpty, let release = latest, !groups.isEmpty else { return }
        busy = true; error = nil; canCancel = true; cancelling = false; verifying = false
        progress = DownloadProgress(received: 0, expected: Int64(release.length))
        task = Task {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-update-" + UUID().uuidString)
            var reopen: [Profile] = []
            defer {
                try? FileManager.default.removeItem(at: workspace)
                model.updatingApplications = []
                model.refresh()
                for profile in reopen where model.running[profile.id]?.isEmpty != false { model.select(profile) }
                busy = false; canCancel = false; cancelling = false; verifying = false; progress = nil; task = nil
            }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                status = "Downloading ChatGPT \(release.version)… You can keep working."
                let prepared = try await VendorDownload.prepare(release, in: workspace, progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.busy, self.canCancel, !self.verifying else { return }
                        self.progress = progress
                    }
                }, verifying: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.busy, !self.cancelling else { return }
                        self.verifying = true
                        self.status = "Verifying the ChatGPT download…"
                    }
                })
                try Task.checkCancellation()
                canCancel = false; verifying = false; progress = nil
                let currentGroups = AppUpdateGroup.make(profiles: model.preferences.profiles, defaultApplication: model.defaultApplication)
                guard groups.allSatisfy({ group in currentGroups.contains(group) && needsUpdate(group) }) else {
                    throw AppOperationError.message("The profiles or installed versions changed. Check for updates again.")
                }
                model.updatingApplications = Set(groups.map(\.id))
                for group in groups {
                    try Task.checkCancellation()
                    model.refresh()
                    guard group.profiles.allSatisfy({ (activity.entries[$0.id]?.working ?? 0) == 0 && (activity.entries[$0.id]?.waiting ?? 0) == 0 }) else {
                        throw AppOperationError.message("A selected profile has an active task. Let it finish before updating this app group.")
                    }
                    guard !model.unreadableProcesses else { throw AppOperationError.message("A running profile cannot be identified yet. Try again once it has started.") }
                    let nativeProfiles = group.profiles.filter { $0.dockApplicationPath != nil }
                    let nativeApps = try nativeProfiles.map { profile -> URL in
                        guard let app = model.nativeDockURL(for: profile) else { throw AppOperationError.message("Repair or disable the native Dock icon for \(profile.name) before updating.") }
                        return app
                    }
                    let locks = try nativeApps.map { try NativeDockLock(directory: $0.deletingLastPathComponent()) }
                    defer { locks.forEach { $0.release() } }
                    let paths = Set(([group.application] + nativeApps).map { $0.resolvingSymlinksInPath().path })
                    var apps = model.observedApplications.filter { app in app.bundleURL.map { paths.contains($0.resolvingSymlinksInPath().path) } ?? false }
                    let known = Set(group.profiles.flatMap { model.running[$0.id] ?? [] }.map(\.processIdentifier))
                    guard apps.allSatisfy({ known.contains($0.processIdentifier) }) else {
                        throw AppOperationError.message("This app also has an unlisted window. Close it yourself before updating this group.")
                    }
                    try await Task.detached { try AppFiles.verifyVendorApp(group.application) }.value
                    let staged = group.application.deletingLastPathComponent().appendingPathComponent(".profiledock-backup-" + UUID().uuidString + ".app")
                    status = "Preparing \(group.profiles.map(\.name).joined(separator: ", "))…"
                    try await Task.detached { try AppFiles.copyVendorApp(from: prepared, to: staged) }.value
                    var replacements = [AppReplacement.Entry(prepared: staged, destination: group.application, native: false)]
                    do {
                        for (profile, app) in zip(nativeProfiles, nativeApps) {
                            status = "Preparing the updated Dock app for \(profile.name)…"
                            let rebuilt = app.deletingLastPathComponent().appendingPathComponent(".profiledock-backup-native-\(UUID().uuidString).app")
                            try await model.prepareNativeDockCopy(profile: profile, source: prepared, sourceIdentity: group.application, destination: rebuilt)
                            replacements.append(AppReplacement.Entry(prepared: rebuilt, destination: app, native: true))
                        }
                        model.refresh()
                        apps = model.observedApplications.filter { app in app.bundleURL.map { paths.contains($0.resolvingSymlinksInPath().path) } ?? false }
                        let currentKnown = Set(group.profiles.flatMap { model.running[$0.id] ?? [] }.map(\.processIdentifier))
                        guard apps.allSatisfy({ currentKnown.contains($0.processIdentifier) }), !model.unreadableProcesses else { throw AppOperationError.message("An unlisted profile opened while preparing the update. Close it and try again.") }
                        guard group.profiles.allSatisfy({ profile in
                            guard model.running[profile.id]?.isEmpty == false else { return true }
                            guard let state = activity.entries[profile.id], state.liveAvailable else { return false }
                            return state.working == 0 && state.waiting == 0
                        }) else {
                            throw AppOperationError.message("A selected profile is busy or its task status is unknown. Finish its work or close it yourself before updating.")
                        }
                        reopen.append(contentsOf: group.profiles.filter { model.running[$0.id]?.isEmpty == false })
                        status = "Waiting for the selected profiles to close. Finish any confirmation in ChatGPT."
                        for app in apps { guard app.terminate() else { throw AppOperationError.message("ChatGPT declined to close. The update has been cancelled.") } }
                        let deadline = Date().addingTimeInterval(60)
                        while apps.contains(where: { !$0.isTerminated }), Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
                        model.refresh()
                        guard apps.allSatisfy(\.isTerminated), !model.unreadableProcesses,
                              !model.observedApplications.contains(where: { app in app.bundleURL.map { paths.contains($0.resolvingSymlinksInPath().path) } ?? false }) else {
                            throw AppOperationError.message("This app is still running. Nothing was replaced; close it and try again.")
                        }
                        status = "Installing \(release.version)…"
                        let transaction = replacements
                        try await Task.detached {
                            try AppReplacement.install(transaction) { entry in
                                if entry.native { _ = try AppFiles.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", entry.destination.path]) }
                                else { try AppFiles.verifyVendorApp(entry.destination) }
                            }
                        }.value
                        for app in nativeApps { NSWorkspace.shared.noteFileSystemChanged(app.path) }
                        // Old apps remain in hidden backups beside the new apps.
                    } catch {
                        // Keep all prepared/backup paths, including after a failed rollback.
                        throw error
                    }
                }
                status = "Updated \(groups.count) app \(groups.count == 1 ? "group" : "groups"). Reopening the profiles that were running."
                selected = []
            } catch {
                if Task.isCancelled {
                    self.error = nil; status = "Download cancelled. Your ChatGPT apps are unchanged."
                } else {
                    self.error = error.localizedDescription; status = "The update stopped. Completed groups keep their new version; the remaining apps are unchanged."
                }
            }
        }
    }
}
