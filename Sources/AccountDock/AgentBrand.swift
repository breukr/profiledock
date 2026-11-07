import AppKit
import DockCore

/// The real app logo of a coding tool, so profiles are recognizable by the app they use (Sam, 2026-11-07).
/// Looks up an installed app by bundle identifier through Launch Services (macOS's app database); returns nil for
/// command-line tools without a desktop app, which keep their colored monogram.
@MainActor
enum AgentBrand {
    /// Desktop apps that carry a tool's logo although the registry launches the tool in a terminal.
    static let companionApps: [String: [String]] = [
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex"],
        "hermes": ["com.nousresearch.hermes.setup"],
        "grok": ["com.anysphere.sand"],
    ]
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func bundleIdentifiers(for tool: AgentTool) -> [String] { tool.bundleIdentifiers + (companionApps[tool.id] ?? []) }

    /// The app icon for a registry tool, or nil when no app with its logo is installed.
    static func icon(for tool: AgentTool) -> NSImage? {
        if let cached = cache[tool.id] { return cached }
        guard !missing.contains(tool.id) else { return nil }
        let url = bundleIdentifiers(for: tool).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first { !$0.path.contains("/.Trash/") }
        guard let url else { missing.insert(tool.id); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[tool.id] = image
        return image
    }

    /// An agent profile without a chosen icon shows its tool's app logo with the profile's color dot.
    static func defaultIcon(for profile: Profile) -> NSImage? {
        guard profile.kind == .agent, profile.dockIconStyle == nil, profile.iconFilename == nil, let tool = profile.agentTool else { return nil }
        return icon(for: tool)
    }
}
