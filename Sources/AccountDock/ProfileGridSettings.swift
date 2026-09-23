import SwiftUI
import DockCore

struct ProfileGridSettings: View {
    @ObservedObject var model: DockModel
    private var grid: ProfileGrid { model.preferences.profileGrid ?? ProfileGrid(columns: 3, rows: 2) }
    private func set(_ value: ProfileGrid?) { model.preferences.profileGrid = value; model.save() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Grid layout").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Grid layout", selection: Binding(get: { model.preferences.profileGrid != nil }, set: { set($0 ? grid : nil) })) {
                    Text("Automatic").tag(false)
                    Text("Custom").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
            }
            if model.preferences.profileGrid != nil {
                HStack(spacing: 16) {
                    Picker("Columns", selection: Binding(get: { grid.columns }, set: { set(ProfileGrid(columns: $0, rows: grid.rows)) })) {
                        ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                    }.fixedSize()
                    Picker("Rows", selection: Binding(get: { grid.rows }, set: { set(ProfileGrid(columns: grid.columns, rows: $0)) })) {
                        ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                    }.fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 18) {
                    VStack(spacing: 3) {
                        ForEach(0..<grid.rows, id: \.self) { _ in
                            HStack(spacing: 3) {
                                ForEach(0..<grid.columns, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.65)).frame(width: 9, height: 7)
                                }
                            }
                        }
                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(grid.label) · up to \(grid.capacity) apps per page").font(.callout.weight(.medium))
                        Text("Columns × rows. Applies to apps and the terminal section. Extra apps get another page.")
                        Text("Width follows your columns. Tall grids scroll; fewer columns fit on smaller displays.")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Automatically fit columns and rows to your apps and each display.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProfileGridMenu: View {
    @ObservedObject var model: DockModel
    let columns: Int
    let rows: Int
    private var grid: ProfileGrid { model.preferences.profileGrid ?? ProfileGrid(columns: columns, rows: rows) }
    private func set(_ value: ProfileGrid?) { model.preferences.profileGrid = value; model.save() }
    var body: some View {
        Menu {
            Button("Automatic") { set(nil) }
            Section("Sections") {
                Toggle("Terminals", isOn: Binding(get: { model.preferences.showTerminalsSection != false }, set: { model.preferences.showTerminalsSection = $0; model.save() }))
                Toggle("Usage Insights", isOn: Binding(get: { model.preferences.showInsightsSection != false }, set: { model.preferences.showInsightsSection = $0; model.save() }))
            }
            Menu("Columns") {
                Picker("Columns", selection: Binding(get: { grid.columns }, set: { set(ProfileGrid(columns: $0, rows: grid.rows)) })) {
                    ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Menu("Rows") {
                Picker("Rows", selection: Binding(get: { grid.rows }, set: { set(ProfileGrid(columns: grid.columns, rows: $0)) })) {
                    ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                }
            }
        } label: { Image(systemName: "square.grid.3x3").frame(width: 22, height: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Grid layout").help("Choose columns and rows")
    }
}

struct ProfileGridPagination: View {
    @ObservedObject var model: DockModel
    @Binding var page: Int
    let count: Int
    let capacity: Int
    let terminals: Bool
    var body: some View {
        let pages = max(1, (count + capacity - 1) / capacity)
        let current = min(page, pages - 1)
        if pages > 1 {
            HStack(spacing: 14) {
                Button { page = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(current == 0).accessibilityLabel(terminals ? "Previous terminals" : "Previous accounts")
                    .overlay { ProfileDropTarget(model: model, terminalGroup: terminals, entered: { page = max(0, current - 1) }, targeted: .constant(false)) }
                Text("\(current * capacity + 1)–\(min((current + 1) * capacity, count)) of \(count)")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                Button { page = min(pages - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(current == pages - 1).accessibilityLabel(terminals ? "Next terminals" : "Next accounts")
                    .overlay { ProfileDropTarget(model: model, terminalGroup: terminals, entered: { page = min(pages - 1, current + 1) }, targeted: .constant(false)) }
            }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).frame(height: 20)
        }
    }
}
