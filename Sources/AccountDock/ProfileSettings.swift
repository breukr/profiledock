import AppKit
import SwiftUI
import DockCore

enum NativeDockDisclosure {
    static let text = "ProfileDock creates a local ChatGPT copy with this profile's icon. It replaces OpenAI's signature, removes vendor-only permissions and disables library validation, so some macOS protections and integrations differ. You may need to sign in again. The copy’s own updater is disabled; ProfileDock rebuilds it from the updated original. Your original app and profile data are kept. You can disable this at any time."
}

struct ProfileSettingsSheet: View {
    @ObservedObject var model: DockModel
    let profileID: String
    let tagging: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hex = ""
    @State private var busy = false
    @State private var consent = false
    @State private var error: String?
    private var profile: Profile? { model.preferences.profiles.first { $0.id == profileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile settings").font(.title2.weight(.semibold))
                    Text("Identity, app installation and context access.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            ScrollView {
                if let profile {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 18) {
                            Image(nsImage: artwork(profile)).resizable().frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Profile name").font(.caption).foregroundStyle(.secondary)
                                TextField("Name", text: Binding(get: { profile.name }, set: { value in edit { $0.name = value } })).textFieldStyle(.roundedBorder)
                                Text("Your sign-in and conversation history belong to this profile.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Dock icon", systemImage: "app.badge").font(.headline)
                                HStack(spacing: 8) {
                                    ForEach(DockIconStyle.allCases, id: \.self) { style in
                                        Button { edit { $0.dockIconStyle = style } } label: {
                                            VStack(spacing: 5) {
                                                Image(nsImage: artwork(profile, style: style)).resizable().frame(width: 52, height: 52)
                                                Text(style.label).font(.caption)
                                            }.frame(maxWidth: .infinity).padding(.vertical, 9)
                                                .background((profile.dockIconStyle ?? .initials) == style ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                                .overlay(RoundedRectangle(cornerRadius: 10).stroke((profile.dockIconStyle ?? .initials) == style ? Color.accentColor : Color.secondary.opacity(0.15)))
                                        }.buttonStyle(.plain).accessibilityLabel("\(style.label) Dock icon").accessibilityAddTraits((profile.dockIconStyle ?? .initials) == style ? .isSelected : [])
                                    }
                                }
                                HStack(spacing: 12) {
                                    ColorPicker("Profile color", selection: Binding(get: { Color(nsColor: NSColor(hex: profile.color)) }, set: { color in
                                        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                                        hex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                                        edit { $0.color = hex }
                                    }), supportsOpacity: false)
                                    Text("#").foregroundStyle(.secondary)
                                    TextField("377CF6", text: $hex).font(.body.monospaced()).textFieldStyle(.roundedBorder).frame(width: 95).accessibilityLabel("Profile color hex code")
                                        .onChange(of: hex) { _, value in
                                            let candidate = value.replacingOccurrences(of: "#", with: "").uppercased()
                                            if candidate.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil { edit { $0.color = candidate } }
                                        }
                                }
                                if (profile.dockIconStyle ?? .initials) == .initials {
                                    TextField("Letters (leave empty for initials)", text: Binding(get: { profile.dockIconText ?? "" }, set: { value in edit { $0.dockIconText = String(value.prefix(3)) } }))
                                        .textFieldStyle(.roundedBorder).accessibilityLabel("Dock icon letters, up to three")
                                }
                                if profile.dockIconStyle == .image {
                                    HStack {
                                        Button(profile.iconFilename == nil ? "Choose image…" : "Replace image…") { model.chooseImage(for: profile, window: NSApp.keyWindow) }
                                        if profile.iconFilename != nil { Button("Remove image") { model.removeImage(for: profile) } }
                                    }
                                }
                                Text(profile.dockApplicationPath == nil ? "Preview only. Enable Native macOS Dock icon below to apply this look to the running app." : "Appearance changes apply when this profile next opens from ProfileDock.").font(.caption).foregroundStyle(.secondary)
                            }.padding(10)
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle(isOn: Binding(get: { profile.dockApplicationPath != nil }, set: { enabled in if enabled { consent = true } else { native(false) } })) {
                                    HStack { Text("Native macOS Dock icon").font(.headline); Text("Experimental").font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3).background(.orange.opacity(0.15), in: Capsule()) }
                                }.toggleStyle(.switch).accessibilityLabel("Native macOS Dock icon, experimental").disabled(model.running[profileID]?.isEmpty == false || model.opening.contains(profileID))
                                Text("Give this profile its own running Dock icon and name. ProfileDock keeps the copy up to date automatically.").font(.callout).foregroundStyle(.secondary)
                                DisclosureGroup("Why experimental?") { Text(NativeDockDisclosure.text).font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
                                if profile.dockApplicationPath != nil {
                                    HStack {
                                        if let app = model.nativeDockURL(for: profile) { Button("Show Dock app") { NSWorkspace.shared.activateFileViewerSelecting([app]) } }
                                        Button("Repair copy") { native(true) }.disabled(model.running[profileID]?.isEmpty == false)
                                    }
                                    Text("Drag the app from Finder to the Dock to pin it.").font(.caption).foregroundStyle(.secondary)
                                }
                                if model.running[profileID]?.isEmpty == false { Text("Close this profile before changing its app or Dock mode.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(10)
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("ChatGPT installation", systemImage: "shippingbox").font(.headline)
                                Text(profile.applicationPath == nil ? "Shared installation" : "Separate installation").font(.subheadline.weight(.medium))
                                Text(profile.applicationPath == nil ? (profile.dockApplicationPath == nil ? "This profile uses the same installed ChatGPT app as your other shared profiles. Each profile still has its own sign-in, chats and settings. The app updates once for the group." : "This profile’s Dock app is rebuilt from the shared, signed ChatGPT installation. Profiles using that source update together. Sign-ins, chats and settings stay separate.") : "This profile has its own ChatGPT installation, so you can update or restart it separately. Its account data is still separate. A copy uses more disk space; it does not add another account or subscription.").font(.callout).foregroundStyle(.secondary)
                                Button(profile.applicationPath == nil ? "Create a separate installation…" : "Use shared installation & trash managed copy") {
                                    perform {
                                        if profile.applicationPath == nil { try await model.makeSeparateCopy(for: profile) }
                                        else { try model.useSharedAppAndTrashCopy(profile) }
                                    }
                                }.disabled(model.running[profileID]?.isEmpty == false || model.opening.contains(profileID))
                                if let app = model.applicationURL(for: profile) { Text(app.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled) }
                            }.padding(10)
                        }
                        GroupBox {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label("Context tagging", systemImage: "at").font(.headline)
                                    Text("Choose which other profiles \(profile.name) can mention for earlier conversations.").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Manage access…") { tagging() }
                            }.padding(10)
                        }
                        if busy { ProgressView("Preparing your profile…") }
                        if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    }.padding(24)
                }
            }
        }.frame(width: 630, height: 720).disabled(busy).interactiveDismissDisabled(busy)
            .onAppear { hex = profile?.color ?? "377CF6" }
            .alert("Enable experimental native Dock icon?", isPresented: $consent) {
                Button("Cancel", role: .cancel) {}
                Button("Enable") { native(true) }
            } message: { Text(NativeDockDisclosure.text) }
    }

    private func edit(_ change: (inout Profile) -> Void) {
        guard var profile else { return }; change(&profile); model.update(profile)
    }
    private func artwork(_ profile: Profile, style: DockIconStyle? = nil) -> NSImage {
        var value = profile; if let style { value.dockIconStyle = style }
        return NativeProfileArtwork.preview(profile: value, image: model.image(for: value), vendor: model.applicationURL(for: value).map { NSWorkspace.shared.icon(forFile: $0.path) })
    }
    private func native(_ enabled: Bool) {
        guard let profile else { return }
        perform { try await model.setNativeDockIcon(for: profile, enabled: enabled) }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
}
