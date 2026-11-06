import Foundation
@testable import VoyageCore

// Frozen pre-optimization calculation for synthetic-data parity checks.
struct ReferenceDashboard: Sendable {
    static let otherSeries = "\u{0}voyage.other"

    let start: String
    let end: String
    let filter: DashboardFilter
    let ledger: UsageLedger
    let previous: UsageLedger?
    let calendarDays: Int
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    /// nil while filtered, because session time is not split per tool.
    let activeMs: Int?
    let peak: (date: String, total: Int)?

    private let days: [String: DayDetail]
    private let calendar: Calendar

    /// `start` nil means from the first recorded day. Ranges of a week or more compare against the range before them.
    init(days allDays: [DayDetail], start: String?, end: String, filter: DashboardFilter = DashboardFilter(), calendar: Calendar = .current) {
        let measurementStart = DashboardMeasurementCounters.start()
        defer { DashboardMeasurementCounters.record(.usageDashboardInit, since: measurementStart) }
        let cleaned = allDays.map { day in
            DayDetail(date: day.date, rows: day.rows.filter(filter.matches), activeMs: day.activeMs)
        }
        let first = start ?? allDays.map(\.date).filter { $0 <= end }.min() ?? end
        let inRange = cleaned.filter { $0.date >= first && $0.date <= end }
        let isActive: (DayDetail) -> Bool = { day in day.rows.contains { $0.tokens.total > 0 } }
        let activeDates = Set(cleaned.filter(isActive).map(\.date))

        self.start = first
        self.end = end
        self.filter = filter
        self.calendar = calendar
        self.days = Dictionary(cleaned.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
        ledger = UsageLedger(days: inRange)

        let count = Self.dayCount(from: first, to: end, calendar: calendar)
        calendarDays = count
        activeDays = inRange.filter(isActive).count
        activeMs = filter.isEmpty ? inRange.reduce(0) { $0 + $1.activeMs } : nil
        peak = inRange.filter(isActive)
            .map { (date: $0.date, total: $0.rows.reduce(UsageTotals()) { $0 + $1.tokens }.total) }
            .max { $0.total == $1.total ? $0.date > $1.date : $0.total < $1.total }

        if start != nil, count >= 7,
           let firstDate = DayKey.date(from: first, calendar: calendar),
           let previousStart = calendar.date(byAdding: .day, value: -count, to: firstDate) {
            let lower = DayKey.string(from: previousStart, calendar: calendar)
            previous = UsageLedger(days: cleaned.filter { $0.date >= lower && $0.date < first })
        } else {
            previous = nil
        }

        // A streak survives today having no use yet; it ends at the last gap.
        var streak = 0
        var cursor = DayKey.date(from: end, calendar: calendar)
        if let date = cursor, !activeDates.contains(DayKey.string(from: date, calendar: calendar)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: date)
        }
        while let date = cursor, activeDates.contains(DayKey.string(from: date, calendar: calendar)) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: date)
        }
        currentStreak = streak

        var longest = 0
        var running = 0
        var key = first
        for _ in 0..<count {
            running = activeDates.contains(key) ? running + 1 : 0
            longest = max(longest, running)
            key = DayKey.next(key, calendar: calendar)
        }
        longestStreak = longest
    }

    var topModel: String? { ledger.byModel.first?.name }
    var activeRate: Double { calendarDays > 0 ? Double(activeDays) / Double(calendarDays) : 0 }

    func change(_ metric: DashboardMetric) -> Double? {
        guard let previous else { return nil }
        let before = metric.value(previous.totals)
        return before > 0 ? (metric.value(ledger.totals) / before - 1) * 100 : nil
    }

    /// Daily up to 90 days, then Monday-based weeks. Clients outside `series` fold into `otherSeries`.
    func trend(_ metric: DashboardMetric, series: [String]) -> [TrendBucket] {
        let weekly = calendarDays > 90
        var buckets: [TrendBucket] = []
        var key = weekly ? monday(of: start) : start
        while key <= end {
            let span = weekly ? 7 : 1
            var values: [String: Double] = [:]
            var day = key
            for _ in 0..<span {
                if day >= start, day <= end {
                    for row in days[day]?.rows ?? [] {
                        let value = metric.value(row.tokens)
                        guard value > 0 else { continue }
                        values[series.contains(row.client) ? row.client : Self.otherSeries, default: 0] += value
                    }
                }
                day = DayKey.next(day, calendar: calendar)
            }
            buckets.append(TrendBucket(start: key, isWeek: weekly, values: values))
            key = day
        }
        return buckets
    }

    /// The weeks up to `end`, starting on a Monday, for the activity grid.
    func heatCells(metric: DashboardMetric, weeks: Int = 53) -> [HeatCell] {
        guard let endDate = DayKey.date(from: monday(of: end), calendar: calendar),
              let firstMonday = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: endDate) else { return [] }
        var cells: [HeatCell] = []
        var key = DayKey.string(from: firstMonday, calendar: calendar)
        var index = 0
        while key <= end {
            let value = (days[key]?.rows ?? []).reduce(0) { $0 + metric.value($1.tokens) }
            cells.append(HeatCell(date: key, week: index / 7, weekday: index % 7, value: value, level: 0))
            key = DayKey.next(key, calendar: calendar)
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
    func weekdayProfile(_ metric: DashboardMetric) -> [Double] {
        var totals = [Double](repeating: 0, count: 7)
        for (date, day) in days where date >= start && date <= end {
            guard let parsed = DayKey.date(from: date, calendar: calendar) else { continue }
            let index = (calendar.component(.weekday, from: parsed) + 5) % 7
            totals[index] += day.rows.reduce(0) { $0 + metric.value($1.tokens) }
        }
        return totals
    }

    private func monday(of key: String) -> String {
        guard let date = DayKey.date(from: key, calendar: calendar) else { preconditionFailure("Invalid day key \(key)") }
        let back = (calendar.component(.weekday, from: date) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -back, to: date) else { preconditionFailure("Invalid day key \(key)") }
        return DayKey.string(from: monday, calendar: calendar)
    }

    private static func dayCount(from start: String, to end: String, calendar: Calendar) -> Int {
        guard let first = DayKey.date(from: start, calendar: calendar), let last = DayKey.date(from: end, calendar: calendar) else { return 0 }
        return max(0, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
    }
}

