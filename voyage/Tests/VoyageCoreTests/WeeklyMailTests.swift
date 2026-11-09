import Foundation
import Testing
@testable import VoyageCore

@Suite struct WeeklyMailTests {
    private func run(_ journey: inout JourneyState, delivery: DeliveryTime = .standard, calendar: Calendar = careCalendar) {
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: calendar, deliveryTime: delivery)
    }

    private func settledWeek() -> (JourneyState, CareState) {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-08", fuel: 90_000_000), finalized: [
            DayUsage(date: "2026-11-02", fuel: 10_000, byClient: ["codex": 7_500, "claude": 2_500]),
            DayUsage(date: "2026-11-07", fuel: 20_000, byClient: ["codex": 20_000]),
        ], calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        return (journey, care)
    }

    @Test func sixFinalDaysExcludeSundayAndRespectLocalDeliveryTime() throws {
        var (journey, care) = settledWeek()
        let due = careCalendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14, minute: 30))!
        let delivery = DeliveryTime(hour: 14, minute: 30)!
        run(&journey, delivery: delivery)
        let mail = try #require(journey.letters.last)
        let summary = try #require(mail.weeklySummary)
        #expect(mail.kind == .weekly && mail.date == "2026-11-08" && mail.deliverAt == due)
        #expect(summary.weekStart == "2026-11-02" && summary.weekEnd == "2026-11-07")
        #expect(summary.fuel == 30_000 && summary.byClient == ["codex": 27_500, "claude": 2_500])
        #expect(summary.previousFuel == nil)
        #expect(mail.vehicles == [.init(client: "codex", percent: 92), .init(client: "claude", percent: 8)])
        #expect(!journey.deliveredLetters(now: due.addingTimeInterval(-1)).contains(mail))
        #expect(journey.deliveredLetters(now: due).contains(mail))
        #expect(!mail.texts!["en"]!.contains("last week"))
        #expect(mail.texts!["en"]!.contains("Nov 7"))
        #expect(mail.texts!["zh-Hans"]!.contains("11月7日"))
        #expect(!mail.texts!["en"]!.contains("2026-11-07"))
        #expect(!mail.texts!["en"]!.contains("9,000 km"))
    }

    @Test func deliveryUsesCalendarDaysAcrossDSTAndLocalSunday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var (journey, care) = engineState()
        journey.weeklyMailEligibleFrom = "2026-10-01"
        journey.startDate = "2026-10-01"
        journey.openDate = "2026-11-01"
        var day = DayRecord(); day.mainWindowOpened = true
        journey.days["2026-10-31"] = day
        run(&journey, delivery: DeliveryTime(hour: 9, minute: 30)!, calendar: calendar)
        let mail = try #require(journey.letters.last)
        #expect(mail.weeklySummary?.weekStart == "2026-10-26" && mail.weeklySummary?.weekEnd == "2026-10-31")
        #expect(mail.deliverAt == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 30)))
        #expect(!journey.deliveredLetters(now: mail.deliverAt.addingTimeInterval(-1)).contains(mail))
    }

    @Test func onlyLatestSundayIsGeneratedOnCatchUpAndReplayIsIdempotent() throws {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-24"), finalized: [
            DayUsage(date: "2026-11-02", fuel: 100), DayUsage(date: "2026-11-09", fuel: 200),
            DayUsage(date: "2026-11-16", fuel: 300),
        ], calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        run(&journey)
        #expect(journey.letters.filter { $0.kind == .weekly }.map(\.date) == ["2026-11-22"])
        let saved = journey
        run(&journey)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey == saved)
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        run(&journey)
        #expect(journey == saved)
        journey.sync(today: DayUsage(date: "2026-12-08"), finalized: [DayUsage(date: "2026-11-30", fuel: 400)], calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        run(&journey)
        #expect(journey.letters.filter { $0.kind == .weekly }.map(\.date) == ["2026-11-22", "2026-12-06"])
    }

    @Test func inactiveWeekAndSundayOnlyActivityNeverProduceMail() {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-08", fuel: 100), calendar: careCalendar, catalog: testCatalog)
        journey.days["2026-11-08"]?.mainWindowOpened = true
        run(&journey)
        #expect(!journey.letters.contains { $0.kind == .weekly })
        #expect(journey.lastWeeklyMailSunday == "2026-11-08")
        journey.sync(today: DayUsage(date: "2026-11-24"), calendar: careCalendar, catalog: testCatalog)
        run(&journey)
        #expect(!journey.letters.contains { $0.kind == .weekly }) // No fallback to an older active week.
    }

    @Test func saturdayNeverCreatesTheUpcomingSundayLetter() {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-07"), finalized: [DayUsage(date: "2026-11-02", fuel: 100)], calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        run(&journey)
        #expect(!journey.letters.contains { $0.kind == .weekly })
    }

    @Test func savedTextAndDataSurviveNewContentAndDeliveryPreferences() throws {
        var (journey, care) = settledWeek()
        run(&journey)
        let saved = try #require(journey.letters.last)
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("weekly-mail.json")
        var content = try JSONDecoder().decode(WeeklyMailContent.self, from: Data(contentsOf: file))
        content.openings = [["en": "Changed opening.", "zh-Hans": "修改后的开头。"]]
        content.version += 1
        try JSONEncoder().encode(content).write(to: file)
        let changed = try CityCatalog.load(directory: box.directory)
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        CareEngine.writeWeeklyMail(journey: &journey, catalog: changed, calendar: careCalendar, deliveryTime: DeliveryTime(hour: 20, minute: 0)!)
        #expect(journey.letters.last == saved)
        #expect(journey.letters.last?.weeklySummary == saved.weeklySummary)
    }

    @Test func windowVisitWithoutUsageGetsCompleteFallbackAndNoTrend() throws {
        var (journey, care) = engineState()
        journey.days["2026-11-05", default: DayRecord()].mainWindowOpened = true
        journey.sync(today: DayUsage(date: "2026-11-08"), calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        run(&journey)
        let mail = try #require(journey.letters.last)
        #expect(mail.kind == .weekly && mail.fuel == 0 && mail.vehicles.isEmpty)
        #expect(mail.weeklySummary?.highlight == nil)
        #expect(mail.texts?["en"]?.contains("no big event") == true)
        #expect(mail.texts?["zh-Hans"]?.contains("没有要圈出来的大事") == true)
        #expect(care.companionDays.isEmpty)
    }

    @Test(arguments: [0, 10_000, 60_000])
    func trendUsesTheSameSixDaysOnly(previous: Int) throws {
        var (journey, care) = settledWeek()
        for day in 26...31 { journey.days["2026-10-\(day)"] = DayRecord() }
        journey.days["2026-10-26"]?.fuel = previous
        journey.days["2026-11-01"]?.fuel = 50_000_000 // Prior Sunday is excluded too.
        run(&journey)
        let mail = try #require(journey.letters.last)
        #expect(mail.weeklySummary?.previousFuel == previous)
        let text = mail.texts!["en"]!
        #expect(text.contains(previous == 0 ? "on the road again" : previous == 10_000 ? "200% farther" : "50% less"))
    }

    @Test func oldVersionSixSaveStartsNextSundayEvenWhenUpgradeIsSunday() throws {
        let url = try #require(Bundle.module.url(forResource: "journey-v6", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "weeklyMailEligibleFrom")
        json.removeValue(forKey: "lastWeeklyMailSunday")
        var journey = try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: json))
        let care = engineState().1
        #expect(journey.weeklyMailEligibleFrom == nil)
        journey.enableWeeklyMail(on: "2026-11-08", calendar: careCalendar)
        #expect(journey.weeklyMailEligibleFrom == "2026-11-15")
        journey.sync(today: DayUsage(date: "2026-11-08"), finalized: [DayUsage(date: "2026-11-02", fuel: 100)], calendar: careCalendar, catalog: testCatalog)
        run(&journey)
        #expect(!journey.letters.contains { $0.kind == .weekly })
        journey.sync(today: DayUsage(date: "2026-11-15"), finalized: [DayUsage(date: "2026-11-09", fuel: 100)], calendar: careCalendar, catalog: testCatalog)
        run(&journey)
        #expect(journey.letters.filter { $0.kind == .weekly }.map(\.date) == ["2026-11-15"])
    }

    @Test func generationAndRepeatedCareProcessingDoNotTouchRewardsPromisesBagOrHabits() throws {
        var (journey, care) = settledWeek()
        let source = try #require(journey.letters.first { !$0.replyOptions.isEmpty })
        CareEngine.reply(letterId: source.id, replyId: source.replyOptions[0].id, date: "2026-11-08", journey: &journey, care: &care)
        care.pity = 8
        care.bag.todayItem = "sketchbook"
        let before = care
        run(&journey)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(care == before)
        let mail = try #require(journey.letters.last)
        #expect(mail.rewards == StoryRewards() && mail.carriedItem == nil && mail.itemTriggered == nil)
        #expect(mail.replyOptions.isEmpty && mail.fulfilledReplyId == nil && mail.rewardItems.isEmpty)
        CareEngine.markCompanion(date: "2026-11-08", care: &care, calendar: careCalendar)
        #expect(care.companionDays == ["2026-11-08"])
    }

    @Test(arguments: [UInt32(1), 7, 42])
    func doublingUsageKeepsMailDeliveryDropsAndRaisingIdentical(seed: UInt32) throws {
        func simulate(_ multiplier: Int) -> (JourneyState, CareState) {
            var (journey, care) = engineState(seed: seed)
            for day in 1...22 {
                let date = "2026-11-\(String(format: "%02d", day))"
                let yesterday = journey.openDate
                journey.sync(today: DayUsage(date: date, fuel: day % 3 == 0 ? 10_000 * multiplier : 0, byClient: day % 3 == 0 ? ["codex": 10_000 * multiplier] : [:]),
                             finalized: [DayUsage(date: yesterday, fuel: journey.fuel(on: yesterday))], calendar: careCalendar, catalog: testCatalog)
                CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
                run(&journey)
                CareEngine.open(at: DayKey.date(from: date, calendar: careCalendar)!, journey: &journey, care: &care, catalog: testCatalog, calendar: careCalendar)
                for letter in journey.deliveredLetters(now: DayKey.date(from: date, calendar: careCalendar)!) where !letter.read {
                    journey.markRead(letter.id)
                    CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar)
                }
                if let letter = journey.letters.first(where: { !$0.replyOptions.isEmpty && $0.selectedReplyId == nil }) {
                    CareEngine.reply(letterId: letter.id, replyId: letter.replyOptions[0].id, date: date, journey: &journey, care: &care)
                }
            }
            return (journey, care)
        }
        let (a, ca) = simulate(1), (b, cb) = simulate(2)
        #expect(a.letters.map(\.kind) == b.letters.map(\.kind))
        #expect(a.letters.map(\.deliverAt) == b.letters.map(\.deliverAt))
        #expect(a.letters.map(\.rewards) == b.letters.map(\.rewards))
        #expect(a.letters.map(\.fulfilledReplyId) == b.letters.map(\.fulfilledReplyId))
        #expect(ca == cb)
        #expect(a.letters.filter { $0.kind == .weekly }.count == 3)
        #expect(a.letters.filter { $0.kind == .weekly }.map(\.fuel) != b.letters.filter { $0.kind == .weekly }.map(\.fuel))
    }

    @Test func highlightPriorityAndSnapshotsSurviveContentChangesAndDuplicateSavedIDs() throws {
        var (journey, care) = settledWeek()
        journey.letters = [engineLetter(1, date: "2026-11-03"), engineLetter(2, date: "2026-11-04")]
        journey.letters[0].fulfilledReplyId = "look-closer"
        journey.letters[0].learnedTexts = ["en": "A saved lesson.", "zh-Hans": "一件学会的事。"]
        journey.letters[1].rewards.dropRarity = "rare"
        journey.letters[1].rewards.itemIds = [testCatalog.items.all.first { $0.rarity == "rare" }!.id]
        journey.days["2026-11-05"]?.newCountries = ["JP"]
        journey.letters.append(journey.letters[0]) // Persisted IDs are not assumed unique.
        let base = journey
        for expected in ["fulfilled", "rare", "country", "longest"] {
            run(&journey)
            #expect(journey.letters.last?.weeklySummary?.highlight?.kind == expected)
            let saved = journey.letters.last
            journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
            run(&journey)
            #expect(journey.letters.last == saved)
            journey = base
            if expected == "fulfilled" { journey.letters.removeAll { $0.fulfilledReplyId != nil } }
            if expected == "rare" || expected == "country" {
                journey.letters.removeAll { $0.fulfilledReplyId != nil || $0.rewards.dropRarity == "rare" }
            }
            if expected == "country" { journey.days["2026-11-05"]?.newCountries = [] }
        }
    }

    @Test(arguments: ["translation", "unknownSlot", "missingLine", "emptyOpening"])
    func contentValidationRejectsIncompleteWeeklyCopy(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("weekly-mail.json")
        var content = try JSONDecoder().decode(WeeklyMailContent.self, from: Data(contentsOf: file))
        switch failure {
        case "translation": content.lines["quiet"]?.removeValue(forKey: "en")
        case "unknownSlot": content.lines["quiet"]?["en"] = "{unsupported}"
        case "missingLine": content.lines.removeValue(forKey: "summary")
        default: content.openings = []
        }
        try JSONEncoder().encode(content).write(to: file)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "weeklyMail" })
        #expect(throws: (any Error).self) { try CityCatalog.load(directory: box.directory) }
    }
}
