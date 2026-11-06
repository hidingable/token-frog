import Charts
import SwiftUI
import VoyageCore

enum DashboardPeriod: String, CaseIterable, Identifiable {
    case today = "今天", week = "7 天", month = "30 天", quarter = "90 天", year = "1 年", all = "全部"
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
    let model: AppModel
    @Binding var selection: DashboardSelection

    var body: some View {
        Group {
            if let days = model.dashboardDays {
                content(days)
            } else if model.lastError == nil {
                Text("正在统计……").font(Theme.pixel()).foregroundStyle(Theme.dusk)
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
            Text("数据来自本机 tokscale · 费用为估算 · 会话时长是各会话累加，并行时一天可超过 24 小时")
                .font(Theme.pixel())
                .foregroundStyle(Theme.dusk)
        }
    }

    private func controls() -> some View {
        HStack(spacing: 4) {
            ForEach(DashboardPeriod.allCases) { item in
                Chip(title: item.rawValue, isOn: selection.day == nil && selection.period == item) {
                    selection.period = item
                    selection.day = nil
                }
            }
            Spacer(minLength: 8)
            if let day = selection.day {
                ClearChip(title: day) { selection.day = nil }
            }
            if let client = selection.client {
                ClearChip(title: Vehicle.toolName(client)) { selection.client = nil }
            }
            if let name = selection.model {
                ClearChip(title: name) { selection.model = nil }
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
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) ✕")
                .font(Theme.pixel())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(Theme.paper)
                .pixelBorder(Theme.dusk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除筛选 \(title)")
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

private func shortDate(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
    return "\(month)/\(day)"
}

private func duration(_ ms: Int) -> String {
    let minutes = ms / 60_000
    if minutes < 60 { return "\(minutes) 分" }
    return "\(Format.grouped(minutes / 60)) 时"
}

struct MetricsGrid: View {
    let board: UsageDashboard

    var body: some View {
        let totals = board.ledger.totals
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
        LazyVGrid(columns: columns, spacing: 4) {
            tile("总量", Format.tokens(totals.total), delta(.total))
            tile("费用（估算）", Format.cost(totals.cost), delta(.cost))
            tile("计入里程", Format.km(fuel: totals.fuel), delta(.fuel), Theme.amber)
            tile("缓存命中", Format.percent(totals.cacheHitPercent), nil)
            tile("消息", Format.grouped(totals.messages), delta(.messages))
            tile("活跃天数", "\(board.activeDays) / \(board.calendarDays)", "活跃率 \(Int((board.activeRate * 100).rounded()))%")
            tile("当前连续", "\(board.currentStreak) 天", "区间最长 \(board.longestStreak) 天")
            tile("会话时长", board.activeMs.map(duration) ?? "-", board.activeMs == nil ? "筛选时不可用" : nil)
            tile("峰值日", board.peak.map { Format.tokens($0.total) } ?? "-", board.peak.map { shortDate($0.date) })
            tile("主力模型", board.topModel ?? "-", nil, Theme.paper, small: true)
        }
    }

    private func delta(_ metric: DashboardMetric) -> String? {
        guard let change = board.change(metric) else { return nil }
        let rounded = Int(change.rounded())
        return rounded == 0 ? "与上期持平" : "较上期 \(rounded > 0 ? "+" : "")\(Format.grouped(rounded))%"
    }

    private func tile(_ label: String, _ value: String, _ note: String?, _ color: Color = Theme.paper, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(Theme.dusk)
            Text(value)
                .font(Theme.pixel(small ? 12 : 24))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minHeight: 24, alignment: .leading)
            Text(note ?? " ").foregroundStyle(Theme.dusk).lineLimit(1)
        }
        .font(Theme.pixel())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inkRaised)
        .accessibilityElement(children: .combine)
    }
}

struct TrendCard: View {
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
        Card(title: isSingleDay ? "当天每小时" : (buckets.first?.isWeek == true ? "趋势 · 每周" : "趋势 · 每天")) {
            ForEach(DashboardMetric.allCases) { item in
                Chip(title: item.rawValue, isOn: metric == item) { selection.metric = item }
            }
        } content: {
            readout(buckets, metric: metric)
            if isSingleDay && filtered {
                Text("每小时数据不区分工具，清除筛选后可看").foregroundStyle(Theme.dusk).frame(height: 180)
            } else if isSingleDay && marks.isEmpty {
                Text("这一天没有每小时数据（只保留最近 30 天）").foregroundStyle(Theme.dusk).frame(height: 180)
            } else {
                chart(marks: marks, buckets: buckets, order: order, metric: metric, isSingleDay: isSingleDay)
                    .frame(height: 180)
                    .accessibilityLabel("\(metric.rawValue)趋势")
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
                let label = isHours ? "\(bucket.start):00" : (bucket.isWeek ? "\(shortDate(bucket.start)) 这周" : shortDate(bucket.start))
                Text(hovered == nil ? "最高 \(label)" : label).foregroundStyle(Theme.dusk)
                Text(metric.format(bucket.total)).foregroundStyle(Theme.paper)
                ForEach(bucket.values.sorted { $0.value > $1.value }.prefix(4), id: \.key) { entry in
                    if !isHours {
                        Text("\(entry.key == UsageDashboard.otherSeries ? entry.key : Vehicle.toolName(entry.key)) \(metric.format(entry.value))")
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
            BarMark(x: .value("时间", mark.bucket), y: .value(metric.rawValue, mark.value), width: .ratio(0.7))
                .foregroundStyle(isSingleDay ? Theme.dusk : toolColor(mark.series, tools: tools))
                .opacity(hovered == nil || hovered == mark.bucket ? 1 : 0.45)
        }
        .chartXScale(domain: keys)
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(isSingleDay ? key : shortDate(key)).font(Theme.pixel()).foregroundStyle(Theme.dusk)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.blockOff)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.format(number)).font(Theme.pixel()).foregroundStyle(Theme.dusk)
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
                    Text(name == UsageDashboard.otherSeries ? name : Vehicle.toolName(name)).foregroundStyle(Theme.paper)
                    Text("\(metric.format(value)) · \(Int((value / total * 100).rounded()))%").foregroundStyle(Theme.dusk)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ActivityCard: View {
    let board: UsageDashboard
    let yearBoard: UsageDashboard
    let hours: [HourUsage]
    @Binding var selection: DashboardSelection
    @State private var hovered: HeatCell?

    var body: some View {
        let metric = selection.metric
        let cells = yearBoard.heatCells(metric: metric)
        Card(title: "活跃") {
            Text(readoutText(metric)).foregroundStyle(Theme.dusk).lineLimit(1)
        } content: {
            HeatGrid(cells: cells, rangeStart: board.start, rangeEnd: board.end, hovered: $hovered) { selection.day = $0 }
                .accessibilityLabel("过去一年的每日活跃，\(cells.filter { $0.level > 0 }.count) 天有使用")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(board.filter.isEmpty ? "时段（最近 30 天内）" : "时段（清除筛选后可看）").foregroundStyle(Theme.dusk)
                    MiniBars(values: hourProfile(metric), labels: ["0", "6", "12", "18"], every: 6) { "\($0):00 \(metric.format($1))" }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("星期").foregroundStyle(Theme.dusk)
                    MiniBars(values: board.weekdayProfile(metric), labels: ["一", "二", "三", "四", "五", "六", "日"], every: 1) { index, value in
                        "周\(["一", "二", "三", "四", "五", "六", "日"][index]) \(metric.format(value))"
                    }
                }
                .frame(width: 200)
            }
        }
    }

    private func hourProfile(_ metric: DashboardMetric) -> [Double] {
        board.filter.isEmpty ? HourUsage.profile(hours, start: board.start, end: board.end, metric: metric) : []
    }

    private func readoutText(_ metric: DashboardMetric) -> String {
        if let hovered { return "\(hovered.date) · \(hovered.value > 0 ? metric.format(hovered.value) : "没有使用")" }
        return "过去一年，亮的是所选范围 · 点一天可看当天明细"
    }
}

/// One Canvas instead of 371 hit-tested views, so hovering stays cheap.
struct HeatGrid: View {
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
                ForEach(Array(["一", "三", "五"].enumerated()), id: \.offset) { index, name in
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
                if !lastMonth.isEmpty || cell.week == 0 { labels.append((cell.week, "\(Int(month) ?? 0)月")) }
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
    let board: UsageDashboard
    let tools: [String]
    @Binding var selection: DashboardSelection

    var body: some View {
        let ledger = board.ledger
        let totals = ledger.totals
        HStack(alignment: .top, spacing: 8) {
            Card(title: "按工具") { EmptyView() } content: {
                ranked(ledger.byClient.prefix(6).map { ($0.name, Vehicle.toolName($0.name), $0.tokens.total, toolColor($0.name, tools: tools)) }, total: totals.total, isOn: { selection.client == $0 }) { name in
                    selection.client = selection.client == name ? nil : name
                }
            }
            Card(title: "按模型") { EmptyView() } content: {
                ranked(ledger.byModel.prefix(6).map { ($0.name, $0.name, $0.tokens.total, Theme.dusk) }, total: totals.total, isOn: { selection.model == $0 }) { name in
                    selection.model = selection.model == name ? nil : name
                }
            }
            Card(title: "构成") { EmptyView() } content: {
                ranked([
                    ("缓存读取", "缓存读取", totals.cacheRead, Theme.dusk), ("输入", "输入", totals.input, Theme.dusk),
                    ("缓存写入", "缓存写入", totals.cacheWrite, Theme.dusk), ("输出", "输出", totals.output, Theme.dusk),
                    ("推理", "推理", totals.reasoning, Theme.dusk),
                ], total: totals.total, isOn: { _ in false }, action: nil)
            }
        }
    }

    private func ranked(_ rows: [(id: String, label: String, value: Int, color: Color)], total: Int, isOn: @escaping (String) -> Bool, action: ((String) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty { Text("暂无用量").foregroundStyle(Theme.dusk) }
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
                        Text(Format.tokens(row.value)).foregroundStyle(Theme.paper).lineLimit(1).layoutPriority(1)
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
                        .accessibilityValue(isOn(row.id) ? "已筛选" : "")
                } else {
                    line
                }
            }
        }
    }
}

struct DetailTable: View {
    let board: UsageDashboard
    let tools: [String]
    @Binding var selection: DashboardSelection

    var body: some View {
        let showModels = selection.showModels
        let entries = showModels ? board.ledger.byModel : board.ledger.byClient
        Card(title: "明细") {
            Chip(title: "工具", isOn: !showModels) { selection.showModels = false }
            Chip(title: "模型", isOn: showModels) { selection.showModels = true }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                row(showModels ? "模型" : "工具", ["总量", "输入", "输出", "缓存读", "缓存写", "命中", "费用", "消息"], color: Theme.dusk)
                Rectangle().fill(Theme.blockOff).frame(height: 2)
                if entries.isEmpty { Text("暂无用量").foregroundStyle(Theme.dusk) }
                ForEach(entries) { entry in
                    let tokens = entry.tokens
                    Button {
                        if showModels {
                            selection.model = selection.model == entry.name ? nil : entry.name
                        } else {
                            selection.client = selection.client == entry.name ? nil : entry.name
                        }
                    } label: {
                        row(showModels ? entry.name : Vehicle.toolName(entry.name), [
                            Format.tokens(tokens.total), Format.tokens(tokens.input), Format.tokens(tokens.output),
                            Format.tokens(tokens.cacheRead), Format.tokens(tokens.cacheWrite),
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
                Text(cell).lineLimit(1).frame(width: 62, alignment: .trailing)
            }
        }
        .foregroundStyle(color)
    }
}
