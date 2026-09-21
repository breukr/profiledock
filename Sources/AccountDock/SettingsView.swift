import AppKit
import SwiftUI
import DockCore

enum AppBrand {
    static let repository = URL(string: "https://github.com/breukr/profiledock")!
    static let sponsors = URL(string: "https://github.com/sponsors/breukr")!
    static let donation = URL(string: "https://github.com/sponsors/breukr?frequency=one-time")!
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case profiles = "Profiles", context = "Context tagging", insights = "Usage insights", updates = "Updates", appearance = "Appearance", support = "Support"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .profiles: return "person.crop.rectangle.stack"; case .context: return "text.bubble"; case .insights: return "chart.bar.xaxis"; case .updates: return "arrow.down.circle"; case .appearance: return "macwindow"; case .support: return "heart" }
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
    @State private var section: SettingsSection? = (CommandLine.arguments.contains("--context-settings") || Bundle.main.object(forInfoDictionaryKey: "ProfileDockContextPreview") as? Bool == true) ? .context : .profiles
    @State private var adding = false
    @State private var editing: Profile?
    @State private var contextProfileID: String?
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
                        case .context: ContextSettingsView(model: model, initialCallerID: contextProfileID)
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
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowUpdates)) { _ in section = .updates }
        .sheet(isPresented: $adding) { AddProfileSheet(model: model) }
        .sheet(item: $editing) { profile in
            ProfileSettingsSheet(model: model, profileID: profile.id) { editing = nil; contextProfileID = profile.id; section = .context }
        }
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
                        Button { editing = profile } label: { ProfileBadge(model: model, profile: profile, size: 44) }
                            .buttonStyle(.plain).help("Profile settings").accessibilityLabel("Settings for \(profile.name)")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name).font(.headline)
                            Text("\(model.state(profile)) · \(profile.applicationPath == nil ? "Shared installation" : "Separate installation")" + (index < 9 ? " · ⌥⌘\(index + 1)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if profile.dockApplicationPath != nil {
                                Text(model.nativeDockNeedsRebuild(profile) ? "Native Dock icon · updates on next launch" : "Native Dock icon · experimental")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Open") { model.select(profile) }
                        Menu {
                            Section {
                                Button("Profile settings…", systemImage: "slider.horizontal.3") { editing = profile }
                                Button("Context tagging…", systemImage: "at") { contextProfileID = profile.id; section = .context }
                            }
                            Section("Window") {
                                Button("Open profile", systemImage: "arrow.up.forward.app") { model.select(profile) }
                                Button("Close profile", systemImage: "xmark.circle") { model.requestQuit(profile) }.disabled(model.running[profile.id]?.isEmpty != false)
                                if let url = model.nativeDockURL(for: profile) ?? model.applicationURL(for: profile) {
                                    Button("Show app in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                if let path = profile.launcherPath {
                                    Button("Show profile shortcut", systemImage: "arrow.turn.up.right") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                } else {
                                    Button("Create profile shortcut", systemImage: "plus.app") {
                                        copying = true
                                        Task { defer { copying = false }; do { try await model.createFinderLauncher(for: profile) } catch { model.message = error.localizedDescription } }
                                    }
                                }
                            }
                            Section("Organize") {
                                Button("Move up", systemImage: "arrow.up") { model.move(profile.id, by: -1) }.disabled(index == 0)
                                Button("Move down", systemImage: "arrow.down") { model.move(profile.id, by: 1) }.disabled(index + 1 == model.preferences.profiles.count)
                            }
                            Section {
                                Button("Remove profile…", systemImage: "trash", role: .destructive) { trashData = false; removing = profile }
                                    .disabled(model.running[profile.id]?.isEmpty == false)
                            }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(profile.name)")
                    }.padding(10)
                }
            }
            if copying || !model.nativeDockOperations.isEmpty { ProgressView("Preparing and verifying the app copy…").controlSize(.small) }
            Button("Import or restore profiles") { model.restoreImportedProfiles() }.buttonStyle(.link)
            Text("New profiles start empty. A separate app copy can update independently; a shared app uses less disk space.").font(.caption).foregroundStyle(.secondary)
        }.disabled(updates.busy || copying || !model.nativeDockOperations.isEmpty)
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
            Text("Two apps, two update controls.").font(.headline)
            Text("ProfileDock updates add features to this companion. ChatGPT / Codex updates install OpenAI's desktop app and may restart selected profiles.").foregroundStyle(.secondary)
            profiledockUpdateCard
            Divider()
            Label("ChatGPT / Codex", systemImage: "sparkles").font(.title3.weight(.semibold))
            Text("Update the OpenAI app used by your profiles. Choose the groups you can restart.").foregroundStyle(.secondary)
            Text("Checks when you open this panel. Updates install only after you confirm.").font(.caption).foregroundStyle(.secondary)
            if model.preferences.profiles.contains(where: { $0.dockApplicationPath != nil }) {
                Text("Enabled native Dock copies are rebuilt automatically with each update, keeping their profile names, colors and data. Updates made outside ProfileDock are applied to the Dock copy on its next launch.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
                            Text(group.application.lastPathComponent + " · " + AppUpdates.installedVersion(at: group.application) + (updates.needsUpdate(group) ? " · Update available" : ""))
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
        }.task { await updates.check() }
    }

    private var profiledockUpdateCard: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("ProfileDock", systemImage: "square.grid.2x2.fill").font(.title3.weight(.semibold))
                    Text("Running version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local")").font(.callout)
                    Text("Includes profile tagging and optional native Dock icons.").font(.caption).foregroundStyle(.secondary)
                    Text("ProfileDock checks daily while it is running. You choose when to download and install; only ProfileDock restarts.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Automatically check for ProfileDock updates", isOn: Binding(get: { selfUpdates.automatic }, set: { selfUpdates.setAutomatic($0) })).disabled(!selfUpdates.enabled)
                    Button("Check ProfileDock for updates…") { selfUpdates.check() }.disabled(!selfUpdates.canCheck || updates.busy)
                    if let last = selfUpdates.lastChecked { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Link("View ProfileDock releases", destination: AppBrand.repository.appendingPathComponent("releases/latest"))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
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
                    Toggle("Show ProfileDock in the menu bar", isOn: Binding(get: { model.preferences.showMenuBarIcon != false }, set: { model.preferences.showMenuBarIcon = $0; model.save() }))
                    Text("When the Dock option is off, its icon appears only while Settings is open so macOS can show the top-left ProfileDock menu. The menu-bar icon is independent. You can always reopen Settings by opening ProfileDock from Finder or Spotlight.").font(.caption).foregroundStyle(.secondary)
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
                Link("Donate once", destination: AppBrand.donation).buttonStyle(.borderedProminent)
                Link("Sponsor monthly", destination: AppBrand.sponsors).buttonStyle(.bordered)
            }
            Text("Choose your amount on GitHub Sponsors. Contributions are optional; every feature stays free.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Link("Star on GitHub", destination: AppBrand.repository)
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
            Text("A profile is a separate sign-in, conversation history and settings. Give it a name, then sign in when it opens.").foregroundStyle(.secondary)
            TextField("For example, Personal or Work", text: $name).textFieldStyle(.roundedBorder)
            Picker("Application", selection: $separate) {
                Text("Shared installation · recommended").tag(false)
                Text("Separate installation").tag(true)
            }.pickerStyle(.radioGroup)
            Text(separate ? "Copies the ChatGPT app so you can update this profile independently. Uses more disk space. It does not create another account or subscription." : "Uses your existing ChatGPT installation. Your sign-in, chats and settings are still separate; only the app files and update schedule are shared.")
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
        }.padding(28).frame(width: 530).disabled(creating).interactiveDismissDisabled(creating)
    }
}
