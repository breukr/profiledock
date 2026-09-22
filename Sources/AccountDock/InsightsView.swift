import SwiftUI
import Charts
import DockCore

enum InsightMetric: String, CaseIterable {
    case cost = "Cost", tokens = "Tokens", sessions = "Sessions"
    func value(_ bucket: InsightBucket) -> Double {
        switch self { case .cost: return bucket.cost; case .tokens: return Double(bucket.tokens.total); case .sessions: return Double(bucket.sessions.count) }
    }
    func value(_ slice: InsightAccountSlice) -> Double {
        switch self { case .cost: return slice.cost; case .tokens: return Double(slice.tokens.total); case .sessions: return Double(slice.sessions.count) }
    }
}

enum InsightsPalette {
    static let colors: [Color] = [Color(red: 0.30, green: 0.65, blue: 1), Color(red: 0.24, green: 0.82, blue: 0.67),
        Color(red: 0.70, green: 0.52, blue: 1), Color(red: 1, green: 0.72, blue: 0.30),
        Color(red: 0.98, green: 0.45, blue: 0.64), Color(red: 0.24, green: 0.80, blue: 0.90),
        Color(red: 0.70, green: 0.81, blue: 0.38), Color(red: 0.96, green: 0.52, blue: 0.32)]
}

enum InsightFormat {
    static func tokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
    }
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
}

struct InsightsPanel: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: InsightsStore
    var compact = false
    var active = true
    var onPopoverChange: (Bool) -> Void
    var account: String { model.insightsAccount }
    var period: InsightsPeriod { model.insightsPeriod }
    var metric: InsightMetric { model.insightsMetric }
    @State private var selectedDate: Date?
    @State private var report = InsightReport.make(samples: [], profileID: nil, period: .week, now: Date())
    @State private var explanation = false
    @State private var slices: [InsightAccountSlice] = []

    init(model: DockModel, store: InsightsStore, compact: Bool = false, active: Bool = true, onPopoverChange: @escaping (Bool) -> Void = { _ in }) {
        self.model = model; self.store = store; self.compact = compact; self.active = active
        self.onPopoverChange = onPopoverChange
        let initial = InsightReport.make(samples: store.snapshot.samples, profileID: model.insightsAccount == "all" ? nil : model.insightsAccount, period: model.insightsPeriod, now: Date())
        _report = State(initialValue: initial)
        _slices = State(initialValue: initial.buckets.flatMap { bucket in model.preferences.profiles.compactMap { bucket.accounts[$0.id] } })
    }

    private var warnings: [String] {
        Array(Set(store.snapshot.warnings.filter { account == "all" || $0.key == account }.map(\.value))).sorted()
    }
    private var selected: InsightBucket? {
        guard let selectedDate else { return nil }
        return report.buckets.last { $0.date <= selectedDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(spacing: 12) {
                Picker("Account", selection: $model.insightsAccount) {
                    Text("All accounts").tag("all")
                    ForEach(model.preferences.profiles) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: compact ? 170 : 230, alignment: .leading)
                    .accessibilityLabel("Usage insights account")
                Spacer(minLength: 0)
                Picker("Period", selection: $model.insightsPeriod) {
                    ForEach(InsightsPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 192).accessibilityLabel("Usage insights period")
                if !compact {
                    Button { store.refresh(profiles: model.preferences.profiles, home: model.home, force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(store.refreshing).help("Refresh local usage history")
                }
            }
            if store.lastUpdated == nil {
                HStack(spacing: 10) {
                    if store.refreshing { ProgressView().controlSize(.small) }
                    Text(store.refreshing ? (store.scannedFiles > 0 ? "Reading local history… \(store.scannedFiles) sessions scanned" : "Reading local session history…") : "Open a local session to start your overview.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: compact ? 230 : 300)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("API-equivalent · USD").font(.caption).foregroundStyle(.secondary)
                        Text(report.unpricedTokens == report.tokens.total && report.tokens.total > 0 ? "Unavailable" : InsightFormat.money(report.cost) + (report.unpricedTokens > 0 ? "+" : ""))
                            .font(.system(size: compact ? 28 : 38, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.7).lineLimit(1)
                        Text(report.tokens.total == 0 ? "No recorded usage in this period" : "Estimated at current Standard rates")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    metricValue("Tokens", value: InsightFormat.tokens(report.tokens.total))
                    metricValue("Sessions", value: report.sessions.count.formatted())
                    if !compact { metricValue("Avg / session", value: report.averageCost.map(InsightFormat.money) ?? "Unavailable") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(selected.map { bucketDescription($0) } ?? (period == .today ? "Hourly activity" : "Daily activity"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Picker("Chart metric", selection: $model.insightsMetric) {
                            ForEach(InsightMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    Chart(slices) { slice in
                        BarMark(x: .value("Date", slice.date, unit: period == .today ? .hour : .day), y: .value(metric.rawValue, metric.value(slice)), stacking: .standard)
                            .foregroundStyle(by: .value("Account", slice.profileID))
                            .cornerRadius(period == .week ? 5 : 2)
                            .opacity(selected == nil || selected?.date == slice.date ? 1 : 0.45)
                            .accessibilityLabel(accountName(slice.profileID) + ", " + slice.date.formatted(date: .abbreviated, time: period == .today ? .shortened : .omitted))
                            .accessibilityValue(metric == .cost ? InsightFormat.money(slice.cost) : metric == .tokens ? slice.tokens.total.formatted() + " tokens" : slice.sessions.count.formatted() + " sessions")
                    }
                    .chartForegroundStyleScale(domain: model.preferences.profiles.map(\.id), range: model.preferences.profiles.indices.map { InsightsPalette.colors[$0 % InsightsPalette.colors.count] })
                    .chartLegend(.hidden)
                    .chartXScale(domain: chartDomain)
                    .chartXSelection(value: $selectedDate)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 5)) { _ in AxisValueLabel(); AxisTick() } }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.primary.opacity(0.08)); AxisValueLabel() } }
                    .frame(height: compact ? 100 : 170)
                    .overlay {
                        if report.tokens.total == 0 { Text("No recorded activity").font(.callout).foregroundStyle(.secondary) }
                        else if metric == .cost && report.unpricedTokens == report.tokens.total {
                            Text("Pricing unavailable · switch to Tokens").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                accountLegend
                HStack(spacing: 12) {
                    Text("\(InsightFormat.tokens(report.tokens.cached)) cached").help("Cached input is already included in the token total and uses the lower cached rate.")
                    Text("\(InsightFormat.tokens(report.tokens.output)) output").help("Includes reasoning tokens; they are not counted twice.")
                    Spacer(minLength: 0)
                    if compact { Text("Avg / session \(report.averageCost.map(InsightFormat.money) ?? "unavailable")") }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if !warnings.isEmpty || report.unpricedTokens > 0 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(report.unpricedTokens > 0 ? "Partial estimate: \(InsightFormat.tokens(report.unpricedTokens)) tokens have no reliable price." : "Some local history is unavailable or incomplete.")
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption2).foregroundStyle(.orange)
                }
            }
            HStack {
                Text(store.showingSavedStatistics ? (store.refreshing ? "Saved statistics · updating…" : "Saved statistics · refresh pending") : "Local history · not your bill").font(.caption2).foregroundStyle(.secondary)
                    .help(store.lastUpdated.map { "Last loaded " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Local history only")
                if store.refreshing && store.lastUpdated != nil { ProgressView().controlSize(.mini) }
                Spacer()
                Button("How it’s calculated") { explanation = true }.font(.caption2).buttonStyle(.plain).foregroundStyle(.blue)
            }
        }
        .padding(compact ? 14 : 20)
        .controlSize(.small)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08), lineWidth: 1))
        .onChange(of: account) { _, _ in selectedDate = nil; rebuild() }
        .onChange(of: explanation) { _, presented in onPopoverChange(presented) }
        .onDisappear { onPopoverChange(false) }
        .onChange(of: period) { _, _ in selectedDate = nil; rebuild() }
        .onChange(of: store.lastUpdated) { _, _ in rebuild() }
        .onChange(of: model.preferences.profiles.map(\.id)) { _, _ in
            store.configure(model.preferences.profiles); rebuild()
        }
        .task(id: active) {
            guard active else { return }
            rebuild()
            while !Task.isCancelled {
                store.refresh(profiles: model.preferences.profiles, home: model.home)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                rebuild()
            }
        }
        .popover(isPresented: $explanation) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A useful comparison, not an invoice.").font(.headline)
                Text("Usage comes from local Work/Codex session counters, grouped by profile. Other devices and cloud-only chats are not included. Changing a profile’s sign-in does not reassign its older history.")
                Text("USD estimates use published Standard API rates checked \(InsightPricing.checkedOn), including cached input, cache writes and long-context rates when known. They exclude tool fees, Fast mode, regional uplifts, taxes and subscription charges. Old usage is valued at these current rates.")
                Text("Sessions are distinct local threads active in the selected period, with identifiable subagents grouped into their parent. Average cost covers that period’s usage per session. Copied events count once in the combined view. Today follows your Mac’s time zone; 7 and 30 days include today.")
                if report.unpricedTokens > 0 { Text("Unpriced or incomplete records: " + report.unknownModels.sorted().joined(separator: ", ")).foregroundStyle(.orange) }
                ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                Link("OpenAI pricing", destination: URL(string: InsightPricing.source)!)
            }.font(.callout).padding(22).frame(width: 380)
        }
    }

    private func metricValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: compact ? 19 : 24, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.padding(.top, 2)
    }
    private func rebuild() {
        report = InsightReport.make(samples: store.snapshot.samples, profileID: account == "all" ? nil : account, period: period, now: Date())
        slices = report.buckets.flatMap { bucket in model.preferences.profiles.compactMap { bucket.accounts[$0.id] } }
    }
    private var chartDomain: ClosedRange<Date> {
        let start = report.buckets.first?.date ?? Calendar.current.startOfDay(for: Date())
        let last = report.buckets.last?.date ?? start
        let end = Calendar.current.date(byAdding: period == .today ? .hour : .day, value: 1, to: last) ?? last.addingTimeInterval(3600)
        return start...end
    }
    private func accountName(_ id: String) -> String { model.preferences.profiles.first { $0.id == id }?.name ?? "Account" }
    private var accountLegend: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 145 : 160), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Array(model.preferences.profiles.enumerated()), id: \.element.id) { index, profile in
                    if account == "all" || account == profile.id {
                        let tokens = selected.map { $0.accounts[profile.id]?.tokens.total ?? 0 }
                            ?? report.buckets.reduce(Int64(0)) { $0 + ($1.accounts[profile.id]?.tokens.total ?? 0) }
                        let total = selected?.tokens.total ?? report.tokens.total
                        let share = total > 0 ? Double(tokens) / Double(total) : 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(InsightsPalette.colors[index % InsightsPalette.colors.count]).frame(width: 7, height: 7)
                                Text(profile.name).fontWeight(.medium).lineLimit(2)
                            }
                            Text(InsightFormat.tokens(tokens) + " tokens · " + share.formatted(.percent.precision(.fractionLength(0))))
                                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }.font(.caption2).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(InsightsPalette.colors[index % InsightsPalette.colors.count].opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .accessibilityLabel(selected == nil ? "Account token totals for this period" : "Account tokens for the selected bar")
    }
    private func bucketDescription(_ bucket: InsightBucket) -> String {
        let date = period == .today ? bucket.date.formatted(date: .omitted, time: .shortened) : bucket.date.formatted(.dateTime.month(.abbreviated).day())
        let value = metric == .cost ? InsightFormat.money(bucket.cost) : metric == .tokens ? InsightFormat.tokens(bucket.tokens.total) + " tokens" : "\(bucket.sessions.count) sessions"
        return date + " · " + value
    }
}

struct InsightsDrawer: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: InsightsStore
    @ObservedObject var presentation: IslandPresentation
    @State private var hoverTask: Task<Void, Never>?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var mode: InsightsExpansion { model.preferences.insightsExpansion ?? .button }
    private var expanded: Bool { mode == .always || presentation.insightsExpanded }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    if mode != .always { presentation.setInsightsExpanded(!expanded) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chart.bar.xaxis").foregroundStyle(.blue)
                        Text("Usage insights").fontWeight(.medium)
                        Spacer(minLength: 5)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: expanded)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(mode == .always)
                    .accessibilityLabel(mode == .always ? "Usage insights, always expanded" : expanded ? "Collapse usage insights" : "Expand usage insights")
                Menu {
                    Picker("Open insights", selection: Binding(get: { mode }, set: { model.preferences.insightsExpansion = $0; model.save() })) {
                        ForEach(InsightsExpansion.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize()
                    .help("Choose whether insights open on click, on hover, or stay expanded")
            }.font(.system(size: 11)).frame(height: 24)
                .background(.white.opacity(hovering ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 6))
                .animation(.easeOut(duration: 0.14), value: hovering)
                .onHover { hovering in
                    self.hovering = hovering
                    hoverTask?.cancel()
                    guard hovering, mode == .hover, !expanded else { return }
                    hoverTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard !Task.isCancelled, presentation.expanded, mode == .hover else { return }
                        presentation.setInsightsExpanded(true)
                    }
                }
            if expanded {
                InsightsPanel(model: model, store: store, compact: true, active: presentation.expanded,
                              onPopoverChange: { presentation.insightsPopoverPresented = $0 })
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: expanded)
        .onChange(of: presentation.expanded) { _, open in
            if !open { hoverTask?.cancel() }
        }
        .onDisappear { hoverTask?.cancel() }
    }
}
