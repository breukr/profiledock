import Foundation
import CoreFoundation

@MainActor
protocol DockAutoHideSettings {
    func read() -> Bool?
    func write(_ value: Bool?) throws
}

@MainActor
private final class MacDockAutoHideSettings: DockAutoHideSettings {
    func read() -> Bool? {
        CFPreferencesCopyValue("autohide" as CFString, "com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }
    func write(_ value: Bool?) throws {
        CFPreferencesSetValue("autohide" as CFString, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse } ?? nil, "com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize("com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NSError(domain: "ProfileDock.SystemDock", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS could not save its Dock preference."])
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// Owns only an opt-in autohide change. Pins, orientation and timing stay untouched.
@MainActor
final class SystemDockAutoHide {
    struct Snapshot: Codable { let original: Bool? }
    private let file: URL
    private var enabled = false
    private let settings: any DockAutoHideSettings
    init(directory: URL, settings: (any DockAutoHideSettings)? = nil) {
        file = directory.appendingPathComponent("system-dock-autohide.json")
        self.settings = settings ?? MacDockAutoHideSettings()
    }

    func apply(_ requested: Bool) throws {
        guard requested != enabled else { return }
        if requested {
            // Recover a prior interrupted run before recording a new baseline.
            try restore()
            let original = settings.read()
            if original != true {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Snapshot(original: original)).write(to: file, options: .atomic)
                try settings.write(true)
            }
            enabled = true
        } else {
            try restore()
            enabled = false
        }
    }

    func restore() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        // If the user already turned autohide off in macOS, preserve that choice.
        if settings.read() == true { try settings.write(snapshot.original) }
        try FileManager.default.removeItem(at: file)
    }

}
