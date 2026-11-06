import Foundation
import Testing
@testable import VoyageCore

private let logbookCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private func logbookDays(from start: String, through end: String, rows: [String: [UsageRow]] = [:]) -> [DayDetail] {
    var date = start
    var days: [DayDetail] = []
    while date <= end {
        days.append(DayDetail(date: date, rows: rows[date] ?? []))
        date = DayKey.next(date, calendar: logbookCalendar)
    }
    return days
}

private func logbookRow(_ client: String = "codex", input: Int = 100, cacheRead: Int = 0) -> UsageRow {
    UsageRow(client: client, model: "example", tokens: UsageTotals(input: input, cacheRead: cacheRead))
}

private func logbookHour(_ date: String, _ hour: Int, input: Int = 1, cacheRead: Int = 0) -> HourUsage {
    HourUsage(date: date, hour: hour, tokens: UsageTotals(input: input, cacheRead: cacheRead))
}

@Suite struct LogbookTests {
    @Test func workdayStartIsMedianOfFirstActiveHoursAndIgnoresWeekends() throws {
        let days = logbookDays(from: "2026-11-01", through: "2026-11-08")
        let hours = [
            logbookHour("2026-11-02", 11), logbookHour("2026-11-02", 9),
            logbookHour("2026-11-03", 7), logbookHour("2026-11-04", 12),
            logbookHour("2026-11-05", 10), logbookHour("2026-11-05", 2, input: 0),
            logbookHour("2026-11-01", 0), logbookHour("2026-11-07", 1),
            logbookHour("2026-11-08", 2), logbookHour("2026-10-30", 1),
        ]
        let result = try #require(Logbook.summarize(days: days, hours: hours, calendar: logbookCalendar))
        #expect(result.workdayStartHour == 10)
        #expect(result.weekendActivePercent == 100)
    }

    @Test func weekendPercentageUsesAllWeekendDaysAndQuietBoundaryIncludesTwentyFive() throws {
        let rows = ["2026-11-07": [logbookRow(input: 0, cacheRead: 100)]]
        let days = logbookDays(from: "2026-11-02", through: "2026-11-15", rows: rows)
        let result = try #require(Logbook.summarize(days: days, hours: [], calendar: logbookCalendar))
        #expect(result.weekendActivePercent == 25)
        #expect(result.isWeekendQuiet == true)
        #expect(result.topClients.isEmpty)
        #expect(result.workdayStartHour == nil)
        #expect(Logbook.weekendQuietThreshold == 25)
        #expect(Logbook(workdayStartHour: nil, weekendActivePercent: 0, topClients: []).isWeekendQuiet == true)
        #expect(Logbook(workdayStartHour: nil, weekendActivePercent: 26, topClients: []).isWeekendQuiet == false)
        #expect(Logbook(workdayStartHour: nil, weekendActivePercent: nil, topClients: []).isWeekendQuiet == nil)

        let moreActive = logbookDays(from: "2026-11-02", through: "2026-11-15", rows: [
            "2026-11-07": [logbookRow()], "2026-11-08": [logbookRow()],
        ])
        let busy = try #require(Logbook.summarize(days: moreActive, hours: [], calendar: logbookCalendar))
        #expect(busy.weekendActivePercent == 50 && busy.isWeekendQuiet == false)
    }

    @Test func clientsAreRankedByFuelWithStableTiesAndOnlyTwoSurvive() throws {
        let days = [DayDetail(date: "2026-11-02", rows: [
            logbookRow("codex", input: 20), logbookRow("codex", input: 30),
            logbookRow("claude", input: 75), logbookRow("cursor", input: 50),
            logbookRow("cache-only", input: 0, cacheRead: 1_000_000),
        ])]
        let result = try #require(Logbook.summarize(days: days, hours: [], calendar: logbookCalendar))
        #expect(result.topClients == ["claude", "codex"])
        let one = try #require(Logbook.summarize(
            days: [DayDetail(date: "2026-11-02", rows: [logbookRow()])], hours: [], calendar: logbookCalendar
        ))
        #expect(one.topClients == ["codex"])
    }

    @Test func noTokenUsageReturnsNilAndRangeWithoutWeekendsOmitsPercentage() throws {
        let empty = logbookDays(from: "2026-11-02", through: "2026-11-06", rows: [
            "2026-11-02": [UsageRow(client: "codex", model: "example", tokens: UsageTotals(cost: 1, messages: 3))],
        ])
        #expect(Logbook.summarize(days: empty, hours: [], calendar: logbookCalendar) == nil)
        #expect(Logbook.summarize(days: [], hours: [], calendar: logbookCalendar) == nil)
        let active = logbookDays(from: "2026-11-02", through: "2026-11-06", rows: ["2026-11-02": [logbookRow()]])
        let result = try #require(Logbook.summarize(days: active, hours: [], calendar: logbookCalendar))
        #expect(result.weekendActivePercent == nil)
    }

    @Test func cacheOnlyHoursAreActivityAndDoNotBecomeFuel() throws {
        let days = logbookDays(from: "2026-11-02", through: "2026-11-06", rows: [
            "2026-11-02": [logbookRow(input: 0, cacheRead: 100)],
        ])
        let result = try #require(Logbook.summarize(
            days: days, hours: [logbookHour("2026-11-02", 8, input: 0, cacheRead: 100)], calendar: logbookCalendar
        ))
        #expect(result.workdayStartHour == 8)
        #expect(result.topClients.isEmpty)
    }

    @Test func doublingUsageLeavesAllObservationsUnchanged() throws {
        let days = logbookDays(from: "2026-11-01", through: "2026-11-08", rows: [
            "2026-11-02": [logbookRow("codex", input: 200, cacheRead: 900), logbookRow("claude", input: 100)],
            "2026-11-03": [logbookRow("claude", input: 50)],
            "2026-11-07": [logbookRow("codex", input: 0, cacheRead: 100)],
        ])
        let hours = [logbookHour("2026-11-02", 8), logbookHour("2026-11-03", 10), logbookHour("2026-11-07", 1)]
        let doubledDays = days.map { day in
            DayDetail(date: day.date, rows: day.rows.map {
                UsageRow(client: $0.client, model: $0.model, tokens: $0.tokens + $0.tokens)
            })
        }
        let doubledHours = hours.map { HourUsage(date: $0.date, hour: $0.hour, tokens: $0.tokens + $0.tokens) }
        let result = try #require(Logbook.summarize(days: days, hours: hours, calendar: logbookCalendar))
        #expect(result == Logbook.summarize(days: doubledDays, hours: doubledHours, calendar: logbookCalendar))
    }

    @Test func logbookAndItsLetterRoundTripWithoutCreditingFuel() throws {
        let logbook = Logbook(workdayStartHour: 9, weekendActivePercent: 25, topClients: ["codex", "claude"])
        #expect(try JSONDecoder().decode(Logbook.self, from: JSONEncoder().encode(logbook)) == logbook)
        let now = Date(timeIntervalSince1970: 1_000)
        let journey = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-11-02", now: now, logbook: logbook, catalog: testCatalog)
        let letter = try #require(journey.letters.first)
        #expect(letter.kind == .logbook && letter.logbook == logbook)
        #expect(letter.deliverAt == now && letter.read && letter.enrichmentDone)
        #expect(journey.totalFuel == 0 && journey.days.isEmpty && journey.route == ["shanghai"])
        #expect(journey.unreadCount(now: now) == 0)
        #expect(try JSONDecoder().decode(Letter.self, from: JSONEncoder().encode(letter)) == letter)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
    }

    @Test func oldDepartureStillDecodesWithoutLogbook() throws {
        let url = try #require(Bundle.module.url(forResource: "journey-v3", withExtension: "json", subdirectory: "Fixtures"))
        let journey = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: url))
        let departure = try #require(journey.letters.first)
        #expect(departure.kind == .departure && departure.logbook == nil)
        #expect(try JSONDecoder().decode(Letter.self, from: JSONEncoder().encode(departure)) == departure)
    }
}
