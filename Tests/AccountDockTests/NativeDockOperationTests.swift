import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class NativeDockOperationTests: XCTestCase {
    @MainActor func testDisableVerifiesCurrentSourceAndPreservesDataOnSuccessAndFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("native-restore-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let model = DockModel(home: root)
        let source = root.appendingPathComponent("Current ChatGPT.app")
        let vendor: [String: Any] = ["CFBundleExecutable": "ChatGPT", "CFBundleVersion": "99", "CFBundleIdentifier": "com.openai.codex"]
        var profile = Profile(id: "work", name: "Work", color: "377CF6", applicationPath: source.path)
        let copy = model.nativeDockDirectory.appendingPathComponent("work/ChatGPT.app")
        profile.dockApplicationPath = copy.path
        let data = profile.home(in: root).appendingPathComponent("electron-user-data")
        for folder in [source.appendingPathComponent("Contents"), copy.appendingPathComponent("Contents"), data] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let sourceInfo = try PropertyListSerialization.data(fromPropertyList: vendor, format: .xml, options: 0)
        try sourceInfo.write(to: source.appendingPathComponent("Contents/Info.plist"))
        var oldVendor = vendor; oldVendor["CFBundleVersion"] = "42"
        let patched = try NativeDock.patchedInfo(oldVendor, profile: profile, home: root, data: data)
        try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0).write(to: copy.appendingPathComponent("Contents/Info.plist"))
        let sentinel = Data("isolated test profile data".utf8)
        let preserved = [profile.home(in: root).appendingPathComponent("auth.json"), data.appendingPathComponent("Preferences")]
        for path in preserved { try sentinel.write(to: path) }
        model.preferences.profiles = [profile]; model.save()
        let preferences = try Data(contentsOf: model.settingsURL)

        // A fake/unsigned source must fail the production OpenAI signature check.
        do {
            try await model.setNativeDockIcon(for: profile, enabled: false)
            XCTFail("An unverified source must not discard the usable Dock copy")
        } catch {}
        XCTAssertEqual(model.preferences.profiles.first, profile)
        XCTAssertEqual(try Data(contentsOf: model.settingsURL), preferences)
        XCTAssertTrue(fm.fileExists(atPath: copy.path))
        XCTAssertTrue(model.nativeDockOperations.isEmpty)
        XCTAssertTrue(model.nativeDockProgress.isEmpty)

        let checking = expectation(description: "Background verification started")
        let release = DispatchSemaphore(value: 0)
        let removed = root.appendingPathComponent("Discarded copy.app")
        let operation = Task { @MainActor in
            try await model.setNativeDockIcon(for: profile, enabled: false, verifySource: { url in
                XCTAssertEqual(url.path, source.path)
                XCTAssertEqual(try NativeDockApp.info(url)["CFBundleVersion"] as? String, "99", "Use the current original, not the copy's older version")
                checking.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            }, trashCopy: { try fm.moveItem(at: $0, to: removed) })
        }
        await fulfillment(of: [checking], timeout: 3)
        XCTAssertTrue(model.nativeDockOperations.contains(profile.id))
        XCTAssertEqual(model.nativeDockProgress[profile.id], .checkingSource, "The UI remains responsive and reports real work")
        XCTAssertTrue(fm.fileExists(atPath: copy.path), "Keep the copy until verification finishes")
        release.signal()
        try await operation.value
        let updated = try XCTUnwrap(model.preferences.profiles.first)
        var expected = profile; expected.dockApplicationPath = nil
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(model.applicationURL(for: updated)?.path, source.path)
        XCTAssertFalse(fm.fileExists(atPath: copy.path))
        XCTAssertTrue(fm.fileExists(atPath: removed.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), sourceInfo)
        for path in preserved { XCTAssertEqual(try Data(contentsOf: path), sentinel) }
        let args = ProfileLaunch.arguments(profile: updated, home: root, application: source)
        XCTAssertTrue(args.contains("--user-data-dir=\(data.path)"))
        XCTAssertTrue(args.contains("CODEX_HOME=\(profile.home(in: root).path)"))
        XCTAssertTrue(model.nativeDockOperations.isEmpty)
        XCTAssertTrue(model.nativeDockProgress.isEmpty)
    }

    @MainActor func testDockLaunchIsRecognizedReopenedAndProtectedAfterExec() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("native-process-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let model = DockModel(home: root)
        var profile = Profile(id: "profile-fixture-" + UUID().uuidString.lowercased(), name: "Process Test", color: "377CF6")
        let source = root.appendingPathComponent("Fixture.app")
        let executable = source.appendingPathComponent("Contents/MacOS/ChatGPT")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile.home(in: root), withIntermediateDirectories: true)
        let code = root.appendingPathComponent("Fixture.swift")
        try #"""
        import AppKit
        class Delegate: NSObject, NSApplicationDelegate {
            func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
                let home = ProcessInfo.processInfo.environment["CODEX_HOME"]!
                try! Data("reopened".utf8).write(to: URL(fileURLWithPath: home).appendingPathComponent("reopen-event"))
                return true
            }
        }
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        """#.write(to: code, atomically: true, encoding: .utf8)
        #if arch(arm64)
        let target = "arm64-apple-macos14.0"
        #else
        let target = "x86_64-apple-macos14.0"
        #endif
        _ = try AppFiles.run("/usr/bin/xcrun", ["swiftc", "-target", target, code.path, "-o", executable.path])
        let vendor: [String: Any] = ["CFBundleExecutable": "ChatGPT", "CFBundleIdentifier": "com.openai.codex", "CFBundleName": "Fixture", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: vendor, format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
        _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        let copy = model.nativeDockDirectory.appendingPathComponent(profile.id).appendingPathComponent("ChatGPT.app")
        defer {
            // Failure cleanup is restricted to this UUID-scoped fixture binary.
            // A test failure must never leave an orphan app behind.
            let path = copy.appendingPathComponent("Contents/MacOS/ChatGPT.bin").path
            for pid in RunningProfileApplication.kernelProcesses()[path] ?? [] where pid > 0 {
                if RunningProfileApplication.executablePath(pid: pid) == path { kill(pid, SIGTERM) }
            }
        }
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        profile.applicationPath = source.path; profile.dockApplicationPath = copy.path
        model.preferences.profiles = [profile]
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROFILEDOCK_SHIM_PATH"] ?? checkout.appendingPathComponent(".build/debug/ProfileDockShim").path)
        try NativeDockApp.build(source: source, profile: profile, home: root, data: profile.home(in: root).appendingPathComponent("electron-user-data"), destination: copy, shim: shim, icon: Data("fixture".utf8), verifySource: { _ in })
        var running: RunningProfileApplication?
        defer { if let running, !running.isTerminated { _ = running.terminate() } }
        _ = try AppFiles.run("/usr/bin/open", ["-g", "-n", "-a", copy.path])
        for _ in 0..<50 {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == copy.path }
            model.refresh(applications: apps)
            running = model.running[profile.id]?.first
            if running != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let app = try XCTUnwrap(running)
        XCTAssertGreaterThan(app.processIdentifier, 0)
        XCTAssertFalse(model.unreadableProcesses)
        XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile), "Never replace or remove this live Dock app")
        model.refresh(applications: [app.application], preparingNativePID: app.processIdentifier)
        XCTAssertEqual(model.running[profile.id]?.first?.processIdentifier, app.processIdentifier,
                       "The vendor process must never be excluded as a waiting launcher")
        XCTAssertNil(DockModel.arguments(pid: -1))
        let kernel = RunningProfileApplication.kernelProcesses()
        XCTAssertEqual(RunningProfileApplication.recover(app.application, kernel: kernel).map(\.processIdentifier), [app.processIdentifier])
        XCTAssertTrue(RunningProfileApplication.recover(app.application, kernel: [:]).isEmpty)
        XCTAssertNil(RunningProfileApplication(app.application, processIdentifier: ProcessInfo.processInfo.processIdentifier), "Never pair an unrelated PID with the native app")
        let args = try XCTUnwrap(DockModel.arguments(pid: app.processIdentifier))
        XCTAssertEqual(args.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       copy.appendingPathComponent("Contents/MacOS/ChatGPT.bin").resolvingSymlinksInPath().path)
        XCTAssertTrue(args.contains("--user-data-dir=\(profile.home(in: root).appendingPathComponent("electron-user-data").path)"))
        try ApplicationReopen.send(processIdentifier: app.processIdentifier)
        let reopened = profile.home(in: root).appendingPathComponent("reopen-event")
        for _ in 0..<30 {
            if fm.fileExists(atPath: reopened.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try String(contentsOf: reopened, encoding: .utf8), "reopened")
        XCTAssertTrue(app.terminate())
        for _ in 0..<30 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(app.isTerminated, "Graceful quit must address the resolved process")

        // A pinned launch that is rebuilding an outdated copy waits in its main
        // executable before it injects --user-data-dir and execs ChatGPT.bin.
        var waiting = Profile(id: profile.id + "-waiting", name: "Waiting Fixture", color: "377CF6")
        let waitingCopy = model.nativeDockDirectory.appendingPathComponent(waiting.id).appendingPathComponent("ChatGPT.app")
        let waitingExecutable = waitingCopy.appendingPathComponent("Contents/MacOS/ChatGPT")
        try fm.createDirectory(at: waitingCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: waitingCopy)
        let waitingInfo = try NativeDock.patchedInfo(vendor, profile: waiting, home: root,
            data: waiting.home(in: root).appendingPathComponent("electron-user-data"))
        try PropertyListSerialization.data(fromPropertyList: waitingInfo, format: .xml, options: 0)
            .write(to: waitingCopy.appendingPathComponent("Contents/Info.plist"))
        _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", waitingCopy.path])
        waiting.dockApplicationPath = waitingCopy.path
        model.preferences.profiles.append(waiting)
        defer {
            let path = waitingExecutable.resolvingSymlinksInPath().path
            for pid in RunningProfileApplication.kernelProcesses()[path] ?? [] where pid > 0 {
                if RunningProfileApplication.executablePath(pid: pid) == path { kill(pid, SIGTERM) }
            }
        }
        _ = try AppFiles.run("/usr/bin/open", ["-g", "-n", "-a", waitingCopy.path])
        var waitingApp: RunningProfileApplication?
        for _ in 0..<50 {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == waitingCopy.path }
            waitingApp = RunningProfileApplication.snapshot(applications: apps).applications.first
            if waitingApp != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let launcher = try XCTUnwrap(waitingApp)
        model.refresh(applications: [launcher.application])
        XCTAssertTrue(model.unreadableProcesses, "Ordinary detection must wait for the shim to finish")
        model.refresh(applications: [launcher.application], preparingNativePID: launcher.processIdentifier)
        XCTAssertFalse(model.unreadableProcesses, "The verified waiting parent must not block its own preparation")
        XCTAssertTrue(model.running.isEmpty)
        model.refresh(applications: [launcher.application], preparingNativePID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(model.unreadableProcesses, "An unrelated PID cannot bypass the safety check")
        XCTAssertTrue(launcher.terminate())
        for _ in 0..<30 { if launcher.isTerminated { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(launcher.isTerminated)
    }
}
