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

struct DashboardSelection {
    var period: DashboardPeriod = .month
    /// Set by clicking a day in the trend or the grid; narrows everything to it.
    var day: String?
    var client: String?
    var model: String?
    var metric: DashboardMetric = .total
    var showModels = false
}

struct DashboardTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @Binding var selection: DashboardSelection

    var body: some View {
        Group {
            if let days = model.dashboardDays {
                content(days)
            } else if model.lastError == nil {
                Text(l10n("dashboard.loading")).font(Theme.pixel()).foregroundStyle(Theme.dusk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // lastScan is in the id so a load skipped because a scan held the slot retries after that scan.
        .task(id: String(describing: model.lastScan)) { await model.loadDashboard() }
    }

    private func range(today: String) -> (start: String?, end: String) {
        if let day = selection.day { return (day, day) }
        guard let lookback = selection.period.lookback else { return (nil, today) }
        let calendar = Calendar.current
        let date = DayKey.date(from: today).flatMap { calendar.date(byAdding: .day, value: -lookback, to: $0) }
        return (date.map { DayKey.string(from: $0) } ?? today, today)
    }

    private func content(_ days: [DayDetail]) -> some View {
        let today = DayKey.string(from: model.now)
        let (start, end) = range(today: today)
        let filter = DashboardFilter(client: selection.client, model: selection.model)
        let board = UsageDashboard(days: days, start: start, end: end, filter: filter)
        // The grid always shows the past year, whatever range is selected, and marks that range.
        let yearBoard = UsageDashboard(days: days, start: nil, end: today, filter: filter)
        let everything = UsageDashboard(days: days, start: nil, end: today)
        let tools = Array(everything.ledger.byClient.prefix(Theme.series.count).map(\.name))
        return VStack(alignment: .leading, spacing: 12) {
            controls()
            MetricsGrid(board: board)
            TrendCard(board: board, hours: model.dashboardHours, tools: tools, selection: $selection)
            ActivityCard(board: board, yearBoard: yearBoard, hours: model.dashboardHours, selection: $selection)
            BreakdownRow(board: board, tools: tools, selection: $selection)
            DetailTable(board: board, tools: tools, selection: $selection)
            Text(l10n("dashboard.source"))
                .font(Theme.pixel())
                .foregroundStyle(Theme.dusk)
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
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.pixel())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Theme.ink : Theme.paper)
                .background(isOn ? Theme.paper : Theme.inkRaised)
        }
        .buttonStyle(.plain)
    }
}

struct ClearChip: View {
    @Environment(\.l10n) private var l10n
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(l10n("filter.chip", title))
                .font(Theme.pixel())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(Theme.paper)
                .pixelBorder(Theme.dusk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n("filter.clear", title))
    }
}

private struct Card<Content: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Theme.paper)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .font(Theme.pixel())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inkRaised.opacity(0.45))
        .pixelBorder(Theme.inkRaised)
    }
}

private func toolColor(_ name: String, tools: [String]) -> Color {
    tools.firstIndex(of: name).map { Theme.series[$0] } ?? Theme.seriesOther
}

struct MetricsGrid: View {
    @Environment(\.l10n) private var l10n
    let board: UsageDashboard

    var body: some View {
        let totals = board.ledger.totals
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                tile(l10n("metric.total"), Format.tokens(totals.total, language: l10n.language), delta(.total))
                tile(l10n("dashboard.estimatedCost"), Format.cost(totals.cost), delta(.cost))
                tile(l10n("dashboard.counted"), Format.km(fuel: totals.fuel), delta(.fuel), Theme.amber)
                tile(l10n("dashboard.cacheHits"), Format.percent(totals.cacheHitPercent), nil)
                tile(l10n("metric.messages"), Format.grouped(totals.messages), delta(.messages))
            }
            GridRow {
                tile(l10n("dashboard.activeDays"), "\(board.activeDays) / \(board.calendarDays)", l10n("dashboard.activeRate", Format.grouped(Int((board.activeRate * 100).rounded()))))
                tile(l10n("dashboard.streak"), l10n.days(board.currentStreak), l10n("dashboard.longest", l10n.language == .zhHans ? Format.grouped(board.longestStreak) : l10n.days(board.longestStreak)))
                tile(l10n("dashboard.sessionTime"), board.activeMs.map(l10n.duration) ?? "-", board.activeMs == nil ? l10n("dashboard.filteredTime") : nil)
                tile(l10n("dashboard.peakDay"), board.peak.map { Format.tokens($0.total, language: l10n.language) } ?? "-", board.peak.map { l10n.day($0.date) })
                tile(l10n("dashboard.topModel"), board.topModel.map(l10n.modelName) ?? "-", nil, Theme.paper, small: true)
            }
        }
    }

    private func delta(_ metric: DashboardMetric) -> String? {
        guard let change = board.change(metric) else { return nil }
        let rounded = Int(change.rounded())
        return rounded == 0 ? l10n("dashboard.unchanged") : l10n("dashboard.delta", "\(rounded > 0 ? "+" : "")\(Format.grouped(rounded))")
    }

    private func tile(_ label: String, _ value: String, _ note: String?, _ color: Color = Theme.paper, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(Theme.dusk)
            Text(value)
                .font(Theme.pixel(small ? 12 : 24))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 24, alignment: .leading)
            Text(note ?? " ").foregroundStyle(Theme.dusk).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.pixel())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.inkRaised)
        .accessibilityElement(children: .combine)
    }
}

struct TrendCard: View {
    @Environment(\.l10n) private var l10n
    let board: UsageDashboard
    let hours: [HourUsage]
    let tools: [String]
    @Binding var selection: DashboardSelection
    @State private var hovered: String?

    private struct Mark: Identifiable {
        var bucket: String
        var series: String
        var value: Double
        var id: String { "\(bucket)-\(series)" }
    }

    var body: some View {
        let metric = selection.metric
        let isSingleDay = board.calendarDays == 1
        let filtered = !board.filter.isEmpty
        let buckets: [TrendBucket] = isSingleDay ? hourBuckets(metric) : board.trend(metric, series: tools)
        let order = tools + [UsageDashboard.otherSeries]
        // Dictionary order would reshuffle the stack from bar to bar.
        let marks = buckets.flatMap { bucket in
            order.compactMap { name in bucket.values[name].map { Mark(bucket: bucket.start, series: name, value: $0) } }
        }
        let present = order.filter { name in marks.contains { $0.series == name } }
        Card(title: isSingleDay ? l10n("trend.hourly") : (buckets.first?.isWeek == true ? l10n("trend.weekly") : l10n("trend.daily"))) {
            ForEach(DashboardMetric.allCases) { item in
                Chip(title: l10n.metric(item), isOn: metric == item) { selection.metric = item }
            }
        } content: {
            readout(buckets, metric: metric)
            if isSingleDay && filtered {
                Text(l10n("trend.clearFilters")).foregroundStyle(Theme.dusk).frame(height: 180)
            } else if isSingleDay && marks.isEmpty {
                Text(l10n("trend.noHours")).foregroundStyle(Theme.dusk).frame(height: 180)
            } else {
                chart(marks: marks, buckets: buckets, order: order, metric: metric, isSingleDay: isSingleDay)
                    .frame(height: 180)
                    .accessibilityLabel(l10n("trend.description", l10n.metric(metric)))
            }
            if !isSingleDay {
                legend(present, marks: marks, metric: metric)
            }
        }
    }

    private func hourBuckets(_ metric: DashboardMetric) -> [TrendBucket] {
        let profile = board.filter.isEmpty ? HourUsage.profile(hours, start: board.start, end: board.end, metric: metric) : []
        return profile.enumerated().map { hour, value in
            TrendBucket(start: String(format: "%02d", hour), isWeek: false, values: value > 0 ? [UsageDashboard.otherSeries: value] : [:])
        }
    }

    private func readout(_ buckets: [TrendBucket], metric: DashboardMetric) -> some View {
        let isHours = board.calendarDays == 1
        let bucket = hovered.flatMap { key in buckets.first { $0.start == key } }
            ?? buckets.max { $0.total < $1.total }
        return HStack(spacing: 12) {
            if let bucket {
                let label = isHours ? l10n.hour(Int(bucket.start)!) : (bucket.isWeek ? l10n("trend.weekOf", l10n.day(bucket.start)) : l10n.day(bucket.start))
                Text(hovered == nil ? l10n("trend.highest", label) : label).foregroundStyle(Theme.dusk)
                Text(metric.format(bucket.total, language: l10n.language)).foregroundStyle(Theme.paper)
                ForEach(bucket.values.sorted { $0.value > $1.value }.prefix(4), id: \.key) { entry in
                    if !isHours {
                        Text(l10n("chart.seriesValue", l10n.series(entry.key), metric.format(entry.value, language: l10n.language)))
                            .foregroundStyle(Theme.dusk)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func chart(marks: [Mark], buckets: [TrendBucket], order: [String], metric: DashboardMetric, isSingleDay: Bool) -> some View {
        let keys = buckets.map(\.start)
        let stride = max(1, keys.count / 8)
        // Offset from the edges, where the first label would be clipped.
        let labels = keys.enumerated().filter { $0.offset % stride == stride / 2 }.map(\.element)
        return Chart(marks) { mark in
            BarMark(x: .value(l10n("chart.time"), mark.bucket), y: .value(l10n.metric(metric), mark.value), width: .ratio(0.7))
                .foregroundStyle(isSingleDay ? Theme.dusk : toolColor(mark.series, tools: tools))
                .opacity(hovered == nil || hovered == mark.bucket ? 1 : 0.45)
        }
        .chartXScale(domain: keys)
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(isSingleDay ? key : l10n.day(key)).font(Theme.pixel()).foregroundStyle(Theme.dusk)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.blockOff)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.format(number, language: l10n.language)).font(Theme.pixel()).foregroundStyle(Theme.dusk)
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

    private func legend(_ present: [String], marks: [Mark], metric: DashboardMetric) -> some View {
        let total = max(marks.reduce(0) { $0 + $1.value }, 0.000_001)
        return HStack(spacing: 12) {
            ForEach(present, id: \.self) { name in
                let value = marks.filter { $0.series == name }.reduce(0) { $0 + $1.value }
                HStack(spacing: 4) {
                    Rectangle().fill(toolColor(name, tools: tools)).frame(width: 8, height: 8)
                    Text(l10n.series(name)).foregroundStyle(Theme.paper)
                    Text(l10n("chart.valueShare", metric.format(value, language: l10n.language), Format.grouped(Int((value / total * 100).rounded())))).foregroundStyle(Theme.dusk)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ActivityCard: View {
    @Environment(\.l10n) private var l10n
    let board: UsageDashboard
    let yearBoard: UsageDashboard
    let hours: [HourUsage]
    @Binding var selection: DashboardSelection
    @State private var hovered: HeatCell?

    var body: some View {
        let metric = selection.metric
        let cells = yearBoard.heatCells(metric: metric)
        Card(title: l10n("dashboard.active")) {
            Text(readoutText(metric)).foregroundStyle(Theme.dusk).lineLimit(1)
        } content: {
            HeatGrid(cells: cells, rangeStart: board.start, rangeEnd: board.end, hovered: $hovered) { selection.day = $0 }
                .accessibilityLabel(l10n("activity.description", Format.grouped(cells.filter { $0.level > 0 }.count)))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(board.filter.isEmpty ? l10n("activity.hours") : l10n("activity.filteredHours")).foregroundStyle(Theme.dusk)
                    MiniBars(values: hourProfile(metric), labels: ["0", "6", "12", "18"], every: 6) { "\(l10n.hour($0)) \(metric.format($1, language: l10n.language))" }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n("activity.weekday")).foregroundStyle(Theme.dusk)
                    MiniBars(values: board.weekdayProfile(metric), labels: l10n.weekdays, every: 1) { index, value in
                        "\(l10n.weekday(index)) \(metric.format(value, language: l10n.language))"
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity)
            }
        }
    }

    private func hourProfile(_ metric: DashboardMetric) -> [Double] {
        board.filter.isEmpty ? HourUsage.profile(hours, start: board.start, end: board.end, metric: metric) : []
    }

    private func readoutText(_ metric: DashboardMetric) -> String {
        if let hovered { return "\(l10n.day(hovered.date, full: true)) · \(hovered.value > 0 ? metric.format(hovered.value, language: l10n.language) : l10n("activity.noUsage"))" }
        return l10n("activity.help")
    }
}

/// One Canvas instead of 371 hit-tested views, so hovering stays cheap.
struct HeatGrid: View {
    @Environment(\.l10n) private var l10n
    let cells: [HeatCell]
    let rangeStart: String
    let rangeEnd: String
    @Binding var hovered: HeatCell?
    var onSelect: (String) -> Void

    private static let gap: CGFloat = 2
    private static let rows: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let weeks = CGFloat((cells.map(\.week).max() ?? 0) + 1)
            let size = max(4, ((proxy.size.width - 20) / weeks).rounded(.down) - Self.gap)
            let pitch = size + Self.gap
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cell in cells {
                        let rect = CGRect(x: 20 + CGFloat(cell.week) * pitch, y: 16 + CGFloat(cell.weekday) * pitch, width: size, height: size)
                        let inRange = cell.date >= rangeStart && cell.date <= rangeEnd
                        context.fill(Path(rect), with: .color(Theme.heat[cell.level].opacity(inRange ? 1 : 0.4)))
                    }
                }
                ForEach(monthLabels(), id: \.week) { label in
                    Text(label.text).foregroundStyle(Theme.dusk).offset(x: 20 + CGFloat(label.week) * pitch, y: -2)
                }
                ForEach(Array([l10n.weekdays[0], l10n.weekdays[2], l10n.weekdays[4]].enumerated()), id: \.offset) { index, name in
                    Text(name).foregroundStyle(Theme.dusk).offset(x: 0, y: 16 + CGFloat(index * 2) * pitch - 2)
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
        let week = Int((point.x - 20) / pitch)
        let weekday = Int((point.y - 16) / pitch)
        guard point.x >= 20, point.y >= 16 else { return nil }
        return cells.first { $0.week == week && $0.weekday == weekday }
    }

    private func monthLabels() -> [(week: Int, text: String)] {
        var labels: [(week: Int, text: String)] = []
        var lastMonth = ""
        for cell in cells where cell.weekday == 0 {
            let month = String(cell.date.dropFirst(5).prefix(2))
            if month != lastMonth {
                if !lastMonth.isEmpty || cell.week == 0 { labels.append((cell.week, l10n.month(Int(month)!))) }
                lastMonth = month
            }
        }
        // The first label is usually a partial month and would collide with the next.
        if labels.count > 1, labels[1].week - labels[0].week < 3 { labels.removeFirst() }
        return labels
    }
}

struct MiniBars: View {
    let values: [Double]
    let labels: [String]
    let every: Int
    var describe: (Int, Double) -> String
    @State private var hovered: Int?

    var body: some View {
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
                        .fill(hovered == index ? Theme.paper : Theme.dusk)
                        .frame(height: value > 0 ? max(2, (CGFloat(value / top) * 48).rounded()) : 1)
                        .frame(maxWidth: .infinity, maxHeight: 48, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                        .accessibilityLabel(describe(index, value))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(label).foregroundStyle(Theme.dusk).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(hovered.flatMap { values.indices.contains($0) ? describe($0, values[$0]) : nil } ?? " ")
                .foregroundStyle(Theme.dusk)
                .lineLimit(1)
        }
    }
}

struct BreakdownRow: View {
    @Environment(\.l10n) private var l10n
    let board: UsageDashboard
    let tools: [String]
    @Binding var selection: DashboardSelection

    var body: some View {
        let ledger = board.ledger
        let totals = ledger.totals
        HStack(alignment: .top, spacing: 8) {
            Card(title: l10n("breakdown.tools")) { EmptyView() } content: {
                ranked(ledger.byClient.prefix(6).map { ($0.name, Vehicle.toolName($0.name), $0.tokens.total, toolColor($0.name, tools: tools)) }, total: totals.total, isOn: { selection.client == $0 }) { name in
                    selection.client = selection.client == name ? nil : name
                }
            }
            Card(title: l10n("breakdown.models")) { EmptyView() } content: {
                ranked(ledger.byModel.prefix(6).map { ($0.name, l10n.modelName($0.name), $0.tokens.total, Theme.dusk) }, total: totals.total, isOn: { selection.model == $0 }) { name in
                    selection.model = selection.model == name ? nil : name
                }
            }
            Card(title: l10n("breakdown.composition")) { EmptyView() } content: {
                ranked([
                    (l10n("usage.cacheRead"), l10n("usage.cacheRead"), totals.cacheRead, Theme.dusk), (l10n("usage.input"), l10n("usage.input"), totals.input, Theme.dusk),
                    (l10n("usage.cacheWrite"), l10n("usage.cacheWrite"), totals.cacheWrite, Theme.dusk), (l10n("usage.output"), l10n("usage.output"), totals.output, Theme.dusk),
                    (l10n("usage.reasoning"), l10n("usage.reasoning"), totals.reasoning, Theme.dusk),
                ], total: totals.total, isOn: { _ in false }, action: nil)
            }
        }
    }

    private func ranked(_ rows: [(id: String, label: String, value: Int, color: Color)], total: Int, isOn: @escaping (String) -> Bool, action: ((String) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty { Text(l10n("usage.empty")).foregroundStyle(Theme.dusk) }
            ForEach(rows, id: \.id) { row in
                let share = total > 0 ? Double(row.value) / Double(total) : 0
                let line = VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.label)
                            .foregroundStyle(isOn(row.id) ? Theme.ink : Theme.paper)
                            .background(isOn(row.id) ? Theme.paper : .clear)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.tokens(row.value, language: l10n.language)).foregroundStyle(Theme.paper).lineLimit(1).layoutPriority(1)
                        Text(String(format: "%.1f%%", share * 100)).foregroundStyle(Theme.dusk).lineLimit(1).frame(width: 46, alignment: .trailing).layoutPriority(1)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.blockOff)
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

struct DetailTable: View {
    @Environment(\.l10n) private var l10n
    let board: UsageDashboard
    let tools: [String]
    @Binding var selection: DashboardSelection

    var body: some View {
        let showModels = selection.showModels
        let entries = showModels ? board.ledger.byModel : board.ledger.byClient
        Card(title: l10n("dashboard.details")) {
            Chip(title: l10n("dashboard.tools"), isOn: !showModels) { selection.showModels = false }
            Chip(title: l10n("dashboard.models"), isOn: showModels) { selection.showModels = true }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                row(showModels ? l10n("dashboard.models") : l10n("dashboard.tools"), [l10n("metric.total"), l10n("usage.input"), l10n("usage.output"), l10n("table.cacheRead"), l10n("table.cacheWrite"), l10n("table.hit"), l10n("metric.cost"), l10n("metric.messages")], color: Theme.dusk)
                Rectangle().fill(Theme.blockOff).frame(height: 2)
                if entries.isEmpty { Text(l10n("usage.empty")).foregroundStyle(Theme.dusk) }
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
                        ], color: Theme.paper)
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
