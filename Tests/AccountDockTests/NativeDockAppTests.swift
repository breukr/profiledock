import AppKit
import XCTest
import DockCore
import SwiftUI
@testable import AccountDock

final class NativeDockAppTests: XCTestCase {
    func testSourceAndDockUpdatesRollBackTogetherAndPreserveAllPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var entries: [AppReplacement.Entry] = []
        for (index, name) in ["Source", "Work", "Personal"].enumerated() {
            let old = root.appendingPathComponent("\(name).app"), new = root.appendingPathComponent("\(name)-prepared.app")
            for (url, content) in [(old, "old-\(name)"), (new, "new-\(name)")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url.appendingPathComponent("version"))
            }
            entries.append(AppReplacement.Entry(prepared: new, destination: old, native: index > 0))
        }
        XCTAssertThrowsError(try AppReplacement.install(entries) { entry in
            if entry.destination.lastPathComponent == "Personal.app" { throw CocoaError(.fileReadCorruptFile) }
        })
        for entry in entries {
            XCTAssertTrue(try String(contentsOf: entry.destination.appendingPathComponent("version")).hasPrefix("old-"))
            XCTAssertTrue(try String(contentsOf: entry.prepared.appendingPathComponent("version")).hasPrefix("new-"))
        }
        try AppReplacement.install(entries) { _ in }
        for entry in entries {
            XCTAssertTrue(try String(contentsOf: entry.destination.appendingPathComponent("version")).hasPrefix("new-"))
            XCTAssertTrue(try String(contentsOf: entry.prepared.appendingPathComponent("version")).hasPrefix("old-"))
        }
    }

    @MainActor func testInstalledVendorWrapperWithAnEmptyTemporaryProfile() async throws {
        guard ProcessInfo.processInfo.environment["PROFILEDOCK_NATIVE_VENDOR_SMOKE"] == "1" else { throw XCTSkip("Opt-in isolated vendor launch") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("native-vendor-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = Profile(id: "profile-native-smoke-" + UUID().uuidString.lowercased(), name: "Dock Test", color: "009B87")
        try fm.createDirectory(at: profile.home(in: root), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let before = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let shim = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PROFILEDOCK_SHIM_PATH"]))
        let destination = root.appendingPathComponent("ChatGPT Dock Test.app")
        let data = profile.home(in: root).appendingPathComponent("electron-user-data")
        let icon = try NativeDockApp.icon(profile: profile, image: nil)
        try NativeDockApp.build(source: source, profile: profile, home: root, data: data, destination: destination, shim: shim, icon: icon)
        var launched: NSRunningApplication?
        defer {
            // Only the uniquely identified test copy, never a real profile or vendor process.
            if let launched, !launched.isTerminated { launched.terminate() }
        }
        _ = try AppFiles.run("/usr/bin/open", ProfileLaunch.arguments(profile: profile, home: root, application: destination))
        for _ in 0..<80 {
            launched = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == NativeDock.identifier(profile) && $0.bundleURL?.path == destination.path }
            if launched != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let app = try XCTUnwrap(launched, "The real vendor copy should register its own running Dock identity")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(app.isTerminated, "The re-signed vendor app should remain running")
        XCTAssertEqual(app.activationPolicy, .regular)
        XCTAssertNotNil(app.icon)
        let args = try XCTUnwrap(DockModel.arguments(pid: app.processIdentifier))
        if ProcessInfo.processInfo.environment["PROFILEDOCK_NATIVE_INSPECT"] == "1" {
            try JSONSerialization.data(withJSONObject: ["app": destination.path, "pid": app.processIdentifier, "args": args, "bundle": NativeDock.identifier(profile)]).write(to: URL(fileURLWithPath: "/private/tmp/profiledock-native-smoke-state.json"))
        }
        XCTAssertTrue(args.contains("--user-data-dir=\(data.path)"))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), before)
        try AppFiles.verifyVendorApp(source)
        // Keep a bounded pause for optional visual inspection without touching real profiles.
        if ProcessInfo.processInfo.environment["PROFILEDOCK_NATIVE_INSPECT"] == "1" {
            print("NATIVE_DOCK_SMOKE_APP=\(destination.path) PID=\(app.processIdentifier)")
            try await Task.sleep(nanoseconds: 45_000_000_000)
        }
        XCTAssertTrue(app.terminate())
        for _ in 0..<150 { if app.isTerminated { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(app.isTerminated)
        if app.isTerminated { try fm.removeItem(at: root) }
    }

    @MainActor func testClonedFixtureRunsWithDistinctIdentityAndIsolatedEnvironment() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("native-dock-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Vendor.app")
        let macos = source.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let swift = root.appendingPathComponent("fixture.swift")
        try #"""
        import Foundation
        let env = ProcessInfo.processInfo.environment
        let output: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "missing", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing", "home": env["CODEX_HOME"] ?? "missing", "data": env["CODEX_ELECTRON_USER_DATA_PATH"] ?? "missing", "leaked": env["OPENAI_API_KEY"] != nil || env["NODE_OPTIONS"] != nil, "args": CommandLine.arguments]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
        """#.write(to: swift, atomically: true, encoding: .utf8)
        _ = try AppFiles.run("/usr/bin/xcrun", ["swiftc", swift.path, "-o", macos.appendingPathComponent("ChatGPT").path])
        let plist: [String: Any] = ["CFBundleExecutable": "ChatGPT", "CFBundleName": "ChatGPT", "CFBundleIdentifier": "com.example.vendor", "CFBundleVersion": "42", "CFBundlePackageType": "APPL"]
        let before = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try before.write(to: source.appendingPathComponent("Contents/Info.plist"))
        _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        let originalBinary = try Data(contentsOf: macos.appendingPathComponent("ChatGPT"))
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROFILEDOCK_SHIM_PATH"] ?? checkout.appendingPathComponent(".build/debug/ProfileDockShim").path)
        XCTAssertTrue(fm.isExecutableFile(atPath: shim.path), "Build ProfileDockShim before running this test")
        let manager = root.appendingPathComponent("fixture-manager")
        for (id, name, color) in [("alpha", "Alpha", "377CF6"), ("beta", "Beta", "D85252")] {
            let profile = Profile(id: id, name: name, color: color)
            try fm.createDirectory(at: profile.home(in: root), withIntermediateDirectories: true)
            let data = profile.home(in: root).appendingPathComponent("electron-user-data")
            let destination = root.appendingPathComponent("\(name).app")
            let icon = try NativeDockApp.icon(profile: profile, image: nil)
            XCTAssertNotNil(NSImage(data: icon))
            try NativeDockApp.build(source: source, profile: profile, home: root, data: data, destination: destination, shim: shim, icon: icon, manager: manager, verifySource: { _ in })
            let process = Process(), output = Pipe()
            process.executableURL = destination.appendingPathComponent("Contents/MacOS/ChatGPT")
            process.arguments = ["--user-data-dir=/wrong"]
            process.environment = ["OPENAI_API_KEY": "test-sentinel", "NODE_OPTIONS": "test-sentinel", "CODEX_HOME": "/wrong"]
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(result["bundle"] as? String, NativeDock.identifier(profile))
            XCTAssertEqual(result["home"] as? String, profile.home(in: root).path)
            XCTAssertEqual(result["data"] as? String, data.path)
            XCTAssertEqual(result["leaked"] as? Bool, false)
            XCTAssertEqual((result["args"] as? [String])?.dropFirst(), ["--user-data-dir=\(data.path)"])
            XCTAssertThrowsError(try NativeDockApp.build(source: source, profile: profile, home: root, data: data, destination: destination, shim: shim, icon: icon, verifySource: { _ in }))
            _ = try AppFiles.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
            if id == "beta" {
                // A pinned Dock launch must refresh before executing the vendor binary.
                var newer = plist; newer["CFBundleVersion"] = "43"
                try PropertyListSerialization.data(fromPropertyList: newer, format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
                _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
                let prepared = root.appendingPathComponent("new-beta.app"), backup = root.appendingPathComponent("old-beta.app")
                try NativeDockApp.build(source: source, profile: profile, home: root, data: data, destination: prepared, shim: shim, icon: icon, manager: manager, verifySource: { _ in })
                let script = "#!/bin/sh\nset -eu\ntest \"$1\" = --prepare-native-dock\ntest \"$2\" = beta\ntest \"$3\" = \"$PPID\"\n/bin/mv '\(destination.path)' '\(backup.path)'\n/bin/mv '\(prepared.path)' '\(destination.path)'\n"
                try Data(script.utf8).write(to: manager)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.path)
                let refreshed = try AppFiles.run(destination.appendingPathComponent("Contents/MacOS/ChatGPT").path, [])
                let newResult = try XCTUnwrap(JSONSerialization.jsonObject(with: refreshed) as? [String: Any])
                XCTAssertEqual(newResult["version"] as? String, "43")
                XCTAssertEqual(newResult["home"] as? String, profile.home(in: root).path)
                XCTAssertEqual(newResult["bundle"] as? String, NativeDock.identifier(profile))
                try before.write(to: source.appendingPathComponent("Contents/Info.plist"))
                _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), before)
        XCTAssertEqual(try Data(contentsOf: macos.appendingPathComponent("ChatGPT")), originalBinary)
        _ = try AppFiles.run("/usr/bin/codesign", ["--verify", "--strict", source.path])
    }

    @MainActor func testPrepareBesideRunningSourceWithoutReplacingItsLiveBundle() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("native-live-source-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Fixture.app")
        let executable = source.appendingPathComponent("Contents/MacOS/Fixture")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let code = root.appendingPathComponent("Fixture.swift")
        try Data("import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.accessory)\napp.run()\n".utf8).write(to: code)
        #if arch(arm64)
        let target = "arm64-apple-macos14.0"
        #else
        let target = "x86_64-apple-macos14.0"
        #endif
        _ = try AppFiles.run("/usr/bin/xcrun", ["swiftc", "-target", target, code.path, "-o", executable.path])
        let identifier = "com.openai.codex" // Required by the source-installation resolver; match only our exact temporary path below.
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundleName": "Fixture", "CFBundleVersion": "1", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
        _ = try AppFiles.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        let process = Process(); process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var fixture: NSRunningApplication?
        for _ in 0..<40 {
            fixture = NSRunningApplication(processIdentifier: process.processIdentifier)
            if fixture?.bundleURL?.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() { fixture = nil }
            if fixture != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let app = try XCTUnwrap(fixture)
        defer { if !app.isTerminated { app.terminate() } }
        let model = DockModel(home: root)
        var profile = Profile(id: "work", name: "Work", color: "377CF6", applicationPath: source.path)
        model.running[profile.id] = [app]
        XCTAssertNil(model.nativeDockChangeBlocker(for: profile), "An open source must not block preparing a separate Dock bundle")
        let copy = model.nativeDockDirectory.appendingPathComponent("work/ChatGPT.app")
        profile.dockApplicationPath = copy.path
        XCTAssertTrue(model.nativeDockAwaitsRelaunch(profile))
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROFILEDOCK_SHIM_PATH"] ?? checkout.appendingPathComponent(".build/debug/ProfileDockShim").path)
        let original = try Data(contentsOf: executable)
        try NativeDockApp.build(source: source, profile: profile, home: root, data: profile.home(in: root).appendingPathComponent("electron-user-data"), destination: copy, shim: shim, icon: Data("fixture".utf8), verifySource: { _ in })
        XCTAssertEqual(try Data(contentsOf: executable), original)
        XCTAssertFalse(app.isTerminated, "Preparing the new copy must not stop the running source")
        XCTAssertEqual(try NativeDockApp.info(copy)["CFBundleIdentifier"] as? String, NativeDock.identifier(profile))
        profile.dockApplicationPath = source.path
        XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile), "Never replace or remove the running bundle")
        profile.dockApplicationPath = copy.path
        model.opening.insert(profile.id); XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile)); model.opening = []
        model.unreadableProcesses = true; XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile)); model.unreadableProcesses = false
        model.updatingApplications.insert(source.path); XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile)); model.updatingApplications = []
        model.nativeDockOperations.insert(profile.id); XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile)); model.nativeDockOperations = []
        profile.applicationPath = root.appendingPathComponent("Other.app").path
        XCTAssertNotNil(model.nativeDockChangeBlocker(for: profile), "Unknown running locations must block changes")
        XCTAssertFalse(app.isTerminated, "Checking activation must leave the running source alone")
        XCTAssertTrue(app.terminate())
        for _ in 0..<40 { if app.isTerminated { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(app.isTerminated)
    }

    @MainActor func testOlderArtworkIsRebuiltEvenWhenSourceAndProfileAreUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DockModel(home: root)
        let source = root.appendingPathComponent("Source.app")
        let app = model.nativeDockDirectory.appendingPathComponent("work/ChatGPT.app")
        for bundle in [source, app] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        }
        let vendor = ["CFBundleExecutable": "ChatGPT", "CFBundleVersion": "1", "CFBundleIdentifier": "com.openai.codex"]
        try PropertyListSerialization.data(fromPropertyList: vendor, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        var profile = Profile(id: "work", name: "Work", color: "377CF6", applicationPath: source.path)
        profile.dockApplicationPath = app.path
        var info = try NativeDock.patchedInfo(vendor, profile: profile, home: root,
                                             data: profile.home(in: root).appendingPathComponent("electron-user-data"))
        info[NativeDock.sourceKey] = source.path
        for version in [nil, 1, NativeDock.artworkVersion] as [Int?] {
            info[NativeDock.artworkVersionKey] = version
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            XCTAssertEqual(model.nativeDockNeedsRebuild(profile), version != NativeDock.artworkVersion)
        }
    }

    @MainActor func testNativePathMustBeOwnedAndBoundToTheExpectedProfile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".codex-work"), withIntermediateDirectories: true)
        let model = DockModel(home: root)
        var profile = Profile(id: "work", name: "Work", color: "377CF6")
        let app = model.nativeDockDirectory.appendingPathComponent("work/ChatGPT.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try NativeDock.patchedInfo(["CFBundleExecutable": "ChatGPT", "CFBundleVersion": "1"], profile: profile, home: root, data: profile.home(in: root).appendingPathComponent("electron-user-data"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        profile.dockApplicationPath = app.path
        XCTAssertEqual(model.nativeDockURL(for: profile)?.path, app.path)
        profile.id = "other"
        XCTAssertNil(model.nativeDockURL(for: profile))
        profile.id = "work"
        let alias = root.appendingPathComponent("alias.app")
        try fm.createSymbolicLink(at: alias, withDestinationURL: app)
        profile.dockApplicationPath = alias.path
        XCTAssertNil(model.nativeDockURL(for: profile))
    }
}
