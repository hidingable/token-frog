import Foundation
import Testing
@testable import VoyageCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
}()

private func fresh(seed: UInt32 = 7) -> JourneyState {
    JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: testCatalog)
}

private func usage(_ date: String, _ fuel: Int, client: String = "codex") -> DayUsage {
    DayUsage(date: date, fuel: fuel, byClient: [client: fuel])
}

@Test func parsesFuelWithoutCacheReadsOrReasoning() throws {
    let json = #"""
    {"contributions":[{"date":"2026-11-05","clients":[
      {"client":"codex","tokens":{"input":100,"output":20,"cacheRead":9000,"cacheWrite":0,"reasoning":5}},
      {"client":"claude","tokens":{"input":1,"output":2,"cacheRead":9000,"cacheWrite":30,"reasoning":0}},
      {"client":"codex","tokens":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
      {"client":"pi","tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}
    ]}]}
    """#
    let days = try TokscaleGraph.parse(Data(json.utf8))
    #expect(days == [DayUsage(date: "2026-11-05", fuel: 163, byClient: ["codex": 130, "claude": 33], observedTokens: 18_168)])
}

@Test func startsWithReadLogbookLetterAndHomeStamp() {
    let state = fresh()
    #expect(state.letters.map(\.kind) == [.logbook])
    #expect(state.letters[0].logbook == nil)
    #expect(state.letters[0].read && state.letters[0].enrichmentDone)
    #expect(state.unreadCount(now: Date(timeIntervalSince1970: 0)) == 0)
    #expect(state.stamps.map(\.countryCode) == ["CN"])
    #expect(state.targetCityId != "shanghai")
}

@Test func changingHomeReplaysTodayAndOnlyChangesFirstLetterCity() throws {
    let logbook = Logbook(workdayStartHour: 9, weekendActivePercent: 25, topClients: ["codex", "claude"])
    var state = JourneyState(
        seed: 42, startCityId: "shanghai", pet: PetID(rawValue: "snail"), date: "2026-11-01",
        now: Date(timeIntervalSince1970: 123), logbook: logbook, catalog: testCatalog
    )
    state.letters[0].read = false
    state.letters[0].weatherCode = 0
    state.sync(today: usage("2026-11-01", 400_000_000), calendar: calendar, catalog: testCatalog)
    var expectedLetter = state.letters[0]
    expectedLetter.cityId = "xian"
    var expected = JourneyState(seed: 42, startCityId: "xian", pet: PetID(rawValue: "snail"), date: "2026-11-01", catalog: testCatalog)
    expected.sync(today: usage("2026-11-01", 400_000_000), calendar: calendar, catalog: testCatalog)
    expected.letters = [expectedLetter]
    state.setStart("xian", calendar: calendar, catalog: testCatalog)
    #expect(state == expected)
    #expect(state.letters[0].kind == .logbook && state.letters[0].logbook == logbook && !state.letters[0].read)
    #expect(state.totalFuel == 400_000_000 && state.route.first == "xian")
}

@Test func changingHomeKeepsLegacyDepartureAndRejectsLaterDays() throws {
    var state = fresh()
    state.letters[0].kind = .departure
    state.setStart("xian", calendar: calendar, catalog: testCatalog)
    #expect(state.letters[0].kind == .departure)
    #expect(state.letters[0].cityId == "xian")
    state.sync(today: usage("2026-11-02", 10), finalized: [usage("2026-11-01", 100)], calendar: calendar, catalog: testCatalog)
    let original = state
    state.setStart("shanghai", calendar: calendar, catalog: testCatalog)
    #expect(state == original)
}

@Test func creditsExactDeltasAndNeverGoesBackwards() {
    var state = fresh()
    state.sync(today: usage("2026-11-01", 5_000), calendar: calendar, catalog: testCatalog)
    state.sync(today: usage("2026-11-01", 8_000), calendar: calendar, catalog: testCatalog)
    #expect(state.legFuel == 8_000)
    state.sync(today: usage("2026-11-01", 6_000), calendar: calendar, catalog: testCatalog)
    #expect(state.legFuel == 8_000)
    #expect(state.totalFuel == 8_000)
    state.sync(today: usage("2026-11-01", 8_001), calendar: calendar, catalog: testCatalog)
    #expect(state.legFuel == 8_001)
    #expect(state.totalFuel == 8_001)
}

@Test func arrivalsConsumeExactlyTheLegCost() {
    var state = fresh()
    let firstTarget = state.targetCityId
    let cost = state.legCost
    state.sync(today: usage("2026-11-01", cost + 123), calendar: calendar, catalog: testCatalog)
    #expect(state.currentCityId == firstTarget)
    #expect(state.route == ["shanghai", firstTarget])
    #expect(state.legFuel == 123)
}

@Test func lateFuelForTheOpenDayIsCreditedBeforeSettlement() {
    var state = fresh()
    state.sync(today: usage("2026-11-01", 1_000), calendar: calendar, catalog: testCatalog)
    state.sync(today: usage("2026-11-02", 500), finalized: [usage("2026-11-01", 4_000)], calendar: calendar, catalog: testCatalog)
    #expect(state.fuel(on: "2026-11-01") == 4_000)
    #expect(state.totalFuel == 4_500)
    let letter = state.letters.last!
    #expect(letter.date == "2026-11-01")
    #expect(letter.fuel == 4_000)
    #expect(letter.transitTargetId == state.targetCityId)
}

@Test func catchesUpMissedDaysOneLetterPerActiveDay() {
    var state = fresh()
    state.sync(
        today: usage("2026-11-05", 10),
        finalized: [usage("2026-11-01", 1_000), usage("2026-11-02", 0), usage("2026-11-03", 2_000), usage("2026-11-04", 3_000)],
        calendar: calendar, catalog: testCatalog
    )
    #expect(state.openDate == "2026-11-05")
    #expect(state.letters.filter { $0.kind == .daily }.map(\.date) == ["2026-11-01", "2026-11-03", "2026-11-04"])
    #expect(state.totalFuel == 6_010)
}

@Test func heavyDayPassesManyCitiesButWritesOneLetter() {
    var state = fresh()
    state.sync(today: usage("2026-11-01", 400_000_000), calendar: calendar, catalog: testCatalog)
    state.sync(today: usage("2026-11-02", 0), finalized: [usage("2026-11-01", 400_000_000)], calendar: calendar, catalog: testCatalog)
    let daily = state.letters.filter { $0.kind == .daily }
    #expect(daily.count == 1)
    #expect(daily[0].arrivals.count > 3)
    #expect(daily[0].cityId == daily[0].arrivals.last)
    #expect(daily[0].transitTargetId == nil)
}

@Test func letterIsDeliveredAtNineTheNextMorning() {
    var state = fresh()
    state.sync(today: usage("2026-11-02", 0), finalized: [usage("2026-11-01", 1_000)], calendar: calendar, catalog: testCatalog)
    let letter = state.letters.last!
    let parts = calendar.dateComponents([.year, .month, .day, .hour], from: letter.deliverAt)
    #expect([parts.year, parts.month, parts.day, parts.hour] == [2026, 11, 2, 9])
    #expect(state.deliveredLetters(now: letter.deliverAt.addingTimeInterval(-1)).map(\.id) == [0])
    #expect(state.deliveredLetters(now: letter.deliverAt).map(\.id) == [letter.id, 0])
}

@Test func replayingTheSameUsageIsDeterministic() {
    func run() -> JourneyState {
        var state = fresh(seed: 42)
        var day = "2026-11-01"
        for value in [30_000_000, 5_000_000, 90_000_000, 1_000, 44_000_000] {
            let next = DayKey.next(day, calendar: calendar)
            state.sync(today: usage(next, 0), finalized: [usage(day, value)], calendar: calendar, catalog: testCatalog)
            day = next
        }
        return state
    }
    #expect(run() == run())
}

@Test func savedTargetDoesNotChangeUntilArrival() throws {
    var state = fresh()
    state.sync(today: usage("2026-11-01", 123), calendar: calendar, catalog: testCatalog)
    let original = state
    state = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
    state.sync(today: usage("2026-11-01", 123), calendar: calendar, catalog: testCatalog, wishTags: ["coast"])
    #expect(state == original)
    state.sync(today: usage("2026-11-01", state.legCost), calendar: calendar, catalog: testCatalog)
    #expect(state.currentCityId == original.targetCityId)
    #expect(state.targetCityId != original.targetCityId)
}

@Test func lowDaysBecomeDeepVisitsOnceThereIsABaseline() {
    var state = fresh()
    var day = "2026-11-01"
    for value in [8_000_000, 9_000_000, 10_000_000, 1_000_000] {
        let next = DayKey.next(day, calendar: calendar)
        state.sync(today: usage(next, 0), finalized: [usage(day, value)], calendar: calendar, catalog: testCatalog)
        day = next
    }
    let letters = state.letters.filter { $0.kind == .daily }
    #expect(letters.first?.isDeepVisit == false)
    #expect(letters.last?.isDeepVisit == true)
    #expect(letters.last?.compareToMedianPercent == -89)
}

@Test func journeyStateRoundTripsThroughJSON() throws {
    var state = fresh()
    state.sync(today: usage("2026-11-02", 7), finalized: [usage("2026-11-01", 99_000_000)], calendar: calendar, catalog: testCatalog)
    let decoded = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
}

@Test func kilometresAndTokensRoundTheSameWay() {
    #expect(Format.tokens(8_997_637, language: .zhHans) == "900 万")
    #expect(Format.km(fuel: 8_997_637) == "900 km")
    #expect(Format.km(fuel: 13_400_000) == "1,340 km")
    #expect(Format.tokens(400_000_000, language: .zhHans) == "4.0 亿")
}

@Test func worldMapMatchesDeclaredSize() {
    #expect(WorldMapData.rows.count == WorldMapData.height)
    #expect(WorldMapData.rows.allSatisfy { $0.count == WorldMapData.width })
}

@Test func cityIdsAreUnique() {
    #expect(Set(testCatalog.all.map(\.id)).count == testCatalog.all.count)
}

@Test func ledgerGroupsAllTokenKindsWithoutChangingFuel() throws {
    let json = #"""
    {"contributions":[
      {"date":"2026-11-04","clients":[
        {"client":"codex","modelId":"gpt","tokens":{"input":100,"output":20,"cacheRead":900,"cacheWrite":0,"reasoning":5},"cost":1.5,"messages":2}
      ]},
      {"date":"2026-11-05","clients":[
        {"client":"codex","modelId":"gpt","tokens":{"input":10,"output":0,"cacheRead":90,"cacheWrite":0,"reasoning":0},"cost":0.5,"messages":1},
        {"client":"claude","modelId":"opus","tokens":{"input":1,"output":2,"cacheRead":0,"cacheWrite":30,"reasoning":0},"cost":0.25,"messages":1},
        {"client":"pi","modelId":"gpt","tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}
      ]}
    ]}
    """#
    let details = try TokscaleGraph.parseDetails(Data(json.utf8))
    let ledger = UsageLedger(days: details)
    #expect(ledger.totals == UsageTotals(input: 111, output: 22, cacheRead: 990, cacheWrite: 30, reasoning: 5, cost: 2.25, messages: 4))
    #expect(ledger.totals.total == 1158)
    #expect(ledger.totals.fuel == 163)
    #expect(ledger.activeDays == 2)
    #expect(ledger.byClient.map(\.name) == ["codex", "claude"])
    #expect(ledger.byModel.map(\.name) == ["gpt", "opus"])
    #expect(ledger.byModel[0].tokens.messages == 3)
    #expect(UsageTotals(input: 1, cacheRead: 90, cacheWrite: 9).cacheHitPercent == 90)
    #expect(UsageTotals(output: 5).cacheHitPercent == nil)
    #expect(try TokscaleGraph.parse(Data(json.utf8)).map(\.fuel) == [120, 43])
}

@Test func quotaReportDropsAccountData() throws {
    let json = #"""
    [{"provider":"Codex","plan":"Pro","email":"someone@example.com","metrics":[
        {"label":"Weekly","used_percent":62.0,"remaining_percent":38.0,"remaining_label":null,"resets_at":"2026-11-09T02:47:37+00:00"}
      ],"reset_credits":{"available_count":2,"credits":[{"id":"x"}]}},
     {"provider":"Copilot","plan":null,"email":null,"metrics":[
        {"label":"Premium","used_percent":100.0,"remaining_percent":0.0,"remaining_label":null,"resets_at":"2026-12-01"}
      ]},
     {"provider":"Empty","plan":null,"email":null}]
    """#
    let quotas = try QuotaReport.parse(Data(json.utf8))
    #expect(quotas.map(\.provider) == ["Codex", "Copilot", "Empty"])
    #expect(quotas[0].resetCredits == 2)
    #expect(quotas[2].metrics.isEmpty)
    #expect(!String(describing: quotas).contains("someone@example.com"))
}

@Test func quotaResetDescriptionHandlesTimestampsAndPlainDates() {
    let now = ISO8601DateFormatter().date(from: "2026-11-06T02:47:37+00:00")!
    #expect(QuotaReport.resetDescription("2026-11-09T04:47:37+00:00", now: now) == .daysHours(3, 2))
    #expect(QuotaReport.resetDescription("2026-11-06T03:17:37.500Z", now: now) == .minutes(30))
    #expect(QuotaReport.resetDescription("2026-11-06T04:47:37+00:00", now: now) == .hours(2))
    #expect(QuotaReport.resetDescription("2026-11-06T02:00:00+00:00", now: now) == .soon)
    #expect(QuotaReport.resetDescription("2026-12-01", now: now, calendar: calendar) == .date("2026-12-01"))
    #expect(QuotaReport.resetDescription("soon", now: now) == .raw("soon"))
}

private func detail(_ date: String, client: String = "codex", model: String = "gpt", input: Int = 100, cacheRead: Int = 900, activeMs: Int = 3_600_000) -> DayDetail {
    DayDetail(date: date, rows: [UsageRow(client: client, model: model, tokens: UsageTotals(input: input, cacheRead: cacheRead, cost: 1, messages: 1))], activeMs: activeMs)
}

@Test func dashboardComparesPeriodsAndCountsActivity() {
    let days = [
        detail("2026-10-30"), detail("2026-10-31", input: 300),
        detail("2026-11-02"), detail("2026-11-03", input: 900), detail("2026-11-05"),
    ]
    let board = UsageDashboard(days: days, start: "2026-11-02", end: "2026-11-05", calendar: calendar)
    #expect(board.calendarDays == 4)
    #expect(board.activeDays == 3)
    #expect(board.ledger.totals.input == 1100)
    #expect(board.activeMs == 3 * 3_600_000)
    #expect(board.peak?.date == "2026-11-03")
    #expect(board.topModel == "gpt")
    #expect(board.currentStreak == 1)
    #expect(board.longestStreak == 2)
    // Short ranges are too noisy to compare; a week compares with the week before.
    #expect(board.previous == nil)
    let week = UsageDashboard(days: days, start: "2026-10-30", end: "2026-11-05", calendar: calendar)
    #expect(week.previous?.totals.input == nil || week.previous?.totals.input == 0)
    let later = UsageDashboard(days: days + [detail("2026-11-06", input: 1)], start: "2026-11-06", end: "2026-11-12", calendar: calendar)
    #expect(later.previous?.totals.input == 1500)
    #expect(later.change(.messages) == -80)

    let all = UsageDashboard(days: days, start: nil, end: "2026-11-05", calendar: calendar)
    #expect(all.calendarDays == 7)
    #expect(all.previous == nil)
}

@Test func dashboardFiltersRowsButKeepsActiveTimeUnfiltered() {
    let day = DayDetail(date: "2026-11-05", rows: [
        UsageRow(client: "codex", model: "gpt", tokens: UsageTotals(input: 10)),
        UsageRow(client: "claude", model: "opus", tokens: UsageTotals(input: 20)),
    ], activeMs: 5)
    let board = UsageDashboard(days: [day], start: "2026-11-05", end: "2026-11-05", filter: .init(client: "claude"), calendar: calendar)
    #expect(board.ledger.totals.input == 20)
    #expect(board.ledger.byModel.map(\.name) == ["opus"])
    #expect(board.activeMs == nil)
}

@Test func dashboardTrendFillsGapsFoldsTailAndBucketsLongRangesByWeek() {
    let days = [
        DayDetail(date: "2026-11-02", rows: [
            UsageRow(client: "codex", model: "gpt", tokens: UsageTotals(input: 10)),
            UsageRow(client: "kimi", model: "k", tokens: UsageTotals(input: 5)),
        ]),
        detail("2026-11-04", input: 7, cacheRead: 0),
    ]
    let short = UsageDashboard(days: days, start: "2026-11-02", end: "2026-11-04", calendar: calendar)
    let trend = short.trend(.total, series: ["codex"])
    #expect(trend.map(\.start) == ["2026-11-02", "2026-11-03", "2026-11-04"])
    #expect(trend[0].values == ["codex": 10, UsageDashboard.otherSeries: 5])
    #expect(trend[1].values.isEmpty)
    #expect(!trend[0].isWeek)

    let long = UsageDashboard(days: days, start: "2026-07-01", end: "2026-11-04", calendar: calendar)
    let weeks = long.trend(.total, series: ["codex"])
    #expect(!weeks.contains { !$0.isWeek })
    #expect(weeks.last?.start == "2026-11-02") // A Monday.
    #expect(weeks.last?.total == 22)
    #expect(weeks.first?.start == "2026-06-29")
}

@Test func heatmapLevelsAreQuartilesAndWeeksAlignToMondays() {
    let days = (1...8).map { detail(String(format: "2026-10-%02d", $0), input: $0 == 8 ? 1_000_000 : $0, cacheRead: 0) }
    let board = UsageDashboard(days: days, start: "2026-10-01", end: "2026-10-08", calendar: calendar)
    let cells = board.heatCells(metric: .total, weeks: 2)
    #expect(cells.first?.date == "2026-09-28")
    #expect(cells.first?.weekday == 0)
    #expect(cells.first(where: { $0.date == "2026-10-08" })?.level == 4)
    #expect(cells.first(where: { $0.date == "2026-10-01" })?.level == 1)
    #expect(cells.first(where: { $0.date == "2026-09-28" })?.level == 0)
    #expect(!cells.contains { $0.date > "2026-10-08" })
}

@Test func hourlyReportParsesAndProfiles() throws {
    let json = #"""
    {"entries":[
      {"hour":"2026-11-05 09:00","clients":["codex"],"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"messageCount":5,"cost":0.5},
      {"hour":"2026-11-06 09:00","clients":["claude","codex"],"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"messageCount":1,"cost":1}
    ]}
    """#
    let hours = try TokscaleHourly.parse(Data(json.utf8))
    #expect(hours[0].date == "2026-11-05")
    #expect(hours[0].hour == 9)
    #expect(hours[0].tokens.total == 10)
    #expect(hours[0].tokens.messages == 5)
    let profile = HourUsage.profile(hours, start: "2026-11-06", end: "2026-11-06", metric: .total)
    #expect(profile.count == 24)
    #expect(profile[9] == 10)
    #expect(profile[10] == 0)
}
