import Foundation
import Observation
import VoyageCore

struct DashboardRefresh: Hashable {
    let version: Int
    let today: String
    let selection: DashboardSelection
    let seriesLimit: Int
    let calendar = Calendar.current

    init(version: Int, today: String, selection: DashboardSelection, seriesLimit: Int) {
        self.version = version
        self.today = today
        var calculation = selection
        calculation.showModels = false
        self.selection = calculation
        self.seriesLimit = seriesLimit
    }
}

struct DashboardRequest: Hashable, Sendable {
    let version: Int
    let today: String
    let start: String?
    let end: String
    let filter: DashboardFilter
    let metric: DashboardMetric
    let seriesLimit: Int
    let calendar: Calendar
}

struct DashboardInput: Sendable {
    let days: [DayDetail]
    let hours: [HourUsage]
}

/// Only the values consumed by the metric tiles participate in SwiftUI equality.
struct DashboardStats: Equatable, Sendable {
    struct Peak: Equatable, Sendable { let date: String; let total: Int }
    let totals: UsageTotals
    let previous: UsageTotals?
    let calendarDays: Int
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    let activeMs: Int?
    let peak: Peak?
    let topModel: String?
    var activeRate: Double { calendarDays > 0 ? Double(activeDays) / Double(calendarDays) : 0 }

    init(_ board: UsageDashboard) {
        totals = board.ledger.totals
        previous = board.previous?.totals
        calendarDays = board.calendarDays
        activeDays = board.activeDays
        currentStreak = board.currentStreak
        longestStreak = board.longestStreak
        activeMs = board.activeMs
        peak = board.peak.map { Peak(date: $0.date, total: $0.total) }
        topModel = board.topModel
    }

    func change(_ metric: DashboardMetric) -> Double? {
        guard let previous else { return nil }
        let before = metric.value(previous)
        return before > 0 ? (metric.value(totals) / before - 1) * 100 : nil
    }
}

struct DashboardTrend: Equatable, Sendable {
    struct Mark: Equatable, Sendable, Identifiable {
        let bucket: String
        let series: String
        let value: Double
        var id: String { "\(bucket)-\(series)" }
    }
    struct Series: Equatable, Sendable {
        let name: String
        let value: Double
    }
    struct Readout: Equatable, Sendable {
        let start: String
        let isWeek: Bool
        let total: Double
        let series: [Series]
    }
    let buckets: [TrendBucket]
    let marks: [Mark]
    let keys: [String]
    let labels: [String]
    let legend: [Series]
    let legendTotal: Double
    let readouts: [String: Readout]
    let highest: Readout?
    let isSingleDay: Bool
    let filtered: Bool

    init(board: UsageDashboard, hours: [Double], metric: DashboardMetric, tools: [String]) {
        isSingleDay = board.calendarDays == 1
        filtered = !board.filter.isEmpty
        if isSingleDay {
            buckets = hours.enumerated().map { hour, value in
                TrendBucket(start: String(format: "%02d", hour), isWeek: false,
                            values: value > 0 ? [UsageDashboard.otherSeries: value] : [:])
            }
        } else {
            buckets = board.trend(metric, series: tools)
        }
        let order = tools + [UsageDashboard.otherSeries]
        let marks = buckets.flatMap { bucket in
            order.compactMap { name in bucket.values[name].map { Mark(bucket: bucket.start, series: name, value: $0) } }
        }
        self.marks = marks
        let keys = buckets.map(\.start)
        self.keys = keys
        let stride = max(1, keys.count / 8)
        labels = keys.enumerated().filter { $0.offset % stride == stride / 2 }.map(\.element)
        legend = order.compactMap { name in
            let entries = marks.filter { $0.series == name }
            return entries.isEmpty ? nil : Series(name: name, value: entries.reduce(0) { $0 + $1.value })
        }
        legendTotal = max(marks.reduce(0) { $0 + $1.value }, 0.000_001)
        let readouts = buckets.map { bucket in
            Readout(start: bucket.start, isWeek: bucket.isWeek, total: bucket.total,
                    series: bucket.values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                        .prefix(4).map { Series(name: $0.key, value: $0.value) })
        }
        self.readouts = Dictionary(uniqueKeysWithValues: readouts.map { ($0.start, $0) })
        highest = readouts.max { $0.total < $1.total }
    }
}

struct DashboardHeat: Equatable, Sendable {
    struct Month: Equatable, Sendable { let week: Int; let month: Int }
    let cells: [HeatCell]
    let months: [Month]
    let weeks: Int
    let activeCount: Int

    init(cells: [HeatCell]) {
        self.cells = cells
        weeks = (cells.map(\.week).max() ?? 0) + 1
        activeCount = cells.filter { $0.level > 0 }.count
        var months: [Month] = []
        var lastMonth = ""
        for cell in cells where cell.weekday == 0 {
            let month = String(cell.date.dropFirst(5).prefix(2))
            if month != lastMonth {
                if !lastMonth.isEmpty || cell.week == 0 { months.append(Month(week: cell.week, month: Int(month)!)) }
                lastMonth = month
            }
        }
        if months.count > 1, months[1].week - months[0].week < 3 { months.removeFirst() }
        self.months = months
    }
}

struct DashboardPresentation: Sendable {
    let request: DashboardRequest
    let board: UsageDashboard
    let yearBoard: UsageDashboard
    let everything: UsageDashboard
    let stats: DashboardStats
    let tools: [String]
    let trend: DashboardTrend
    let heat: DashboardHeat
    let hours: [Double]
    let weekdays: [Double]
}

extension DashboardPresentation {
    /// A small startup-only calculation makes restored input visible before the first frame.
    init(input: DashboardInput, request: DashboardRequest) {
        let board = UsageDashboard(days: input.days, start: request.start, end: request.end, filter: request.filter, calendar: request.calendar)
        let year = UsageDashboard(days: input.days, start: nil, end: request.today, filter: request.filter, calendar: request.calendar)
        let everything = UsageDashboard(days: input.days, start: nil, end: request.today, calendar: request.calendar)
        let tools = Array(everything.ledger.byClient.prefix(request.seriesLimit).map(\.name))
        let hours = request.filter.isEmpty ? HourUsage.profile(input.hours, start: board.start, end: board.end, metric: request.metric) : []
        self.init(request: request, board: board, yearBoard: year, everything: everything, stats: DashboardStats(board), tools: tools,
                  trend: DashboardTrend(board: board, hours: hours, metric: request.metric, tools: tools),
                  heat: DashboardHeat(cells: year.heatCells(metric: request.metric)), hours: hours, weekdays: board.weekdayProfile(request.metric))
    }
}

/// A small bounded cache per responsibility, so changing a range never rebuilds the annual grid.
private struct DashboardLRU<Key: Equatable, Value> {
    private var entries: [(key: Key, value: Value)] = []
    mutating func value(for key: Key) -> Value? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.value
    }
    mutating func insert(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > 8 { entries.removeFirst() }
    }
    mutating func removeAll() { entries.removeAll() }
}

/// Actor work is reached through Task.detached, never from a view's body or the main actor.
actor DashboardCache {
    private struct BoardKey: Equatable {
        let start: String?
        let end: String
        let filter: DashboardFilter
    }
    private struct HeatKey: Equatable { let filter: DashboardFilter; let metric: DashboardMetric }
    private var generation: (version: Int, today: String, calendar: Calendar)?
    private var boards = DashboardLRU<BoardKey, UsageDashboard>()
    private var heat = DashboardLRU<HeatKey, DashboardHeat>()
    private var results = DashboardLRU<DashboardRequest, DashboardPresentation>()
    private(set) var boardComputations = 0
    private(set) var heatComputations = 0
    private(set) var presentationComputations = 0

    func result(input: DashboardInput, request: DashboardRequest) -> DashboardPresentation {
        if generation?.version != request.version || generation?.today != request.today || generation?.calendar != request.calendar {
            boards.removeAll()
            heat.removeAll()
            results.removeAll()
            generation = (request.version, request.today, request.calendar)
        }
        if let result = results.value(for: request) { return result }
        let board = self.board(input, start: request.start, end: request.end, filter: request.filter, calendar: request.calendar)
        let year = self.board(input, start: nil, end: request.today, filter: request.filter, calendar: request.calendar)
        let everything = self.board(input, start: nil, end: request.today, filter: DashboardFilter(), calendar: request.calendar)
        let tools = Array(everything.ledger.byClient.prefix(request.seriesLimit).map(\.name))
        let hours = request.filter.isEmpty
            ? HourUsage.profile(input.hours, start: board.start, end: board.end, metric: request.metric) : []
        let heatKey = HeatKey(filter: request.filter, metric: request.metric)
        let cells: DashboardHeat
        if let cached = heat.value(for: heatKey) { cells = cached }
        else {
            cells = DashboardHeat(cells: year.heatCells(metric: request.metric))
            heat.insert(cells, for: heatKey)
            heatComputations += 1
        }
        let result = DashboardPresentation(request: request, board: board, yearBoard: year, everything: everything,
                                           stats: DashboardStats(board), tools: tools,
                                           trend: DashboardTrend(board: board, hours: hours, metric: request.metric, tools: tools),
                                           heat: cells, hours: hours, weekdays: board.weekdayProfile(request.metric))
        presentationComputations += 1
        results.insert(result, for: request)
        return result
    }

    private func board(_ input: DashboardInput, start: String?, end: String, filter: DashboardFilter, calendar: Calendar) -> UsageDashboard {
        let key = BoardKey(start: start, end: end, filter: filter)
        if let board = boards.value(for: key) { return board }
        let board = UsageDashboard(days: input.days, start: start, end: end, filter: filter, calendar: calendar)
        boards.insert(board, for: key)
        boardComputations += 1
        return board
    }
}

@MainActor @Observable
final class DashboardStore {
    typealias Compute = @Sendable (DashboardInput, DashboardRequest) async -> DashboardPresentation
    private(set) var result: DashboardPresentation?
    private(set) var updatedAt: Date?
    private(set) var version = 0
    private(set) var today: String
    @ObservationIgnored private var input: DashboardInput?
    @ObservationIgnored private var inputUpdatedAt: Date?
    @ObservationIgnored private var latestRequest: DashboardRequest?
    @ObservationIgnored private var requestNumber = 0
    @ObservationIgnored private var cached = DashboardLRU<DashboardRequest, DashboardPresentation>()
    @ObservationIgnored private let compute: Compute

    init(today: String = DayKey.string(from: Date()), compute: Compute? = nil) {
        self.today = today
        let cache = DashboardCache()
        self.compute = compute ?? { input, request in await cache.result(input: input, request: request) }
    }

    func update(days: [DayDetail]?, hours: [HourUsage], updatedAt: Date? = nil) {
        inputUpdatedAt = updatedAt
        guard input?.days != days || input?.hours != hours else { return }
        input = days.map { DashboardInput(days: $0, hours: hours) }
        version += 1
        cached.removeAll()
        requestNumber += 1
        if days == nil { result = nil; self.updatedAt = nil }
    }

    func updateToday(_ day: String) {
        guard today != day else { return }
        today = day
        cached.removeAll()
        requestNumber += 1
    }

    func request(selection: DashboardSelection, seriesLimit: Int, calendar: Calendar = .current) -> DashboardRequest {
        let end = selection.day ?? today
        let start: String?
        if selection.day != nil { start = end }
        else if let lookback = selection.period.lookback {
            let ordinal = DayKey.ordinal(from: today, calendar: calendar)!
            start = DayKey.string(forOrdinal: ordinal - lookback, calendar: calendar)
        } else { start = nil }
        return DashboardRequest(version: version, today: today, start: start, end: end,
                                filter: DashboardFilter(client: selection.client, model: selection.model), metric: selection.metric,
                                seriesLimit: seriesLimit, calendar: calendar)
    }

    func select(_ request: DashboardRequest) async {
        guard let input, request.version == version, request.today == today else { return }
        requestNumber += 1
        let number = requestNumber
        latestRequest = request
        if let hit = cached.value(for: request) {
            result = hit
            updatedAt = inputUpdatedAt
            return
        }
        let compute = compute
        let readAt = inputUpdatedAt
        let value = await Task.detached(priority: .utility) { await compute(input, request) }.value
        guard number == requestNumber, latestRequest == request, request.version == version, request.today == today else { return }
        cached.insert(value, for: request)
        result = value
        updatedAt = readAt
    }

    func restore(selection: DashboardSelection, seriesLimit: Int) {
        guard let input else { return }
        let request = request(selection: selection, seriesLimit: seriesLimit)
        let value = DashboardPresentation(input: input, request: request)
        cached.insert(value, for: request)
        result = value
        updatedAt = inputUpdatedAt
    }

    /// For snapshots, which render while holding the main actor, so `select` from a view's task cannot finish.
    func showCached(_ request: DashboardRequest) {
        if let hit = cached.value(for: request) { result = hit }
    }
}
