import AppKit
import SwiftUI
import DockCore

enum AppBrand {
    static let repository = URL(string: "https://github.com/breukr/profiledock")!
    static let donation: URL? = URL(string: "https://github.com/breukr/profiledock#support")
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case profiles = "Profiles", insights = "Usage insights", updates = "ChatGPT updates", appearance = "Appearance", support = "Support"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .profiles: return "person.crop.rectangle.stack"; case .insights: return "chart.bar.xaxis"; case .updates: return "arrow.down.circle"; case .appearance: return "macwindow"; case .support: return "heart" }
    }
}

struct SettingsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var loginItem: LoginItemModel
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var updates: AppUpdates
    @ObservedObject var selfUpdates: ProfileDockUpdates
    @ObservedObject var insights: InsightsStore
    let cues: ActivityCues
    let chooseImage: (Profile) -> Void
    @State private var section: SettingsSection? = .profiles
    @State private var adding = false
    @State private var removing: Profile?
    @State private var trashData = false
    @State private var copying = false
    @State private var confirmingUpdate = false

    private var groups: [AppUpdateGroup] { AppUpdateGroup.make(profiles: model.preferences.profiles, defaultApplication: model.defaultApplication) }
    private var selectedGroups: [AppUpdateGroup] { groups.filter { updates.selected.contains($0.id) && updates.needsUpdate($0) } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) { BrandMark(size: 17); Text("ProfileDock").font(.system(size: 17, weight: .semibold)) }
                    Text("by Breukr").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
                List(SettingsSection.allCases, selection: $section) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                        .padding(.vertical, 5)
                }.listStyle(.sidebar)
                Text("Your profiles, one place.").font(.caption).foregroundStyle(.secondary).padding(20)
            }.frame(minWidth: 170, idealWidth: 190, maxWidth: 220)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text((section ?? .profiles).rawValue).font(.title2.weight(.semibold))
                    Spacer()
                    if section == .profiles {
                        Button { adding = true } label: { Label("Add profile", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).disabled(copying || updates.busy)
                    }
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch section ?? .profiles {
                        case .profiles: profiles
                        case .insights: insightsSettings
                        case .updates: updateSettings
                        case .appearance: appearance
                        case .support: support
                        }
                        if let message = model.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) { AddProfileSheet(model: model) }
        .sheet(item: $removing) { profile in
            VStack(alignment: .leading, spacing: 18) {
                Text("Remove \(profile.name)?").font(.title2.weight(.semibold))
                Text("The profile will disappear from ProfileDock. Its chats and sign-in data stay on this Mac unless you choose to move them to the Trash.")
                if profile.id.hasPrefix("profile-") { Toggle("Also move this profile's data and managed app copy to the Trash", isOn: $trashData) }
                HStack { Spacer(); Button("Cancel") { removing = nil }.keyboardShortcut(.cancelAction)
                    Button("Remove", role: .destructive) {
                        do { try model.removeProfile(profile, trashData: trashData); removing = nil }
                        catch { model.message = error.localizedDescription; removing = nil }
                    }
                }
            }.padding(28).frame(width: 460)
        }
        .alert("Update the selected ChatGPT apps?", isPresented: $confirmingUpdate) {
            Button("Cancel", role: .cancel) {}
            Button("Download & update") { updates.install(groups: selectedGroups, model: model, activity: activity) }
        } message: {
            Text("\(selectedGroups.flatMap(\.profiles).map(\.name).joined(separator: ", ")) will close after the download and reopen when the update finishes. Profiles sharing an app update together. Active tasks must finish first.")
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep your accounts separate and switch without signing out.").foregroundStyle(.secondary)
            if model.preferences.profiles.isEmpty {
                ContentUnavailableView("Make room for another account", systemImage: "person.crop.circle.badge.plus", description: Text("Add a profile, then sign in to ChatGPT in its new window."))
            }
            ForEach(Array(model.preferences.profiles.enumerated()), id: \.element.id) { index, profile in
                GroupBox {
                    HStack(spacing: 14) {
                        Button { chooseImage(profile) } label: { ProfileBadge(model: model, profile: profile, size: 40) }
                            .buttonStyle(.plain).help("Change picture").accessibilityLabel("Change picture for \(profile.name)")
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("Profile name", text: Binding(get: { profile.name }, set: { var edited = profile; edited.name = $0; model.update(edited) }))
                                .font(.headline).textFieldStyle(.plain).accessibilityLabel("Name for \(profile.name)")
                            Text("\(model.state(profile)) · \(profile.applicationPath == nil ? "Shared app" : "Separate app")" + (index < 9 ? " · ⌥⌘\(index + 1)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Open") { model.select(profile) }
                        Menu {
                            Button("Choose picture…") { chooseImage(profile) }
                            if profile.iconFilename != nil { Button("Remove picture") { model.removeImage(for: profile) } }
                            Menu("Color") {
                                ForEach(["377CF6", "009B87", "955CE5", "D77620", "CA528B", "D85252"], id: \.self) { hex in
                                    Button { var changed = profile; changed.color = hex; model.update(changed) } label: { Label(colorName(hex), systemImage: profile.color == hex ? "checkmark.circle.fill" : "circle") }
                                }
                            }
                            Divider()
                            Button("Move up") { model.move(profile.id, by: -1) }.disabled(index == 0)
                            Button("Move down") { model.move(profile.id, by: 1) }.disabled(index + 1 == model.preferences.profiles.count)
                            Divider()
                            Button("Create separate app copy…") {
                                copying = true
                                Task { defer { copying = false }; do { try await model.makeSeparateCopy(for: profile) } catch { model.message = error.localizedDescription } }
                            }.disabled(profile.applicationPath != nil || model.running[profile.id]?.isEmpty == false)
                            if profile.applicationPath != nil {
                                Button("Use shared app & move copy to Trash") {
                                    do { try model.useSharedAppAndTrashCopy(profile) } catch { model.message = error.localizedDescription }
                                }.disabled(model.running[profile.id]?.isEmpty == false)
                            }
                            if let url = model.applicationURL(for: profile) { Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                            if let path = profile.launcherPath { Button("Show profile launcher in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                            else {
                                Button("Create Finder launcher") {
                                    copying = true
                                    Task { defer { copying = false }; do { try await model.createFinderLauncher(for: profile) } catch { model.message = error.localizedDescription } }
                                }
                            }
                            Button("Close profile") { model.requestQuit(profile) }.disabled(model.running[profile.id]?.isEmpty != false)
                            Divider()
                            Button("Remove profile…", role: .destructive) { trashData = false; removing = profile }
                                .disabled(model.running[profile.id]?.isEmpty == false)
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(profile.name)")
                    }.padding(10)
                }
            }
            if copying { ProgressView("Creating and verifying the app copy…").controlSize(.small) }
            Button("Import or restore profiles") { model.restoreImportedProfiles() }.buttonStyle(.link)
            Text("New profiles start empty. A separate app copy can update independently; a shared app uses less disk space.").font(.caption).foregroundStyle(.secondary)
        }.disabled(updates.busy || copying)
    }

    private var insightsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A clearer picture of your local AI activity.").foregroundStyle(.secondary)
            InsightsPanel(model: model, store: insights)
            Picker("In the profile strip", selection: Binding(get: { model.preferences.insightsExpansion ?? .button }, set: { model.preferences.insightsExpansion = $0; model.save() })) {
                ForEach(InsightsExpansion.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Text("Choose how the Usage insights drawer opens inside your expanded profile strip. Hover mode stays open until you leave the strip.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Update your ChatGPT app copies together, or choose the ones you can restart.").foregroundStyle(.secondary)
            Text("Checks when you open this panel. Updates install only after you confirm.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(updates.checking ? "Checking ChatGPT…" : "Check ChatGPT updates") { Task { await updates.check() } }.disabled(updates.checking || updates.busy)
                Spacer()
                Button("Select all") { updates.selected = Set(groups.filter { updates.needsUpdate($0) }.map(\.id)) }.disabled(updates.busy)
            }
            ForEach(groups) { group in
                GroupBox {
                    Toggle(isOn: Binding(get: { updates.selected.contains(group.id) }, set: { if $0 { updates.selected.insert(group.id) } else { updates.selected.remove(group.id) } })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.profiles.map(\.name).joined(separator: ", ")).font(.headline)
                            Text(group.application.lastPathComponent + " · " + (updates.needsUpdate(group) ? "Update available" : "Build \(AppUpdates.installedBuild(at: group.application).map(String.init) ?? "unknown")"))
                                .font(.caption).foregroundStyle(.secondary)
                            if group.profiles.count > 1 { Text("These profiles share one app and restart together.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.toggleStyle(.checkbox).padding(8)
                }.disabled(!updates.needsUpdate(group) || updates.busy)
            }
            if updates.busy {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = updates.progress, !updates.verifying, !updates.cancelling {
                        ProgressView(value: progress.fraction ?? 0).accessibilityLabel("ChatGPT download progress")
                        HStack {
                            Text(progress.label).monospacedDigit()
                            Spacer()
                            if let fraction = progress.fraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                    if updates.canCancel {
                        Button("Cancel download") { updates.cancel() }
                    } else if !updates.cancelling {
                        Text("Installation is in progress. Keep ProfileDock open until it finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let status = updates.status { Text(status).font(.callout).foregroundStyle(.secondary) }
            if let error = updates.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Button("Update selected ChatGPT apps") { confirmingUpdate = true }.buttonStyle(.borderedProminent).disabled(selectedGroups.isEmpty || updates.busy || selfUpdates.sessionInProgress)
            Text("Only selected app groups close. Your profiles, sign-ins, and chats stay in place. ChatGPT's own updater remains available.").font(.caption).foregroundStyle(.secondary)
            Divider()
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ProfileDock · Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")").font(.headline)
                    Text("ProfileDock checks daily while it is running. You choose when to download and install; only ProfileDock restarts.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Automatically check for ProfileDock updates", isOn: Binding(get: { selfUpdates.automatic }, set: { selfUpdates.setAutomatic($0) })).disabled(!selfUpdates.enabled)
                    Button("Check ProfileDock for updates…") { selfUpdates.check() }.disabled(!selfUpdates.canCheck || updates.busy)
                    if let last = selfUpdates.lastChecked { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Link("View ProfileDock releases", destination: AppBrand.repository.appendingPathComponent("releases/latest"))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }.task { await updates.check() }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Open ProfileDock at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                    if loginItem.requiresApproval {
                        Text("Allow ProfileDock in System Settings → Login Items.").font(.caption)
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                    }
                    if let error = loginItem.error { Text(error).foregroundStyle(.orange) }
                    Divider()
                    Picker("Placement", selection: Binding(get: { model.placement }, set: { model.preferences.placement = $0; model.save() })) {
                        ForEach(DockPlacement.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Top center follows the notch or menu bar. Free position lets you drag the grip anywhere within each display; positions are remembered separately.").font(.caption).foregroundStyle(.secondary)
                    if model.placement == .free {
                        Button("Reset strip positions") { model.preferences.floatingPositions = nil; model.preferences.placement = .free; model.save() }
                    }
                    AppIconAppearancePicker(model: model)
                    Divider()
                    Toggle("Show ProfileDock in the macOS Dock", isOn: Binding(get: { model.preferences.showDockIcon == true }, set: { model.preferences.showDockIcon = $0; model.save() }))
                    Text("Click the Dock icon to open settings. Hover expansion works on ProfileDock's floating launchers.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker("Tile size", selection: Binding(get: { model.preferences.scale }, set: { model.preferences.scale = $0; model.save() })) {
                        Text("Small").tag(0.85); Text("Default").tag(1.0); Text("Large").tag(1.3)
                    }.pickerStyle(.segmented)
                    widthControl("Compact strip width", value: Binding(get: { model.preferences.compactWidth }, set: { model.preferences.compactWidth = $0; model.save() }), range: 160...480, automatic: WidgetSizing.compact(count: model.preferences.profiles.count, preferred: nil))
                    widthControl("Expanded panel width", value: Binding(get: { model.preferences.expandedWidth }, set: { model.preferences.expandedWidth = $0; model.save() }), range: 320...1400, automatic: WidgetSizing.expanded(count: model.preferences.profiles.count, scale: model.preferences.scale, preferred: nil, insights: false))
                    Text("Automatic widths adapt to your account count. Tiles adapt into rows, with page controls for additional accounts. Insights need at least 520 pt. The compact width applies to floating strips and screens without a notch; the physical notch keeps its own size.").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            Label(model.placement.instruction, systemImage: "cursorarrow.motionlines")
            GroupBox("Activity & sound") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Blue: working. Orange: needs you. Green: idle. Red: unread results. Gray: closed or unknown.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Show completion and input cues", isOn: Binding(get: { model.preferences.activityCues != false }, set: { model.preferences.activityCues = $0; model.save(); if !$0 { cues.dismiss() } }))
                    Text("One cue grows from the strip: status on the left, environment on the right. Reduce Motion uses a simple fade.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Play quiet activity sounds", isOn: Binding(get: { model.preferences.activitySounds == true }, set: { model.preferences.activitySounds = $0; model.save() }))
                    if model.preferences.activitySounds == true {
                        HStack {
                            Image(systemName: "speaker.wave.1")
                            Slider(value: Binding(get: { model.preferences.activitySoundVolume ?? 0.18 }, set: { model.preferences.activitySoundVolume = $0; model.save() }), in: 0...0.5).accessibilityLabel("Activity sound volume")
                            Image(systemName: "speaker.wave.2")
                        }
                    }
                    HStack {
                        Button("Preview completion") { cues.present(.finished, model: model, preview: true) }
                        Button("Preview input request") { cues.present(.needsInput, model: model, preview: true) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Activity covers local Work and Codex tasks. Ordinary chats and tasks running on another computer are outside this view.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func widthControl(_ title: String, value: Binding<Double?>, range: ClosedRange<Double>, automatic: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Toggle("Automatic", isOn: Binding(get: { value.wrappedValue == nil }, set: { value.wrappedValue = $0 ? nil : automatic }))
                    .toggleStyle(.checkbox).controlSize(.small)
            }
            if let current = value.wrappedValue {
                HStack {
                    Slider(value: Binding(get: { value.wrappedValue ?? automatic }, set: { value.wrappedValue = $0 }), in: range, step: 10)
                        .accessibilityLabel(title)
                    Text("\(Int(current)) pt").font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandMark(size: 44).foregroundStyle(.blue)
            Text("A little less switching.\nA little more flow.").font(.system(size: 26, weight: .semibold))
            Text("Free, open source, and made by Breukr.").foregroundStyle(.secondary)
            HStack {
                Link("Star on GitHub", destination: AppBrand.repository).buttonStyle(.borderedProminent)
                if let donation = AppBrand.donation { Link("Support development", destination: donation).buttonStyle(.bordered) }
            }
            Divider()
            Link("Installation & guide", destination: AppBrand.repository)
            Link("Report an issue", destination: AppBrand.repository.appendingPathComponent("issues/new/choose"))
            Link("Privacy & security", destination: AppBrand.repository.appendingPathComponent("blob/main/PRIVACY.md"))
            Text("No ProfileDock account. No analytics. Profile data stays on your Mac; usage requests go directly to OpenAI.").font(.caption).foregroundStyle(.secondary)
            Text("An independent companion for ChatGPT and Codex. Not affiliated with OpenAI.").font(.caption).foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")").font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private func colorName(_ hex: String) -> String { ["377CF6": "Blue", "009B87": "Teal", "955CE5": "Purple", "D77620": "Orange", "CA528B": "Pink", "D85252": "Red"][hex] ?? hex }
}

private struct AddProfileSheet: View {
    @ObservedObject var model: DockModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var separate = false
    @State private var source: URL?
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a profile").font(.title2.weight(.semibold))
            Text("Give this account a name. You'll sign in when you open it.").foregroundStyle(.secondary)
            TextField("For example, Personal or Work", text: $name).textFieldStyle(.roundedBorder)
            Picker("Application", selection: $separate) {
                Text("Use the shared app").tag(false)
                Text("Create a separate app copy").tag(true)
            }.pickerStyle(.radioGroup)
            Text(separate ? "Uses more disk space. This profile can update without restarting your other app copies." : "Uses your installed ChatGPT app. Profiles that share it update together.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text((source ?? model.defaultApplication)?.lastPathComponent ?? "ChatGPT is not installed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose app…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
                    panel.begin { response in if response == .OK { source = panel.url } }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            if creating { ProgressView("Creating your profile…").controlSize(.small) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create profile") {
                    creating = true; error = nil
                    Task {
                        do { try await model.createProfile(name: name, separateApp: separate, source: source); dismiss() }
                        catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }.buttonStyle(.borderedProminent).disabled(ProfileLaunch.newProfile(name: name) == nil)
            }
        }.padding(28).frame(width: 470).disabled(creating).interactiveDismissDisabled(creating)
    }
}
