import AppKit
import SwiftUI
import DockCore

@MainActor
final class AppIconController {
    private var mode: AppIconAppearance = .auto
    private var appearanceObserver: NSKeyValueObservation?
    private var colorObserver: NSObjectProtocol?
    func update(_ mode: AppIconAppearance) {
        self.mode = mode
        if appearanceObserver == nil {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.apply() }
            }
            colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        apply()
    }
    private func apply() {
        // nil restores the bundled layered icon, allowing macOS to choose its rendition.
        NSApp.applicationIconImage = mode == .auto ? nil : AppIconImages.image(mode: mode, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    func shutdown() {
        appearanceObserver = nil
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
    }
}

enum AppIconImages {
    static func image(mode: AppIconAppearance, dark: Bool) -> NSImage {
        let name: String
        switch mode {
        case .auto: name = dark ? "dark" : "light"
        case .light: name = "light"
        case .dark: name = "dark"
        case .tinted: name = dark ? "tinted-dark" : "tinted-light"
        case .clear: name = dark ? "clear-dark" : "clear-light"
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "IconPreviews"), let image = NSImage(contentsOf: url) { return image }
        // Source/test builds without bundled resources still show the real monochrome mark.
        return BrandArtwork.template(size: 128)
    }
}

struct AppIconAppearancePicker: View {
    @ObservedObject var model: DockModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App icon").font(.headline)
            HStack(spacing: 8) {
                ForEach(AppIconAppearance.allCases, id: \.self) { mode in
                    Button {
                        model.preferences.appIconAppearance = mode; model.save()
                    } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: AppIconImages.image(mode: mode, dark: colorScheme == .dark)).resizable().scaledToFit().frame(width: 42, height: 42)
                            Text(mode.label).font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background((model.preferences.appIconAppearance ?? .auto) == mode ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder((model.preferences.appIconAppearance ?? .auto) == mode ? Color.accentColor : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("\(mode.label) app icon")
                        .accessibilityAddTraits((model.preferences.appIconAppearance ?? .auto) == mode ? .isSelected : [])
                }
            }
            Text("Auto follows the macOS icon appearance, including tint and clear styles. The other choices override ProfileDock's running Dock icon; Finder continues to follow macOS.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
