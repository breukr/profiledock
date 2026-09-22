import AppKit
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case profiles = "Profiles", search = "Search Chats", insights = "Usage Insights"
    case general = "General", appearance = "Appearance", icons = "Profile Icons", access = "Context Access", updates = "Updates"
    case support = "About & Support"

    var id: String { rawValue }
    static let workspace: [Self] = [.profiles, .search, .insights]
    static let settings: [Self] = [.general, .appearance, .icons, .access, .updates]

    static func initial(arguments: [String]) -> Self {
        if arguments.contains("--search-chats") { return .search }
        if arguments.contains("--context-settings") { return .access }
        return arguments.contains("--settings") ? .general : .profiles
    }

    var symbol: String {
        switch self {
        case .profiles: return "person.crop.rectangle.stack"
        case .search: return "magnifyingglass"
        case .insights: return "chart.bar.xaxis"
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .icons: return "app.badge"
        case .access: return "lock.shield"
        case .updates: return "arrow.down.circle"
        case .support: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .profiles: return "Your accounts, ready when you are."
        case .search: return "Find earlier conversations across your profiles."
        case .insights: return "Understand your local AI activity."
        case .general: return "Choose how ProfileDock starts and where it appears."
        case .appearance: return "Make the profile strip feel at home on your Mac."
        case .icons: return "Give each profile a recognizable icon."
        case .access: return "Choose which profiles can share earlier conversations."
        case .updates: return "Keep ProfileDock and your ChatGPT apps up to date."
        case .support: return "An independent companion, made by Breukr."
        }
    }

    private var keywords: String {
        switch self {
        case .profiles: return "accounts open switch organize import restore"
        case .search: return "history conversations tasks find"
        case .insights: return "analytics tokens cost activity"
        case .general: return "startup login launch menu bar dock visibility"
        case .appearance: return "strip position size width sound volume notifications cues"
        case .icons: return "custom color colour image initials native experimental dock"
        case .access: return "permissions privacy sharing tagging mentions context"
        case .updates: return "versions software install download repair"
        case .support: return "help version about donate sponsorship github"
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let text = rawValue + " " + subtitle + " " + keywords
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

/// System colors keep the same hierarchy in light, dark and increased-contrast appearances.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }
}

struct SettingsGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            SettingsCard { configuration.content.padding(6) }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct SettingsNotice: View {
    let text: String
    var symbol = "info.circle"
    var isWarning = false
    var compact = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil
    private var tint: Color { isWarning ? .orange : .accentColor }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: compact ? 14 : 16))
                .foregroundStyle(tint).accessibilityHidden(true).padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(compact ? .system(size: 11) : .callout)
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                    .buttonStyle(.borderless).help("Dismiss message").accessibilityLabel("Dismiss message")
                    .foregroundStyle(.secondary)
            }
        }.padding(12)
            .background(tint.opacity(isWarning ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(isWarning ? 0.2 : 0.08), lineWidth: 0.5))
    }
}

struct ProfileMessageNotice: View {
    @ObservedObject var model: DockModel
    var compact = false
    var body: some View {
        if let message = model.message {
            SettingsNotice(text: message, symbol: "exclamationmark.triangle.fill", isWarning: true, compact: compact,
                           actionTitle: model.messageRecovery?.title, action: { model.retryMessage() }, dismiss: { model.message = nil })
        }
    }
}
