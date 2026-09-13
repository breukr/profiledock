import Foundation

public enum AppIconAppearance: String, Codable, CaseIterable, Sendable {
    case auto, dark, light, tinted, clear
    public var label: String { rawValue.capitalized }
}

public struct DesktopDockEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String
    public let applicationPath: String?
    public let processID: Int32?
    public let profileID: String?
    public let isRunning: Bool
    public let isChatGPT: Bool
    public static let groupID = "profiledock:chatgpt"

    public init(id: String, name: String, bundleIdentifier: String = "", applicationPath: String? = nil, processID: Int32? = nil, profileID: String? = nil, isRunning: Bool = false, isChatGPT: Bool = false) {
        self.id = id; self.name = name; self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath; self.processID = processID
        self.profileID = profileID; self.isRunning = isRunning; self.isChatGPT = isChatGPT
    }
}

public enum DesktopDockLayout {
    public static func isChatGPT(bundleIdentifier: String) -> Bool {
        let id = bundleIdentifier.lowercased()
        if id.hasPrefix("nl.breukr.profiledock.launcher.") { return true }
        guard !id.contains(".helper"), !id.contains(".xpc") else { return false }
        return ["com.openai.codex", "com.openai.chat", "com.openai.chatgpt"].contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Projection only: no changes to the original pins or profile order.
    public static func items(_ entries: [DesktopDockEntry], grouped: Bool) -> [DesktopDockEntry] {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.id).inserted }
        guard grouped, unique.contains(where: \.isChatGPT) else { return unique }
        let running = unique.contains { $0.isChatGPT && $0.isRunning }
        var inserted = false
        return unique.compactMap { entry in
            guard entry.isChatGPT else { return entry }
            guard !inserted else { return nil }
            inserted = true
            return DesktopDockEntry(id: DesktopDockEntry.groupID, name: "ChatGPT", isRunning: running, isChatGPT: true)
        }
    }
}
