import Foundation

public enum DashboardMetric: String, CaseIterable, Identifiable, Sendable {
    case total, fuel, cost, messages
    public var id: String { rawValue }

    public func value(_ tokens: UsageTotals) -> Double {
        switch self {
        case .total: Double(tokens.total)
        case .fuel: Double(tokens.total) / Double(outboundTokensPerKm)
        case .cost: tokens.cost
        case .messages: Double(tokens.messages)
        }
    }

    public func format(_ value: Double, language: Language) -> String {
        switch self {
        case .total: Format.tokens(Int(value.rounded()), language: language)
        case .fuel: Format.km(value)
        case .cost: Format.cost(value)
        case .messages: Format.grouped(Int(value.rounded()))
        }
    }
}

public struct DashboardFilter: Hashable, Sendable {
    public var client: String?
    public var model: String?

    public init(client: String? = nil, model: String? = nil) {
        self.client = client
        self.model = model
    }

    public var isEmpty: Bool { client == nil && model == nil }

    func matches(_ row: UsageRow) -> Bool {
        (client == nil || client == row.client) && (model == nil || model == row.model)
    }
}

public struct TrendBucket: Equatable, Sendable, Identifiable {
    public var start: String
    public var isWeek: Bool
    public var values: [String: Double]
    public var id: String { start }

    public init(start: String, isWeek: Bool, values: [String: Double]) {
        self.start = start
        self.isWeek = isWeek
        self.values = values
    }

    public var total: Double { values.keys.sorted().reduce(0) { $0 + values[$1]! } }
}

public struct HeatCell: Equatable, Sendable, Identifiable {
    public var date: String
    public var week: Int
    /// 0 is Monday.
    public var weekday: Int
    public var value: Double
    /// 0 for no use, then 1...4 by quartile of the visible active days, so one huge day cannot flatten the rest.
    public var level: Int
    public var id: String { date }
}

/// Derives everything the dashboard shows from daily detail. Display-only: nothing here reaches the journey.
public struct UsageDashboard: Sendable {
    public static let otherSeries = "\u{0}voyage.other"

    public let start: String
    public let end: String
    public let filter: DashboardFilter
    public let ledger: UsageLedger
    public let previous: UsageLedger?
    public let calendarDays: Int
    public let activeDays: Int
    public let currentStreak: Int
    public let longestStreak: Int
    /// nil while filtered, because session time is not split per tool.
    public let activeMs: Int?
    public let peak: (date: String, total: Int)?

    private let days: [Int: DayDetail]
    private let calendar: Calendar
    private let firstDay: Int
    private let lastDay: Int

    /// `start` nil means from the first recorded day. Ranges of a week or more compare against the range before them.
    public init(days allDays: [DayDetail], start: String?, end: String, filter: DashboardFilter = DashboardFilter(), calendar: Calendar = .current) {
        let measurementStart = DashboardMeasurementCounters.start()
        defer { DashboardMeasurementCounters.record(.usageDashboardInit, since: measurementStart) }
        let cleaned = allDays.map { day in
            DayDetail(date: day.date, rows: day.rows.filter(filter.matches), activeMs: day.activeMs)
        }
        let first = start ?? allDays.map(\.date).filter { $0 <= end }.min() ?? end
        let inRange = cleaned.filter { $0.date >= first && $0.date <= end }
        let isActive: (DayDetail) -> Bool = { day in day.rows.contains { $0.tokens.total > 0 } }
        let indexed = cleaned.compactMap { day in
            DayKey.ordinal(from: day.date, calendar: calendar).map { ($0, day) }
        }
        let activeDates = Set(indexed.filter { isActive($0.1) }.map(\.0))
        guard let firstDay = DayKey.ordinal(from: first, calendar: calendar),
              let lastDay = DayKey.ordinal(from: end, calendar: calendar) else {
            preconditionFailure("Invalid dashboard range")
        }

        self.start = first
        self.end = end
        self.filter = filter
        self.calendar = calendar
        self.days = Dictionary(indexed, uniquingKeysWith: { _, latest in latest })
        self.firstDay = firstDay
        self.lastDay = lastDay
        ledger = UsageLedger(days: inRange)

        let count = max(0, lastDay - firstDay + 1)
        calendarDays = count
        activeDays = inRange.filter(isActive).count
        activeMs = filter.isEmpty ? inRange.reduce(0) { $0 + $1.activeMs } : nil
        peak = inRange.filter(isActive)
            .map { (date: $0.date, total: $0.rows.reduce(UsageTotals()) { $0 + $1.tokens }.total) }
            .max { $0.total == $1.total ? $0.date > $1.date : $0.total < $1.total }

        if start != nil, count >= 7 {
            let lower = DayKey.string(forOrdinal: firstDay - count, calendar: calendar)
            previous = UsageLedger(days: cleaned.filter { $0.date >= lower && $0.date < first })
        } else {
            previous = nil
        }

        // A streak survives today having no use yet; it ends at the last gap.
        var streak = 0
        var cursor = lastDay
        if !activeDates.contains(cursor) { cursor -= 1 }
        while activeDates.contains(cursor) {
            streak += 1
            cursor -= 1
        }
        currentStreak = streak

        var longest = 0
        var running = 0
        for offset in 0..<count {
            running = activeDates.contains(firstDay + offset) ? running + 1 : 0
            longest = max(longest, running)
        }
        longestStreak = longest
    }

    public var topModel: String? { ledger.byModel.first?.name }
    public var activeRate: Double { calendarDays > 0 ? Double(activeDays) / Double(calendarDays) : 0 }

    public func change(_ metric: DashboardMetric) -> Double? {
        guard let previous else { return nil }
        let before = metric.value(previous.totals)
        return before > 0 ? (metric.value(ledger.totals) / before - 1) * 100 : nil
    }

    /// Daily up to 90 days, then Monday-based weeks. Clients outside `series` fold into `otherSeries`.
    public func trend(_ metric: DashboardMetric, series: [String]) -> [TrendBucket] {
        let weekly = calendarDays > 90
        var buckets: [TrendBucket] = []
        var key = weekly ? monday(of: firstDay) : firstDay
        while key <= lastDay {
            let span = weekly ? 7 : 1
            var values: [String: Double] = [:]
            var day = key
            for _ in 0..<span {
                if day >= firstDay, day <= lastDay {
                    for row in days[day]?.rows ?? [] {
                        let value = metric.value(row.tokens)
                        guard value > 0 else { continue }
                        values[series.contains(row.client) ? row.client : Self.otherSeries, default: 0] += value
                    }
                }
                day += 1
            }
            buckets.append(TrendBucket(start: DayKey.string(forOrdinal: key, calendar: calendar), isWeek: weekly, values: values))
            key = day
        }
        return buckets
    }

    /// The weeks up to `end`, starting on a Monday, for the activity grid.
    public func heatCells(metric: DashboardMetric, weeks: Int = 53) -> [HeatCell] {
        let firstMonday = monday(of: lastDay) - 7 * (weeks - 1)
        var cells: [HeatCell] = []
        var key = firstMonday
        var index = 0
        while key <= lastDay {
            let value = (days[key]?.rows ?? []).reduce(0) { $0 + metric.value($1.tokens) }
            cells.append(HeatCell(date: DayKey.string(forOrdinal: key, calendar: calendar), week: index / 7, weekday: index % 7, value: value, level: 0))
            key += 1
            index += 1
        }
        let sorted = cells.map(\.value).filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return cells }
        let cut = { (fraction: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        let (q1, q2, q3) = (cut(0.25), cut(0.5), cut(0.75))
        return cells.map { cell in
            var cell = cell
            if cell.value > 0 { cell.level = cell.value < q1 ? 1 : cell.value < q2 ? 2 : cell.value < q3 ? 3 : 4 }
            return cell
        }
    }

    /// Sums per weekday across the range, Monday first.
    public func weekdayProfile(_ metric: DashboardMetric) -> [Double] {
        var totals = [Double](repeating: 0, count: 7)
        for date in days.keys.sorted() where date >= firstDay && date <= lastDay {
            let day = days[date]!
            let parsed = DayKey.date(forOrdinal: date, calendar: calendar)
            let index = (calendar.component(.weekday, from: parsed) + 5) % 7
            totals[index] += day.rows.reduce(0) { $0 + metric.value($1.tokens) }
        }
        return totals
    }

    private func monday(of key: Int) -> Int {
        let date = DayKey.date(forOrdinal: key, calendar: calendar)
        let back = (calendar.component(.weekday, from: date) + 5) % 7
        return key - back
    }
}

public struct HourUsage: Equatable, Sendable {
    public var date: String
    public var hour: Int
    public var tokens: UsageTotals

    public init(date: String, hour: Int, tokens: UsageTotals) {
        self.date = date
        self.hour = hour
        self.tokens = tokens
    }

    /// Sums per hour of day across the range. tokscale reports hours across all tools, so this cannot be filtered per tool.
    public static func profile(_ hours: [HourUsage], start: String, end: String, metric: DashboardMetric) -> [Double] {
        var totals = [Double](repeating: 0, count: 24)
        for entry in hours where entry.date >= start && entry.date <= end && (0..<24).contains(entry.hour) {
            totals[entry.hour] += metric.value(entry.tokens)
        }
        return totals
    }
}

public enum TokscaleHourly {
    private struct Report: Decodable {
        let entries: [Entry]
    }

    private struct Entry: Decodable {
        let hour: String
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let messageCount: Int?
        let cost: Double?
    }

    public static func parse(_ data: Data) throws -> [HourUsage] {
        try JSONDecoder().decode(Report.self, from: data).entries.compactMap { entry in
            let parts = entry.hour.split(separator: " ")
            guard parts.count == 2, let hour = Int(parts[1].prefix(2)) else { return nil }
            return HourUsage(
                date: String(parts[0]),
                hour: hour,
                tokens: UsageTotals(
                    input: entry.input ?? 0, output: entry.output ?? 0, cacheRead: entry.cacheRead ?? 0,
                    cacheWrite: entry.cacheWrite ?? 0, cost: entry.cost ?? 0, messages: entry.messageCount ?? 0
                )
            )
        }
    }
}
