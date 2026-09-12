import AppKit
import Combine
import CryptoKit
import Darwin
import DockCore

enum VendorDownload {
    static let feed = URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")!
    // Public Ed25519 key shipped in OpenAI's desktop application, not a credential.
    static let publicKey = "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="

    static func prepare(_ release: VendorRelease, in directory: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: release.url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let final = response.url, VendorRelease.allowedDownload(final) else { throw AppOperationError.message("The download was not served by OpenAI's update server.") }
        let archive = directory.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        return try await Task.detached {
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
    }
}

enum AppReplacement {
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
    private var task: Task<Void, Never>?

    nonisolated static func installedBuild(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["CFBundleVersion"] as? String).flatMap(Int.init)
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
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let os = ProcessInfo.processInfo.operatingSystemVersion
            latest = try UpdateFeed.latest(data: data, architecture: architecture, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            status = latest.map { "Latest release: \($0.version)" } ?? "No compatible release is listed for this Mac. Use ChatGPT's own update menu."
        } catch { self.error = error.localizedDescription }
    }

    func install(groups: [AppUpdateGroup], model: DockModel, activity: ActivityMonitor) {
        guard !busy, let release = latest, !groups.isEmpty else { return }
        busy = true; error = nil
        task = Task {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("profiledock-update-" + UUID().uuidString)
            var reopen: [Profile] = []
            defer {
                try? FileManager.default.removeItem(at: workspace)
                model.updatingApplications = []
                model.refresh()
                for profile in reopen where model.running[profile.id]?.isEmpty != false { model.select(profile) }
                busy = false
            }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                status = "Downloading and verifying ChatGPT \(release.version)… You can keep working."
                let prepared = try await VendorDownload.prepare(release, in: workspace)
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
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == group.application }
                    let known = Set(group.profiles.flatMap { model.running[$0.id] ?? [] }.map(\.processIdentifier))
                    guard apps.allSatisfy({ known.contains($0.processIdentifier) }) else {
                        throw AppOperationError.message("This app also has an unlisted window. Close it yourself before updating this group.")
                    }
                    try await Task.detached { try AppFiles.verifyVendorApp(group.application) }.value
                    let staged = group.application.deletingLastPathComponent().appendingPathComponent(".profiledock-backup-" + UUID().uuidString + ".app")
                    status = "Preparing \(group.profiles.map(\.name).joined(separator: ", "))…"
                    try await Task.detached { try AppFiles.copyVendorApp(from: prepared, to: staged) }.value
                    var exchanged = false
                    do {
                        model.refresh()
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
                        guard apps.allSatisfy(\.isTerminated), !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == group.application }) else {
                            throw AppOperationError.message("This app is still running. Nothing was replaced; close it and try again.")
                        }
                        status = "Installing \(release.version)…"
                        try AppReplacement.swap(prepared: staged, destination: group.application)
                        exchanged = true
                        do { try await Task.detached { try AppFiles.verifyVendorApp(group.application) }.value }
                        catch { try AppReplacement.swap(prepared: staged, destination: group.application); exchanged = false; throw error }
                        // The old signed app remains in the hidden backup beside the new app.
                    } catch {
                        if !exchanged { try? FileManager.default.removeItem(at: staged) }
                        throw error
                    }
                }
                status = "Updated \(groups.count) app \(groups.count == 1 ? "group" : "groups"). Reopening the profiles that were running."
                selected = []
            } catch { self.error = error.localizedDescription; status = "The update stopped. Completed groups keep their new version; the remaining apps are unchanged." }
        }
    }
}
