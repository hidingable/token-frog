import Charts
import SwiftUI
import VoyageCore

enum DashboardPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, quarter, year, all
    var id: String { rawValue }

    /// Days before today to include; nil reads from the first recorded day.
    var lookback: Int? {
        switch self {
        case .today: 0
        case .week: 6
        case .month: 29
        case .quarter: 89
        case .year: 364
        case .all: nil
        }
    }
}

struct DashboardSelection: Hashable, Sendable {
    var period: DashboardPeriod = .month
    /// Set by clicking a day in the trend or the grid; narrows everything to it.
    var day: String?
    var client: String?
    var model: String?
    var metric: DashboardMetric = .total
    var showModels = false
}

struct DashboardTab: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.value == rhs.value }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @Binding var selection: DashboardSelection
    private let value: DashboardSelection

    init(model: AppModel, selection: Binding<DashboardSelection>) {
        self.model = model
        _selection = selection
        value = selection.wrappedValue
    }

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        let store = model.dashboardStore
        let refresh = DashboardRefresh(version: store.version, today: store.today, selection: selection, seriesLimit: theme.series.count)
        Group {
            if model.usageDisplayState == .noUsage {
                Text(l10n("usage.noRecords")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = store.result {
                content(result)
            } else if model.lastError == nil {
                Text(l10n("dashboard.loading")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // lastScan is in the id so a load skipped because a scan held the slot retries after that scan.
        .task(id: String(describing: model.lastScan)) { await model.loadDashboard() }
        .task(id: refresh) {
            await store.select(store.request(selection: refresh.selection, seriesLimit: refresh.seriesLimit, calendar: refresh.calendar))
        }
    }

    private func content(_ result: DashboardPresentation) -> some View {
        DashboardMeasurementCounters.record(.dashboardContent)
        return VStack(alignment: .leading, spacing: 12) {
            controls()
            MetricsGrid(board: result.stats).equatable()
            TrendCard(data: result.trend, metric: result.request.metric, tools: result.tools, selection: $selection).equatable()
            ActivityCard(heat: result.heat, hours: result.hours, weekdays: result.weekdays, filtered: !result.request.filter.isEmpty,
                         rangeStart: result.board.start, rangeEnd: result.board.end, metric: result.request.metric, selection: $selection).equatable()
            BreakdownRow(ledger: result.board.ledger, tools: result.tools, client: selection.client, model: selection.model, selection: $selection).equatable()
            DetailTable(ledger: result.board.ledger, showModels: selection.showModels, selection: $selection).equatable()
            Text(l10n("dashboard.source"))
                .font(Theme.pixel())
                .foregroundStyle(theme.textMuted)
        }
    }

    private func controls() -> some View {
        HStack(spacing: 4) {
            ForEach(DashboardPeriod.allCases) { item in
                Chip(title: l10n.period(item), isOn: selection.day == nil && selection.period == item) {
                    selection.period = item
                    selection.day = nil
                }
            }
            Spacer(minLength: 8)
            if let day = selection.day {
                ClearChip(title: l10n.day(day, full: true)) { selection.day = nil }
            }
            if let client = selection.client {
                ClearChip(title: Vehicle.toolName(client)) { selection.client = nil }
            }
            if let name = selection.model {
                ClearChip(title: l10n.modelName(name)) { selection.model = nil }
            }
        }
    }
}

struct Chip: View {
    @Environment(\.theme) private var theme
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        Button(action: action) {
            Text(title)
                .font(Theme.pixel())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? theme.selectedText : theme.text)
                .background(isOn ? theme.selectedFill : theme.surfaceRaised)
        }
        .buttonStyle(.plain)
    }
}

struct ClearChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    var title: String
    var action: () -> Void

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        Button(action: action) {
            Text(l10n("filter.chip", title))
                .font(Theme.pixel())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(theme.text)
                .pixelBorder(theme.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n("filter.clear", title))
    }
}

private struct Card<Content: View, Accessory: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(theme.text)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .font(Theme.pixel())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised.opacity(0.45))
        .pixelBorder(theme.surfaceRaised)
    }
}

private func toolColor(_ name: String, tools: [String], theme: AppTheme) -> Color {
    tools.firstIndex(of: name).map { theme.series[$0] } ?? theme.seriesOther
}

struct MetricsGrid: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.board == rhs.board }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let board: DashboardStats

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        let totals = board.totals
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                tile(l10n("metric.total"), Format.tokens(totals.total, language: l10n.language), delta(.total))
                tile(l10n("dashboard.estimatedCost"), Format.cost(totals.cost), delta(.cost))
                tile(l10n("dashboard.counted"), Format.km(DashboardMetric.fuel.value(totals)), delta(.fuel), theme.mileageText)
                tile(l10n("dashboard.cacheHits"), Format.percent(totals.cacheHitPercent), nil)
                tile(l10n("metric.messages"), Format.grouped(totals.messages), delta(.messages))
            }
            GridRow {
                tile(l10n("dashboard.activeDays"), "\(board.activeDays) / \(board.calendarDays)", l10n("dashboard.activeRate", Format.grouped(Int((board.activeRate * 100).rounded()))))
                tile(l10n("dashboard.streak"), l10n.days(board.currentStreak), l10n("dashboard.longest", l10n.language == .zhHans ? Format.grouped(board.longestStreak) : l10n.days(board.longestStreak)))
                tile(l10n("dashboard.sessionTime"), board.activeMs.map(l10n.duration) ?? "-", board.activeMs == nil ? l10n("dashboard.filteredTime") : nil)
                tile(l10n("dashboard.peakDay"), board.peak.map { Format.tokens($0.total, language: l10n.language) } ?? "-", board.peak.map { l10n.day($0.date) })
                tile(l10n("dashboard.topModel"), board.topModel.map(l10n.modelName) ?? "-", nil, theme.text, small: true)
            }
        }
    }

    private func delta(_ metric: DashboardMetric) -> String? {
        guard let change = board.change(metric) else { return nil }
        let rounded = Int(change.rounded())
        return rounded == 0 ? l10n("dashboard.unchanged") : l10n("dashboard.delta", "\(rounded > 0 ? "+" : "")\(Format.grouped(rounded))")
    }

    private func tile(_ label: String, _ value: String, _ note: String?, _ color: Color? = nil, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(theme.textMuted)
            Text(value)
                .font(Theme.pixel(small ? 12 : 24))
                .foregroundStyle(color ?? theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 24, alignment: .leading)
            Text(note ?? " ").foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.pixel())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceRaised)
        .accessibilityElement(children: .combine)
    }
}

struct TrendCard: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data && lhs.metric == rhs.metric && lhs.tools == rhs.tools }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let data: DashboardTrend
    let metric: DashboardMetric
    let tools: [String]
    @Binding var selection: DashboardSelection
    @State private var hovered: String?
    private typealias Mark = DashboardTrend.Mark

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        Card(title: data.isSingleDay ? l10n("trend.hourly") : (data.buckets.first?.isWeek == true ? l10n("trend.weekly") : l10n("trend.daily"))) {
            ForEach(DashboardMetric.allCases) { item in
                Chip(title: l10n.metric(item), isOn: metric == item) { selection.metric = item }
            }
        } content: {
            readout(metric: metric)
            if data.isSingleDay && data.filtered {
                Text(l10n("trend.clearFilters")).foregroundStyle(theme.textMuted).frame(height: 180)
            } else if data.isSingleDay && data.marks.isEmpty {
                Text(l10n("trend.noHours")).foregroundStyle(theme.textMuted).frame(height: 180)
            } else {
                chart(marks: data.marks, buckets: data.buckets, metric: metric, isSingleDay: data.isSingleDay)
                    .frame(height: 180)
                    .accessibilityLabel(l10n("trend.description", l10n.metric(metric)))
            }
            if !data.isSingleDay { legend(metric: metric) }
        }
    }

    private func readout(metric: DashboardMetric) -> some View {
        let isHours = data.isSingleDay
        let bucket = hovered.flatMap { data.readouts[$0] } ?? data.highest
        return HStack(spacing: 12) {
            if let bucket {
                let label = isHours ? l10n.hour(Int(bucket.start)!) : (bucket.isWeek ? l10n("trend.weekOf", l10n.day(bucket.start)) : l10n.day(bucket.start))
                Text(hovered == nil ? l10n("trend.highest", label) : label).foregroundStyle(theme.textMuted)
                Text(metric.format(bucket.total, language: l10n.language)).foregroundStyle(theme.text)
                ForEach(bucket.series, id: \.name) { entry in
                    if !isHours {
                        Text(l10n("chart.seriesValue", l10n.series(entry.name), metric.format(entry.value, language: l10n.language)))
                            .foregroundStyle(theme.textMuted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func chart(marks: [Mark], buckets: [TrendBucket], metric: DashboardMetric, isSingleDay: Bool) -> some View {
        let keys = data.keys
        let labels = data.labels
        return Chart(marks) { mark in
            BarMark(x: .value(l10n("chart.time"), mark.bucket), y: .value(l10n.metric(metric), mark.value), width: .ratio(0.7))
                .foregroundStyle(isSingleDay ? theme.textMuted : toolColor(mark.series, tools: tools, theme: theme))
                .opacity(hovered == nil || hovered == mark.bucket ? 1 : 0.45)
        }
        .chartXScale(domain: keys)
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(isSingleDay ? key : l10n.day(key)).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(theme.controlOff)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.format(number, language: l10n.language)).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = proxy.value(atX: point.x, as: String.self)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { point in
                    guard !isSingleDay, buckets.first?.isWeek == false,
                          let key = proxy.value(atX: point.x, as: String.self) else { return }
                    selection.day = key
                }
        }
    }

    private func legend(metric: DashboardMetric) -> some View {
        let total = data.legendTotal
        return HStack(spacing: 12) {
            ForEach(data.legend, id: \.name) { entry in
                let name = entry.name
                let value = entry.value
                HStack(spacing: 4) {
                    Rectangle().fill(toolColor(name, tools: tools, theme: theme)).frame(width: 8, height: 8)
                    Text(l10n.series(name)).foregroundStyle(theme.text)
                    Text(l10n("chart.valueShare", metric.format(value, language: l10n.language), Format.grouped(Int((value / total * 100).rounded())))).foregroundStyle(theme.textMuted)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ActivityCard: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.heat == rhs.heat && lhs.hours == rhs.hours && lhs.weekdays == rhs.weekdays && lhs.filtered == rhs.filtered
            && lhs.rangeStart == rhs.rangeStart && lhs.rangeEnd == rhs.rangeEnd && lhs.metric == rhs.metric
    }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let heat: DashboardHeat
    let hours: [Double]
    let weekdays: [Double]
    let filtered: Bool
    let rangeStart: String
    let rangeEnd: String
    let metric: DashboardMetric
    @Binding var selection: DashboardSelection
    @State private var hovered: HeatCell?

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        Card(title: l10n("dashboard.active")) {
            Text(readoutText(metric)).foregroundStyle(theme.textMuted).lineLimit(1)
        } content: {
            HeatGrid(heat: heat, rangeStart: rangeStart, rangeEnd: rangeEnd, hovered: $hovered) { selection.day = $0 }
                .equatable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n("activity.description", Format.grouped(heat.activeCount)))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(!filtered ? l10n("activity.hours") : l10n("activity.filteredHours")).foregroundStyle(theme.textMuted)
                    MiniBars(values: hours, labels: ["0", "6", "12", "18"], every: 6, metric: metric, language: l10n.language) { "\(l10n.hour($0)) \(metric.format($1, language: l10n.language))" }.equatable()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n("activity.weekday")).foregroundStyle(theme.textMuted)
                    MiniBars(values: weekdays, labels: l10n.weekdays, every: 1, metric: metric, language: l10n.language) { index, value in
                        "\(l10n.weekday(index)) \(metric.format(value, language: l10n.language))"
                    }.equatable()
                }
                .frame(minWidth: 200, maxWidth: .infinity)
            }
        }
    }

    private func readoutText(_ metric: DashboardMetric) -> String {
        if let hovered, let cell = heat.cells.first(where: { $0.date == hovered.date }) {
            return "\(l10n.day(cell.date, full: true)) · \(cell.value > 0 ? metric.format(cell.value, language: l10n.language) : l10n("activity.noUsage"))"
        }
        return l10n("activity.help")
    }
}

/// One Canvas instead of 371 hit-tested views, so hovering stays cheap.
struct HeatGrid: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.heat == rhs.heat && lhs.rangeStart == rhs.rangeStart && lhs.rangeEnd == rhs.rangeEnd
    }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let heat: DashboardHeat
    let rangeStart: String
    let rangeEnd: String
    @Binding var hovered: HeatCell?
    var onSelect: (String) -> Void

    private static let gap: CGFloat = 2

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        GeometryReader { proxy in
            let weeks = CGFloat(heat.weeks)
            let size = max(4, ((proxy.size.width - 20) / weeks).rounded(.down) - Self.gap)
            let pitch = size + Self.gap
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cell in heat.cells {
                        let rect = CGRect(x: 20 + CGFloat(cell.week) * pitch, y: 16 + CGFloat(cell.weekday) * pitch, width: size, height: size)
                        let inRange = cell.date >= rangeStart && cell.date <= rangeEnd
                        context.fill(Path(rect), with: .color(theme.heat[cell.level].opacity(inRange ? 1 : 0.4)))
                    }
                }
                ForEach(heat.months, id: \.week) { label in
                    Text(l10n.month(label.month)).foregroundStyle(theme.textMuted).offset(x: 20 + CGFloat(label.week) * pitch, y: -2)
                }
                ForEach(Array([l10n.weekdays[0], l10n.weekdays[2], l10n.weekdays[4]].enumerated()), id: \.offset) { index, name in
                    Text(name).foregroundStyle(theme.textMuted).offset(x: 0, y: 16 + CGFloat(index * 2) * pitch - 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = cell(at: point, pitch: pitch)
                case .ended: hovered = nil
                }
            }
            .onTapGesture { point in
                if let cell = cell(at: point, pitch: pitch) { onSelect(cell.date) }
            }
        }
        .frame(height: 16 + 7 * 13)
    }

    private func cell(at point: CGPoint, pitch: CGFloat) -> HeatCell? {
        HeatGridGeometry.cell(at: point, pitch: pitch, cells: heat.cells)
    }

}

struct MiniBars: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values && lhs.labels == rhs.labels && lhs.every == rhs.every && lhs.metric == rhs.metric && lhs.language == rhs.language
    }
    @Environment(\.theme) private var theme
    let values: [Double]
    let labels: [String]
    let every: Int
    let metric: DashboardMetric
    let language: Language
    var describe: (Int, Double) -> String
    @State private var hovered: Int?

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        let top = max(values.max() ?? 0, 0.000_001)
        if values.isEmpty {
            EmptyView()
        } else {
            bars(top: top)
        }
    }

    private func bars(top: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Rectangle()
                        .fill(hovered == index ? theme.text : theme.textMuted)
                        .frame(height: value > 0 ? max(2, (CGFloat(value / top) * 48).rounded()) : 1)
                        .frame(maxWidth: .infinity, maxHeight: 48, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                        .accessibilityLabel(describe(index, value))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(label).foregroundStyle(theme.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(hovered.flatMap { values.indices.contains($0) ? describe($0, values[$0]) : nil } ?? " ")
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
        }
    }
}

struct BreakdownRow: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ledger == rhs.ledger && lhs.tools == rhs.tools && lhs.client == rhs.client && lhs.model == rhs.model
    }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let ledger: UsageLedger
    let tools: [String]
    let client: String?
    let model: String?
    @Binding var selection: DashboardSelection

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        let totals = ledger.totals
        HStack(alignment: .top, spacing: 8) {
            Card(title: l10n("breakdown.tools")) { EmptyView() } content: {
                ranked(ledger.byClient.prefix(6).map { ($0.name, Vehicle.toolName($0.name), $0.tokens.total, toolColor($0.name, tools: tools, theme: theme)) }, total: totals.total, isOn: { client == $0 }) { name in
                    selection.client = selection.client == name ? nil : name
                }
            }
            Card(title: l10n("breakdown.models")) { EmptyView() } content: {
                ranked(ledger.byModel.prefix(6).map { ($0.name, l10n.modelName($0.name), $0.tokens.total, theme.textMuted) }, total: totals.total, isOn: { model == $0 }) { name in
                    selection.model = selection.model == name ? nil : name
                }
            }
            Card(title: l10n("breakdown.composition")) { EmptyView() } content: {
                ranked([
                    (l10n("usage.cacheRead"), l10n("usage.cacheRead"), totals.cacheRead, theme.textMuted), (l10n("usage.input"), l10n("usage.input"), totals.input, theme.textMuted),
                    (l10n("usage.cacheWrite"), l10n("usage.cacheWrite"), totals.cacheWrite, theme.textMuted), (l10n("usage.output"), l10n("usage.output"), totals.output, theme.textMuted),
                    (l10n("usage.reasoning"), l10n("usage.reasoning"), totals.reasoning, theme.textMuted),
                ], total: totals.total, isOn: { _ in false }, action: nil)
            }
        }
    }

    private func ranked(_ rows: [(id: String, label: String, value: Int, color: Color)], total: Int, isOn: @escaping (String) -> Bool, action: ((String) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty { Text(l10n("usage.empty")).foregroundStyle(theme.textMuted) }
            ForEach(rows, id: \.id) { row in
                let share = total > 0 ? Double(row.value) / Double(total) : 0
                let line = VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.label)
                            .foregroundStyle(isOn(row.id) ? theme.selectedText : theme.text)
                            .background(isOn(row.id) ? theme.selectedFill : .clear)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.tokens(row.value, language: l10n.language)).foregroundStyle(theme.text).lineLimit(1).layoutPriority(1)
                        Text(String(format: "%.1f%%", share * 100)).foregroundStyle(theme.textMuted).lineLimit(1).frame(width: 46, alignment: .trailing).layoutPriority(1)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(theme.controlOff)
                            Rectangle().fill(row.color).frame(width: row.value > 0 ? max(1, (proxy.size.width * share).rounded()) : 0)
                        }
                    }
                    .frame(height: 4)
                }
                if let action {
                    Button { action(row.id) } label: { line.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityValue(isOn(row.id) ? l10n("filter.selected") : "")
                } else {
                    line
                }
            }
        }
    }
}

struct DetailTable: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.ledger == rhs.ledger && lhs.showModels == rhs.showModels }
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let ledger: UsageLedger
    let showModels: Bool
    @Binding var selection: DashboardSelection

    var body: some View {
        let _ = DashboardMeasurementCounters.record(.body)
        let entries = showModels ? ledger.byModel : ledger.byClient
        Card(title: l10n("dashboard.details")) {
            Chip(title: l10n("dashboard.tools"), isOn: !showModels) { selection.showModels = false }
            Chip(title: l10n("dashboard.models"), isOn: showModels) { selection.showModels = true }
        } content: {
            LazyVStack(alignment: .leading, spacing: 4) {
                row(showModels ? l10n("dashboard.models") : l10n("dashboard.tools"), [l10n("metric.total"), l10n("usage.input"), l10n("usage.output"), l10n("table.cacheRead"), l10n("table.cacheWrite"), l10n("table.hit"), l10n("metric.cost"), l10n("metric.messages")], color: theme.textMuted)
                Rectangle().fill(theme.controlOff).frame(height: 2)
                if entries.isEmpty { Text(l10n("usage.empty")).foregroundStyle(theme.textMuted) }
                ForEach(entries) { entry in
                    let tokens = entry.tokens
                    Button {
                        if showModels {
                            selection.model = selection.model == entry.name ? nil : entry.name
                        } else {
                            selection.client = selection.client == entry.name ? nil : entry.name
                        }
                    } label: {
                        row(showModels ? l10n.modelName(entry.name) : Vehicle.toolName(entry.name), [
                            Format.tokens(tokens.total, language: l10n.language), Format.tokens(tokens.input, language: l10n.language), Format.tokens(tokens.output, language: l10n.language),
                            Format.tokens(tokens.cacheRead, language: l10n.language), Format.tokens(tokens.cacheWrite, language: l10n.language),
                            Format.percent(tokens.cacheHitPercent), Format.cost(tokens.cost), Format.grouped(tokens.messages),
                        ], color: theme.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ title: String, _ cells: [String], color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell).fixedSize(horizontal: false, vertical: true).frame(minWidth: 48, maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(color)
    }
}
