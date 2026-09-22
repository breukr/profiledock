import AppKit
import SwiftUI
import DockCore

enum AppBrand {
    static let repository = URL(string: "https://github.com/breukr/profiledock")!
    static let sponsors = URL(string: "https://github.com/sponsors/breukr")!
    static let donation = URL(string: "https://github.com/sponsors/breukr?frequency=one-time")!
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
    @State private var section: SettingsDestination?
    @State private var navigationQuery = ""
    @State private var adding = false
    @State private var editing: Profile?
    @State private var removing: Profile?
    @State private var trashData = false
    @State private var copying = false
    @State private var confirmingUpdate = false

    init(model: DockModel, loginItem: LoginItemModel, activity: ActivityMonitor, updates: AppUpdates,
         selfUpdates: ProfileDockUpdates, insights: InsightsStore, cues: ActivityCues,
         chooseImage: @escaping (Profile) -> Void,
         destination: SettingsDestination = .initial(arguments: CommandLine.arguments)) {
        self.model = model
        self.loginItem = loginItem
        self.activity = activity
        self.updates = updates
        self.selfUpdates = selfUpdates
        self.insights = insights
        self.cues = cues
        self.chooseImage = chooseImage
        _section = State(initialValue: destination)
    }

    private var groups: [AppUpdateGroup] { AppUpdateGroup.make(profiles: model.preferences.profiles, defaultApplication: model.defaultApplication) }
    private var selectedGroups: [AppUpdateGroup] { groups.filter { updates.selected.contains($0.id) && updates.needsUpdate($0) } }

    var body: some View {
        HSplitView {
            sidebar
            detail

        }
        .groupBoxStyle(SettingsGroupBoxStyle())
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowGeneralSettings)) { _ in navigate(.general) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowUpdates)) { _ in navigate(.updates) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowProfiles)) { _ in navigate(.profiles) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowSearch)) { _ in navigate(.search) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowSupport)) { _ in navigate(.support) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockShowAbout)) { _ in navigate(.about) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDockAddProfile)) { _ in navigate(.profiles); adding = true }
        .sheet(isPresented: $adding) { AddProfileSheet(model: model) }
        .sheet(item: $editing) { profile in
            ProfileSettingsSheet(model: model, profileID: profile.id) { editing = nil; manageContext(for: profile.id) }
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

    private let pageWidth: CGFloat = 760
    private var isEmptyPage: Bool {
        model.preferences.profiles.isEmpty && [.profiles, .search, .insights, .icons, .access].contains(destination)
    }
    private func columnWidth(_ available: CGFloat) -> CGFloat { max(0, min(pageWidth, available - 48)) }

    private var detail: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                pageHeader.frame(width: columnWidth(geometry.size.width))
                    .padding(.vertical, 20).frame(width: geometry.size.width)
                Divider()
                GeometryReader { pane in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if isEmptyPage { emptyState }
                            else { pageContent }
                        }
                        .frame(width: columnWidth(pane.size.width), alignment: .leading)
                        .padding(.vertical, 24)
                        .frame(width: pane.size.width)
                        .frame(minHeight: pane.size.height, alignment: isEmptyPage ? .center : .top)
                    }.id(destination)
                }
                if model.message != nil {
                    ProfileMessageNotice(model: model)
                        .frame(width: columnWidth(geometry.size.width)).padding(.vertical, 12)
                }
            }
        }.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(destination.rawValue).font(.system(size: 20, weight: .semibold))
                Text(destination.subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if destination == .profiles, !isEmptyPage {
                Button { adding = true } label: { Label("Add Profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(copying || updates.busy)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch destination {
        case .profiles: profiles
        case .search: ContextSettingsView(model: model, mode: .search) { manageContext() }
        case .insights: insightsSettings
        case .updates: updateSettings
        case .general: generalSettings
        case .appearance: appearance
        case .icons: profileIconSettings
        case .access: ContextSettingsView(model: model, mode: .access)
        case .support: support
        case .about: about
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: destination == .profiles ? "person.crop.circle.badge.plus" : destination.symbol)
                .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Add your first profile").font(.title3.weight(.semibold))
                Text("Keep your accounts in one place, with a separate sign-in for each.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add Profile") { adding = true }.buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
            Button("Import or Restore Profiles…") { model.restoreImportedProfiles() }.buttonStyle(.borderless)
        }
        .frame(maxWidth: 360).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var destination: SettingsDestination { section ?? .profiles }

    private func navigate(_ destination: SettingsDestination) {
        navigationQuery = ""
        section = destination
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 21)
                Text("ProfileDock").font(.system(size: 15, weight: .semibold))
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a setting", text: $navigationQuery).textFieldStyle(.plain)
                    .accessibilityLabel("Find a setting")
                    .onSubmit { if let match = SettingsDestination.allCases.first(where: { $0.matches(navigationQuery) }) { navigate(match) } }
                if !navigationQuery.isEmpty {
                    Button { navigationQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear settings search")
                }
            }.font(.system(size: 12)).padding(7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12).padding(.bottom, 10)
            List(selection: $section) {
                sidebarGroup("Workspace", items: SettingsDestination.workspace)
                sidebarGroup("Settings", items: SettingsDestination.settings)
                sidebarGroup("", items: [.support, .about])
                if !SettingsDestination.allCases.contains(where: { $0.matches(navigationQuery) }) {
                    Text("No matching settings").font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.sidebar).environment(\.defaultMinListRowHeight, 26)
            Divider().padding(.horizontal, 16)
            Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"))
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(minWidth: 190, idealWidth: 210, maxWidth: 240, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder private func sidebarGroup(_ title: String, items: [SettingsDestination]) -> some View {
        let matches = items.filter { $0.matches(navigationQuery) }
        if !matches.isEmpty {
            Section(title) {
                ForEach(matches) { item in
                    Label {
                        Text(item.rawValue).font(.system(size: 13)).lineLimit(1)
                    } icon: {
                        Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 22)
                            .foregroundStyle(item == .support ? Color.pink : Color.accentColor)
                    }.padding(.vertical, 1).tag(item)
                }
            }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.preferences.profiles.isEmpty {
                ContentUnavailableView("Add your first profile", systemImage: "person.crop.circle.badge.plus", description: Text("Keep work and personal accounts together, with a separate sign-in for each."))
            } else {
                HStack {
                    Text("\(model.preferences.profiles.count) profiles").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(model.preferences.profiles.filter { model.running[$0.id]?.isEmpty == false }.count) open")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(model.preferences.profiles.enumerated()), id: \.element.id) { index, profile in
                            profileRow(profile, index: index)
                            if index < model.preferences.profiles.count - 1 { Divider().padding(.leading, 72) }
                        }
                    }
                }
            }
            if copying || !model.nativeDockOperations.isEmpty { ProgressView("Preparing your profile…").controlSize(.small) }
            HStack {
                Button { model.restoreImportedProfiles() } label: { Label("Import or Restore Profiles…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            Text("Each profile keeps its own sign-in, chats and settings. Click its name to edit it.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(updates.busy || copying || !model.nativeDockOperations.isEmpty)
    }

    private func profileRow(_ profile: Profile, index: Int) -> some View {
        let isOpen = model.running[profile.id]?.isEmpty == false
        return HStack(spacing: 12) {
            Button { editing = profile } label: {
                HStack(spacing: 12) {
                    ProfileBadge(model: model, profile: profile, size: 40, showStatus: false)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(isOpen ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                            Text(model.state(profile))
                            Text("·")
                            Text(profile.dockApplicationPath != nil ? "Custom Dock icon" : profile.applicationPath == nil ? "Shared app" : "Separate app")
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Edit \(profile.name)").accessibilityLabel("Edit \(profile.name)")
            if index < 9 {
                Text("⌥⌘\(index + 1)").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 38)
                    .accessibilityLabel("Option Command \(index + 1)")
            }
            Button(isOpen ? "Show" : "Open") { model.select(profile) }
                .buttonStyle(.bordered).frame(width: 62)
                .disabled(model.opening.contains(profile.id) || model.closing.contains(profile.id))
                .accessibilityLabel("\(isOpen ? "Show" : "Open") \(profile.name)")
            Menu { profileCommands(profile, index: index) } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16)).frame(width: 22, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More actions for \(profile.name)").accessibilityLabel("Options for \(profile.name)")
        }.padding(.horizontal, 16).padding(.vertical, 15)
            .contextMenu { profileCommands(profile, index: index) }
    }

    @ViewBuilder private func profileCommands(_ profile: Profile, index: Int) -> some View {

        Section {
            Button("Profile settings…", systemImage: "slider.horizontal.3") { editing = profile }
            Button("Context tagging…", systemImage: "at") { manageContext(for: profile.id) }
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

    }


    private var insightsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            if let error = updates.error {
                SettingsNotice(text: error, symbol: "exclamationmark.triangle.fill", isWarning: true,
                               actionTitle: "Check Again", action: { Task { await updates.check() } })
            }
            Button("Update selected ChatGPT apps") { confirmingUpdate = true }.buttonStyle(.borderedProminent).disabled(selectedGroups.isEmpty || updates.busy || selfUpdates.sessionInProgress)
            Text("Only selected app groups restart. Your profiles, sign-ins and chats stay in place. Enabled custom Dock icons are reapplied automatically.").font(.caption).foregroundStyle(.secondary)
        }.task { await updates.check() }
    }

    private var profiledockUpdateCard: some View {
        GroupBox("ProfileDock") {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    BrandMark(size: 30).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ProfileDock").font(.headline)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") { selfUpdates.check() }.disabled(!selfUpdates.canCheck || updates.busy)
                }.padding(16)
                Divider().padding(.leading, 16)
                SettingsRow(title: "Check automatically", detail: "Checks daily. You choose when to download and install.") {
                    Toggle("Automatically check for ProfileDock updates", isOn: Binding(get: { selfUpdates.automatic }, set: { selfUpdates.setAutomatic($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!selfUpdates.enabled)
                }
                if let last = selfUpdates.lastChecked {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 16)
                }
            }
        }
    }

    private func manageContext(for profileID: String? = nil) {
        if let profileID { model.contextSettings.selectCaller(profileID) }
        navigate(.access)
    }

    private var profileIconSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.preferences.profiles.isEmpty {
                ContentUnavailableView("Add your first profile", systemImage: "person.crop.circle.badge.plus", description: Text("Then choose an icon for it here."))
                Button("Add Profile") { adding = true }.buttonStyle(.borderedProminent)
            } else {
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(model.preferences.profiles.enumerated()), id: \.element.id) { index, profile in
                            HStack(spacing: 14) {
                                Image(nsImage: model.artwork(for: profile))
                                    .resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(profile.dockApplicationPath == nil ? "Native Dock icon off" : model.nativeDockAwaitsRelaunch(profile) ? "Ready for next launch" : "Native Dock icon on")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Customize…") { editing = profile }.accessibilityLabel("Customize icon for \(profile.name)")
                            }.padding(16)
                            if index < model.preferences.profiles.count - 1 { Divider().padding(.leading, 74) }
                        }
                    }
                }
            }
            SettingsNotice(text: "Native Dock icons are optional and experimental. Enabling one prepares a separate app copy; it takes effect the next time that profile opens.")
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox("Startup") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Open at login", detail: "Have your profiles ready when you sign in to your Mac.") {
                        Toggle("Open at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) })).labelsHidden()
                    }
                    if loginItem.requiresApproval {
                        Divider().padding(.leading, 16)
                        SettingsRow(title: "Allow ProfileDock in Login Items") {
                            Button("Open System Settings…") { loginItem.openSystemSettings() }
                        }
                    }
                    if let error = loginItem.error {
                        SettingsNotice(text: error, symbol: "exclamationmark.triangle.fill", isWarning: true,
                                       actionTitle: "Open System Settings…", action: { loginItem.openSystemSettings() }).padding(12)
                    }
                }
            }
            GroupBox("Dock & Menu Bar") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Show in menu bar", detail: "Quick access to profiles, search and settings.") {
                        Toggle("Show ProfileDock in the menu bar", isOn: Binding(get: { model.preferences.showMenuBarIcon != false }, set: { model.preferences.showMenuBarIcon = $0; model.save() })).labelsHidden()
                    }
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Keep in Dock", detail: "Keep the ProfileDock icon visible when its window is closed.") {
                        Toggle("Keep ProfileDock in the Dock", isOn: Binding(get: { model.preferences.showDockIcon == true }, set: { model.preferences.showDockIcon = $0; model.save() })).labelsHidden()
                    }
                }
            }
            Text("You can always open ProfileDock from Applications or Spotlight. Individual profile icons are managed in Profile Icons.")
                .font(.caption).foregroundStyle(.secondary)
        }.toggleStyle(.switch).controlSize(.small)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox("Profile Strip") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Position") {
                        Picker("Position", selection: Binding(get: { model.placement }, set: { model.preferences.placement = $0; model.save() })) {
                            ForEach(DockPlacement.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize().frame(width: 210, alignment: .trailing)
                    }
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Profile size") {
                        Picker("Profile size", selection: Binding(get: { model.preferences.scale }, set: { model.preferences.scale = $0; model.save() })) {
                            Text("Small").tag(0.85); Text("Default").tag(1.0); Text("Large").tag(1.3)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
                    }
                    Divider().padding(.leading, 16)
                    VStack(spacing: 18) {
                        widthControl("Compact width", value: Binding(get: { model.preferences.compactWidth }, set: { model.preferences.compactWidth = $0; model.save() }), range: 160...480, automatic: WidgetSizing.compact(count: model.preferences.profiles.count, preferred: nil))
                        widthControl("Expanded width", value: Binding(get: { model.preferences.expandedWidth }, set: { model.preferences.expandedWidth = $0; model.save() }), range: 320...1400, automatic: WidgetSizing.expanded(count: model.preferences.profiles.count, scale: model.preferences.scale, preferred: nil, insights: false))
                    }.padding(16)
                    if model.placement == .free {
                        Divider().padding(.leading, 16)
                        SettingsRow(title: "Positions on each display") {
                            Button("Reset Positions") { model.preferences.floatingPositions = nil; model.preferences.placement = .free; model.save() }
                        }
                    }
                }
            }
            Text(model.placement.instruction).font(.caption).foregroundStyle(.secondary)
            GroupBox("ProfileDock App Icon") { AppIconAppearancePicker(model: model).padding(12) }
            GroupBox("Activity & Sound") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Activity cues", detail: "Show when a task finishes or needs your input.") {
                        Toggle("Show activity cues", isOn: Binding(get: { model.preferences.activityCues != false }, set: { model.preferences.activityCues = $0; model.save(); if !$0 { cues.dismiss() } })).labelsHidden()
                    }
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Activity sounds", detail: "Play a quiet sound with each cue.") {
                        Toggle("Play activity sounds", isOn: Binding(get: { model.preferences.activitySounds == true }, set: { model.preferences.activitySounds = $0; model.save() })).labelsHidden()
                    }
                    if model.preferences.activitySounds == true {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.1")
                            Slider(value: Binding(get: { model.preferences.activitySoundVolume ?? 0.18 }, set: { model.preferences.activitySoundVolume = $0; model.save() }), in: 0...0.5).accessibilityLabel("Activity sound volume")
                            Image(systemName: "speaker.wave.2")
                        }.foregroundStyle(.secondary).padding(16)
                    }
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("Try a cue").foregroundStyle(.secondary)
                        Spacer()
                        Button("Task Complete") { cues.present(.finished, model: model, preview: true) }
                        Button("Input Needed") { cues.present(.needsInput, model: model, preview: true) }
                    }.padding(16)
                }
            }.toggleStyle(.switch).controlSize(.small)
            Text("Activity covers local Work and Codex tasks. Ordinary chats and tasks on other computers are outside this view.")
                .font(.caption).foregroundStyle(.secondary)
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
            SettingsCard {
                VStack(spacing: 16) {
                    Image(systemName: "heart.fill").font(.system(size: 34))
                        .foregroundStyle(.pink).frame(width: 72, height: 72)
                        .background(.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Support ProfileDock").font(.title2.weight(.semibold))
                        Text("If ProfileDock makes your day a little easier, you can help support its development.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Every feature stays free. Contributions are always optional.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: 400)
                }.padding(28).frame(maxWidth: .infinity)
            }
            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "One-time donation", detail: "A small thank-you, whenever you like.") {
                        Link("Donate Once", destination: AppBrand.donation).buttonStyle(.bordered)
                    }
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Monthly sponsorship", detail: "Help fund continued improvements.") {
                        Link("Sponsor Monthly", destination: AppBrand.sponsors).buttonStyle(.bordered)
                    }
                }
            }
            Text("Donations and sponsorships open on GitHub Sponsors.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                HStack(spacing: 18) {
                    BrandMark(size: 48).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ProfileDock").font(.title2.weight(.semibold))
                        Text("Free, open source, and made by Breukr.").foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
            GroupBox("Help & Feedback") {
                VStack(alignment: .leading, spacing: 14) {
                    Link("Read the Guide", destination: AppBrand.repository.appendingPathComponent("blob/main/docs/GUIDE.md"))
                    Link("Report an Issue", destination: AppBrand.repository.appendingPathComponent("issues/new/choose"))
                    Link("View on GitHub", destination: AppBrand.repository)
                    Link("Privacy & Security", destination: AppBrand.repository.appendingPathComponent("blob/main/PRIVACY.md"))
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("An independent companion for ChatGPT and Codex. Not affiliated with OpenAI.").font(.caption).foregroundStyle(.secondary)
        }
    }

}

private struct AddProfileSheet: View {
    @ObservedObject var model: DockModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var separate = false
    @State private var source: URL?
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Profile").font(.title2.weight(.semibold))
            Text("A profile is a separate sign-in, conversation history and settings. Give it a name, then sign in when it opens.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Profile name").font(.subheadline.weight(.medium))
                TextField("For example, Personal or Work", text: $name).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).accessibilityLabel("Profile name")
            }
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
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(ProfileLaunch.newProfile(name: name) == nil)
            }
        }.padding(28).frame(width: 500).disabled(creating).interactiveDismissDisabled(creating).onAppear { nameFocused = true }
    }
}
