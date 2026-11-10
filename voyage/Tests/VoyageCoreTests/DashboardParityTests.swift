import Foundation
import Testing
import VoyageCore

@Test(arguments: ["UTC", "America/Los_Angeles", "America/Sao_Paulo"])
func optimizedDashboardMatchesOriginalCalculations(timeZone: String) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    let end = "2020-04-12"
    let first = try #require(DayKey.date(from: "2019-01-01", calendar: calendar))
    let days = try (0..<468).compactMap { offset -> DayDetail? in
        if offset.isMultiple(of: 9) { return nil }
        let date = try #require(calendar.date(byAdding: .day, value: offset, to: first))
        return DayDetail(date: DayKey.string(from: date, calendar: calendar), rows: (0..<4).map { index in
            UsageRow(client: ["codex", "claude", "other", "codex"][index], model: "m\(index)",
                     tokens: UsageTotals(input: offset + index, output: index * 2, cacheRead: offset % 7,
                                         cacheWrite: index, reasoning: offset % 5, cost: Double(offset % 9) * 0.25, messages: index + 1))
        }, activeMs: offset * 1_000)
    }
    for start: String? in [nil, end, "2020-04-06", "2020-03-14", "2020-01-01", "2019-04-14"] {
        for filter in [DashboardFilter(), DashboardFilter(client: "codex"), DashboardFilter(model: "m1"), DashboardFilter(client: "missing")] {
            let actual = UsageDashboard(days: days, start: start, end: end, filter: filter, calendar: calendar)
            let original = ReferenceDashboard(days: days, start: start, end: end, filter: filter, calendar: calendar)
            #expect(actual.start == original.start)
            #expect(actual.end == original.end)
            #expect(actual.ledger == original.ledger)
            #expect(actual.previous == original.previous)
            #expect(actual.calendarDays == original.calendarDays)
            #expect(actual.activeDays == original.activeDays)
            #expect(actual.currentStreak == original.currentStreak)
            #expect(actual.longestStreak == original.longestStreak)
            #expect(actual.activeMs == original.activeMs)
            #expect(actual.peak?.date == original.peak?.date)
            #expect(actual.peak?.total == original.peak?.total)
            #expect(actual.topModel == original.topModel)
            #expect(actual.activeRate == original.activeRate)
            for metric in DashboardMetric.allCases {
                #expect(actual.change(metric) == original.change(metric))
                #expect(actual.trend(metric, series: ["codex", "claude"]) == original.trend(metric, series: ["codex", "claude"]))
                #expect(actual.heatCells(metric: metric) == original.heatCells(metric: metric))
                if metric == .fuel {
                    // Fractional km sums can differ by floating-point addition order.
                    #expect(zip(actual.weekdayProfile(metric), original.weekdayProfile(metric)).allSatisfy { abs($0 - $1) < 1e-12 })
                } else {
                    #expect(actual.weekdayProfile(metric) == original.weekdayProfile(metric))
                }
            }
        }
    }
}
