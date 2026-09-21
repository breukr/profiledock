import AppKit

enum AppVisibility {
    static func activationPolicy(preferences: Preferences, settingsOpen: Bool) -> NSApplication.ActivationPolicy {
        // Accessory apps cannot own a menu bar. Temporarily become a regular
        // app while Settings is open, then restore the background preference.
        preferences.showDockIcon == true || settingsOpen ? .regular : .accessory
    }
}

extension Notification.Name {
    static let profileDockShowUpdates = Notification.Name("nl.breukr.profiledock.show-updates")
}
