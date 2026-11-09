import Foundation
import Testing
@testable import VoyageCore

private let usageEventCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    return calendar
}()

private func usageEventDate(_ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
    usageEventCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func usageEventJourney(seed: UInt32 = 7) -> JourneyState {
    JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-01", now: usageEventDate(1), catalog: testCatalog)
}

private func usageEventSettle(_ fuel: Int, clients: [String: Int] = [:], journey: inout JourneyState) {
    let date = journey.openDate
    journey.sync(today: DayUsage(date: DayKey.next(date, calendar: usageEventCalendar)),
                 finalized: [DayUsage(date: date, fuel: fuel, byClient: clients)],
                 calendar: usageEventCalendar, catalog: testCatalog)
}

private func usageEventHistory(_ fuels: [Int], seed: UInt32 = 7) -> JourneyState {
    var journey = usageEventJourney(seed: seed)
    for fuel in fuels { usageEventSettle(fuel, journey: &journey) }
    return journey
}

private func usageEventNotes(_ journey: JourneyState, on date: String) -> [UsageEventNote] {
    journey.letters.first { $0.kind == .daily && $0.date == date }?.usageEventNotes ?? []
}

@Suite struct UsageEventTests {
    @Test(arguments: [300, 301])
    func teaStrictlyExceedsTwiceTheEvenMedian(finalFuel: Int) {
        var journey = usageEventHistory(Array(repeating: 100, count: 7) + Array(repeating: 200, count: 7))
        let date = journey.openDate
        usageEventSettle(finalFuel, journey: &journey)
        #expect(usageEventNotes(journey, on: date).count == (finalFuel > 300 ? 1 : 0))
        #expect(journey.days[date]?.finalUsageFuel == finalFuel)
    }

    @Test(arguments: [0, 1, 3, 13])
    func teaNeedsFourteenPriorActiveDays(activeDays: Int) {
        var journey = usageEventHistory(Array(repeating: 100, count: activeDays))
        let date = journey.openDate
        usageEventSettle(10_000, journey: &journey)
        #expect(usageEventNotes(journey, on: date).isEmpty)
        #expect(journey.usageEvents?.pendingTea == nil)
    }

    @Test func medianUsesTheLatestFourteenActiveFinalDaysAndSkipsZeroDays() {
        var journey = usageEventHistory([100_000, 100_000] + Array(repeating: [100, 0], count: 14).flatMap { $0 })
        let date = journey.openDate
        usageEventSettle(201, journey: &journey)
        #expect(usageEventNotes(journey, on: date).count == 1)
    }

    @Test(arguments: [200, 201])
    func intermediateSpikeNeverDecidesTeaAndFinalDownwardCorrectionIsAuthoritative(finalFuel: Int) {
        var spiked = usageEventHistory(Array(repeating: 100, count: 14))
        var direct = spiked
        let date = spiked.openDate
        spiked.sync(today: DayUsage(date: date, fuel: 10_000), calendar: usageEventCalendar, catalog: testCatalog)
        #expect(spiked.usageEvents?.pendingTea == nil)
        #expect(usageEventNotes(spiked, on: date).isEmpty)
        #expect(spiked.days[date]?.finalUsageFuel == nil)
        usageEventSettle(finalFuel, journey: &spiked)
        usageEventSettle(finalFuel, journey: &direct)
        #expect(spiked.days[date]?.fuel == 10_000) // Existing mileage remains a monotonic ledger.
        #expect(spiked.days[date]?.finalUsageFuel == finalFuel)
        #expect(usageEventNotes(spiked, on: date) == usageEventNotes(direct, on: date))
        #expect(usageEventNotes(spiked, on: date).count == (finalFuel > 200 ? 1 : 0))
        let next = spiked.openDate
        usageEventSettle(201, journey: &spiked)
        usageEventSettle(201, journey: &direct)
        #expect(usageEventNotes(spiked, on: next) == usageEventNotes(direct, on: next))
    }

    @Test func correctedZeroUsageDoesNotBecomeAnActiveDayInLaterTeaBaselines() {
        var journey = usageEventHistory(Array(repeating: 100, count: 7) + Array(repeating: 200, count: 7))
        let correctedDate = journey.openDate
        journey.sync(today: DayUsage(date: correctedDate, fuel: 10_000), calendar: usageEventCalendar, catalog: testCatalog)
        usageEventSettle(0, journey: &journey)
        #expect(journey.days[correctedDate]?.finalUsageFuel == 0)
        #expect(usageEventNotes(journey, on: correctedDate).isEmpty)
        let date = journey.openDate
        usageEventSettle(350, journey: &journey)
        #expect(usageEventNotes(journey, on: date).count == 1)
    }

    @Test func oldMileageWithoutAKnownFinalValueIsNotATeaBaseline() {
        var journey = usageEventHistory(Array(repeating: 100, count: 14))
        for date in journey.days.keys { journey.days[date]?.finalUsageFuel = nil }
        let date = journey.openDate
        usageEventSettle(10_000, journey: &journey)
        #expect(usageEventNotes(journey, on: date).isEmpty)
        #expect(journey.usageEvents?.pendingTea == nil)
    }

    @Test func anUnknownRecentDayCannotBeReplacedWithAnOlderFinalSample() {
        var journey = usageEventHistory(Array(repeating: 100, count: 16))
        journey.days["2026-11-15"]?.finalUsageFuel = nil
        let date = journey.openDate
        usageEventSettle(1_000, journey: &journey)
        #expect(usageEventNotes(journey, on: date).isEmpty)
    }

    @Test(arguments: Array(UInt32(0)..<8))
    func proportionalUsageKeepsEventResultsIdentical(seed: UInt32) {
        func run(_ multiplier: Int) -> JourneyState {
            var journey = usageEventJourney(seed: seed)
            var observer = NightWorkObserver()
            for (index, fuel) in (Array(repeating: 100, count: 14) + [201, 0, 100, 500, 100]).enumerated() {
                let clients = [index < 16 ? "claude-code" : "antigravity-cli": fuel * multiplier]
                let date = journey.openDate
                let start = DayKey.date(from: date, calendar: usageEventCalendar)!
                observer.observe(.init(date: date), at: start.addingTimeInterval(23 * 3_600),
                                 journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
                observer.observe(.init(date: date, fuel: fuel * multiplier), at: start.addingTimeInterval(23 * 3_600 + 60),
                                 journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
                usageEventSettle(fuel * multiplier, clients: clients, journey: &journey)
            }
            return journey
        }
        let first = run(1), second = run(2)
        #expect(first.usageEvents == second.usageEvents)
        #expect(first.letters.map(\.usageEventNotes) == second.letters.map(\.usageEventNotes))
        #expect(first.letters.map(\.kind) == second.letters.map(\.kind))
    }

    @Test func firstVoyagesUseCanonicalToolIdsOnlyOnceAndIgnoreZeroUsage() {
        var journey = usageEventJourney()
        journey.sync(today: DayUsage(date: journey.openDate, fuel: 30,
                                    byClient: ["claude-code": 10, "claude": 20, "pi": 0]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets == [ToolTicket(toolID: "claude", date: "2026-11-01")])
        let pending = journey.usageEvents?.pendingFirstVoyage
        journey.sync(today: DayUsage(date: journey.openDate, fuel: 40, byClient: ["Claude Code": 40]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets.count == 1)
        #expect(journey.usageEvents?.pendingFirstVoyage == pending)
        usageEventSettle(40, clients: ["claude-code": 40], journey: &journey)
        journey.sync(today: DayUsage(date: journey.openDate, fuel: 30,
                                    byClient: ["antigravity-cli": 10, "antigravity-extension": 20]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        journey.sync(today: DayUsage(date: journey.openDate, fuel: 40, byClient: ["antigravity": 40]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets == [
            ToolTicket(toolID: "claude", date: "2026-11-01"),
            ToolTicket(toolID: "antigravity", date: "2026-11-02"),
        ])
        #expect(!journey.usageEvents!.seenTools.contains("pi"))
    }

    @Test(arguments: [
        ["antigravity-cli", "antigravity-extension", "antigravity"],
        ["micode", "micode-desktop", "mimo"],
        ["kilocode", "kilo"],
        ["devin-cli", "devin-desktop", "devin"],
        ["claude-code", "Claude Code", "claude"],
    ])
    func upstreamAliasFamiliesShareOneTicket(aliases: [String]) {
        var journey = usageEventJourney()
        for (index, alias) in aliases.enumerated() {
            journey.sync(today: DayUsage(date: journey.openDate, fuel: index + 1, byClient: [alias: index + 1]),
                         calendar: usageEventCalendar, catalog: testCatalog)
        }
        #expect(journey.usageEvents?.tickets.map(\.toolID) == [aliases.last!])
    }

    @Test func sameDayFirstVoyagePresentationDoesNotDependOnScanOrder() {
        var incremental = usageEventJourney(), together = incremental
        incremental.sync(today: .init(date: incremental.openDate, fuel: 100, byClient: ["gemini": 100]),
                         calendar: usageEventCalendar, catalog: testCatalog)
        let final = DayUsage(date: incremental.openDate, fuel: 200, byClient: ["gemini": 100, "claude": 100])
        incremental.sync(today: final, calendar: usageEventCalendar, catalog: testCatalog)
        together.sync(today: final, calendar: usageEventCalendar, catalog: testCatalog)
        #expect(incremental.usageEvents == together.usageEvents)
        usageEventSettle(200, clients: final.byClient, journey: &incremental)
        usageEventSettle(200, clients: final.byClient, journey: &together)
        #expect(incremental.letters.map(\.usageEventNotes) == together.letters.map(\.usageEventNotes))
    }

    @Test func cacheOnlyToolUsageWaitsForATravelLetterAndCanBeObservedAtNight() {
        var journey = usageEventJourney()
        let date = journey.openDate
        let first = DayDetail(date: date, rows: [.init(client: "claude-code", model: "test", tokens: .init(cacheRead: 100))]).usage
        let next = DayDetail(date: date, rows: [.init(client: "claude", model: "test", tokens: .init(cacheRead: 101))]).usage
        journey.sync(today: first, calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.totalFuel == 0 && journey.letters.count == 1)
        #expect(journey.usageEvents?.tickets == [.init(toolID: "claude", date: date)])
        let pending = journey.usageEvents?.pendingFirstVoyage
        var observer = NightWorkObserver()
        observer.observe(first, at: usageEventDate(1, hour: 23), journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(next, at: usageEventDate(1, hour: 23, minute: 1), journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap?.date == date)
        journey.sync(today: .init(date: "2026-11-02"), finalized: [next], calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.letters.count == 1 && journey.usageEvents?.pendingFirstVoyage == pending)
        usageEventSettle(0, journey: &journey)
        usageEventSettle(100, clients: ["claude": 100], journey: &journey)
        #expect(journey.usageEvents?.tickets.count == 1)
        #expect(journey.letters.last?.usageEventNotes == [pending!])
    }

    @Test func upgradeBaselinesToolsInDayRecordsAndLettersWithoutIssuingTickets() {
        var journey = usageEventJourney()
        journey.usageEvents = nil
        journey.days["2026-10-31", default: DayRecord()].byClient = ["claude-code": 100, "pi": 0]
        var letter = engineLetter(1, date: "2026-10-31")
        letter.vehicles = [.init(client: "antigravity-cli", percent: 100)]
        journey.letters.append(letter)
        let savedLetters = journey.letters
        journey.enableUsageEvents(on: "2026-11-01")
        #expect(Set(journey.usageEvents!.seenTools) == ["claude", "antigravity"])
        #expect(journey.usageEvents?.tickets.isEmpty == true)
        #expect(journey.usageEvents?.pendingFirstVoyage == nil)
        #expect(journey.letters == savedLetters)
        journey.sync(today: DayUsage(date: "2026-11-01", fuel: 300,
                                    byClient: ["claude": 100, "antigravity-extension": 100, "codex": 100]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets == [ToolTicket(toolID: "codex", date: "2026-11-01")])
        let enabled = journey.usageEvents
        journey.enableUsageEvents(on: "2026-11-30")
        #expect(journey.usageEvents == enabled)
    }

    @Test func upgradeCatchUpKeepsTheFirstDateOfAToolNotPreviouslyInTheSave() {
        var journey = usageEventJourney()
        journey.sync(today: .init(date: journey.openDate, fuel: 100, byClient: ["codex": 100]),
                     calendar: usageEventCalendar, catalog: testCatalog)
        journey.usageEvents = nil
        let finals = [
            DayUsage(date: "2026-11-01", fuel: 100, byClient: ["codex": 100]),
            DayDetail(date: "2026-11-02", rows: [.init(client: "claude-code", model: "test", tokens: .init(cacheRead: 100))]).usage,
            DayUsage(date: "2026-11-03", fuel: 100, byClient: ["claude": 100]),
        ]
        journey.sync(today: .init(date: "2026-11-04"), finalized: finals, calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets == [.init(toolID: "claude", date: "2026-11-02")])
        #expect(journey.letters.filter { $0.usageEventNotes != nil }.map(\.date) == ["2026-11-03"])
        let saved = journey
        journey.sync(today: .init(date: "2026-11-04"), finalized: finals, calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey == saved)
    }

    @Test func pendingCategoriesWaitThroughPostcardsAndQuietDaysForOneTravelLetter() throws {
        var journey = usageEventJourney()
        let tea = testCatalog.usageEvents.note("tea", seed: journey.seed, date: journey.openDate)
        let first = testCatalog.usageEvents.note("firstVoyage", seed: journey.seed, date: journey.openDate, tool: "codex")
        journey.usageEvents?.pendingTea = tea
        journey.usageEvents?.pendingFirstVoyage = first
        journey.days[journey.openDate, default: DayRecord()].mainWindowOpened = true
        usageEventSettle(0, journey: &journey)
        usageEventSettle(0, journey: &journey)
        #expect(journey.letters.map(\.kind) == [.logbook, .postcard])
        #expect(journey.letters.allSatisfy { $0.usageEventNotes == nil })
        #expect(journey.usageEvents?.pendingTea == tea)
        #expect(journey.usageEvents?.pendingFirstVoyage == first)
        journey.recordFirstVoyages(DayUsage(date: journey.openDate, fuel: 300,
                                           byClient: ["claude": 100, "gemini": 100, "cursor": 100]),
                                  content: testCatalog.usageEvents)
        #expect(journey.usageEvents?.pendingFirstVoyage == first)
        usageEventSettle(100, journey: &journey)
        let daily = try #require(journey.letters.last)
        #expect(daily.kind == .daily && daily.usageEventNotes == [tea, first])
        #expect(journey.usageEvents?.pendingTea == nil && journey.usageEvents?.pendingFirstVoyage == nil)
        usageEventSettle(100, journey: &journey)
        #expect(journey.letters.last?.usageEventNotes == nil)
    }

    @Test func eventTextIsBilingualAndFrozenEvenBeforeCompositionAndAfterCareReplay() throws {
        var journey = usageEventHistory(Array(repeating: 100, count: 14))
        let date = journey.openDate
        usageEventSettle(201, clients: ["codex": 201], journey: &journey)
        let notes = try #require(journey.letters.last?.usageEventNotes)
        #expect(notes.count == 2)
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("usage-events.json") { json in
            json["version"] = 999
            for kind in ["tea", "nightcap", "firstVoyage"] {
                var lines = json[kind] as! [[String: Any]]
                for index in lines.indices {
                    lines[index]["texts"] = ["en": kind == "firstVoyage" ? "Changed {tool}." : "Changed.",
                                             "zh-Hans": kind == "firstVoyage" ? "改过的{tool}。" : "改过了。"]
                }
                json[kind] = lines
            }
        }
        let changed = try CityCatalog.load(directory: box.directory)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate, calendar: usageEventCalendar)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: changed)
        let letter = try #require(journey.letters.first { $0.kind == .daily && $0.date == date })
        for language in Language.allCases {
            let body = try #require(letter.texts?[language.rawValue])
            for note in notes {
                let text = try #require(note.texts[language.rawValue])
                #expect(!text.isEmpty && body.components(separatedBy: text).count == 2)
            }
            #expect(!body.contains("Changed") && !body.contains("改过"))
        }
        let saved = journey
        care.processedLetterIds = []
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: changed)
        #expect(journey == saved)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
    }

    @Test func catchUpAndRepeatedScansCannotDuplicateTeaTicketsOrAttachedNotes() throws {
        let fuels = Array(repeating: 100, count: 14) + [201, 201, 0, 500]
        var incremental = usageEventJourney()
        var finalized: [DayUsage] = []
        for (index, fuel) in fuels.enumerated() {
            let date = incremental.openDate
            let clients = [index < 15 ? "claude-code" : "antigravity-cli": fuel]
            finalized.append(DayUsage(date: date, fuel: fuel, byClient: clients))
            usageEventSettle(fuel, clients: clients, journey: &incremental)
        }
        var caughtUp = usageEventJourney()
        caughtUp.sync(today: DayUsage(date: incremental.openDate), finalized: Array(finalized.reversed()),
                      calendar: usageEventCalendar, catalog: testCatalog)
        #expect(caughtUp == incremental)
        let saved = caughtUp
        caughtUp.sync(today: DayUsage(date: caughtUp.openDate), finalized: finalized + finalized,
                      calendar: usageEventCalendar, catalog: testCatalog)
        caughtUp = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(caughtUp))
        caughtUp.sync(today: DayUsage(date: caughtUp.openDate), finalized: finalized,
                      calendar: usageEventCalendar, catalog: testCatalog)
        #expect(caughtUp == saved)
        #expect(caughtUp.usageEvents?.tickets.count == 2)
        #expect(Set(caughtUp.usageEvents!.tickets.map(\.toolID)).count == 2)
    }

    @Test func nightWorkNeedsAnObservedIncrementAndNeverReplaysWorkWhileNotRunning() {
        var journey = usageEventJourney()
        var observer = NightWorkObserver()
        observer.observe(DayUsage(date: "2026-11-02", fuel: 1_000), at: usageEventDate(2, hour: 23),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap == nil)
        observer = NightWorkObserver() // A new process has no earlier scan timestamp.
        observer.observe(DayUsage(date: "2026-11-04", fuel: 5_000), at: usageEventDate(4, hour: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(DayUsage(date: "2026-11-04", fuel: 5_000), at: usageEventDate(4, hour: 1, minute: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap == nil)
        observer.observe(DayUsage(date: "2026-11-04", fuel: 5_001), at: usageEventDate(4, hour: 1, minute: 2),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap?.date == "2026-11-04")
        #expect(journey.usageEvents?.nightcapWeeks == ["2026-11-02"])
        #expect(journey.letters.count == 1)
    }

    @Test func nightcapIsWeeklyByLocalMondayAndResetsAcrossMidnightIntoANewWeek() {
        var journey = usageEventJourney()
        var observer = NightWorkObserver()
        func observe(_ day: Int, _ hour: Int, _ minute: Int, _ fuel: Int) {
            let date = usageEventDate(day, hour: hour, minute: minute)
            observer.observe(DayUsage(date: DayKey.string(from: date, calendar: usageEventCalendar), fuel: fuel), at: date,
                             journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        }
        observe(2, 22, 59, 100)
        observe(2, 23, 0, 100)
        #expect(journey.usageEvents?.nightcap == nil)
        observe(2, 23, 1, 101)
        let first = journey.usageEvents?.nightcap
        #expect(first?.date == "2026-11-02")
        #expect(journey.nightcapNote(at: usageEventDate(3, hour: 4, minute: 59), calendar: usageEventCalendar) == first?.note)
        #expect(journey.nightcapNote(at: usageEventDate(3, hour: 5), calendar: usageEventCalendar) == nil)
        observe(3, 0, 1, 1)
        observe(8, 23, 59, 1)
        #expect(journey.usageEvents?.nightcap == first)
        observe(9, 0, 1, 1)
        #expect(journey.usageEvents?.nightcap?.date == "2026-11-09")
        #expect(journey.usageEvents?.nightcapWeeks == ["2026-11-02", "2026-11-09"])
        observe(9, 0, 2, 2)
        #expect(journey.usageEvents?.nightcapWeeks.count == 2)
    }

    @Test func midnightIncrementBelongsToTheNewLocalDayEvenIfItsTotalIsSmaller() {
        var journey = usageEventJourney()
        var observer = NightWorkObserver()
        observer.observe(DayUsage(date: "2026-11-01", fuel: 1_000), at: usageEventDate(1, hour: 23, minute: 59),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(DayUsage(date: "2026-11-02"), at: usageEventDate(2, hour: 0),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap == nil)
        observer.observe(DayUsage(date: "2026-11-02", fuel: 1), at: usageEventDate(2, hour: 0, minute: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap?.date == "2026-11-02")
        #expect(journey.usageEvents?.nightcap?.observedAt == usageEventDate(2, hour: 0, minute: 1))
        #expect(journey.usageEvents?.nightcapWeeks == ["2026-11-02"])
    }

    @Test(arguments: [4, 5, 22, 23])
    func nightHoursHaveInclusiveElevenAndExclusiveFive(hour: Int) {
        var journey = usageEventJourney()
        var observer = NightWorkObserver()
        observer.observe(DayUsage(date: "2026-11-02", fuel: 100), at: usageEventDate(2, hour: hour),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(DayUsage(date: "2026-11-02", fuel: 101), at: usageEventDate(2, hour: hour, minute: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect((journey.usageEvents?.nightcap != nil) == (hour == 4 || hour == 23))
    }

    @Test func staleDayScansDoNotAttributeHistoricalUsageToTonight() {
        var journey = usageEventJourney()
        var observer = NightWorkObserver()
        observer.observe(DayUsage(date: "2026-11-01", fuel: 100), at: usageEventDate(1, hour: 23),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(DayUsage(date: "2026-11-01", fuel: 500), at: usageEventDate(2, hour: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        observer.observe(DayUsage(date: "2026-11-02", fuel: 500), at: usageEventDate(2, hour: 1, minute: 1),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap == nil)
        observer.observe(DayUsage(date: "2026-11-02", fuel: 501), at: usageEventDate(2, hour: 1, minute: 2),
                         journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
        #expect(journey.usageEvents?.nightcap?.date == "2026-11-02")
    }

    @Test(arguments: Array(UInt32(0)..<4))
    func eventsCannotChangeCareRewardsPromisesCompanionDaysOrAppearance(seed: UInt32) {
        func run(eventsEnabled: Bool) -> (JourneyState, CareState) {
            var journey = usageEventJourney(seed: seed)
            if !eventsEnabled {
                journey.usageEvents = UsageEvents(eligibleFrom: "2099-01-01")
                journey.usageEvents?.seenTools = ["claude", "codex"]
            }
            var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate, calendar: usageEventCalendar)
            var observer = NightWorkObserver()
            for (index, fuel) in (Array(repeating: 100, count: 14) + [201, 100, 500, 100]).enumerated() {
                let date = journey.openDate
                if eventsEnabled {
                    let start = DayKey.date(from: date, calendar: usageEventCalendar)!
                    observer.observe(DayUsage(date: date, fuel: 0), at: start.addingTimeInterval(23 * 3_600),
                                     journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
                    observer.observe(DayUsage(date: date, fuel: fuel), at: start.addingTimeInterval(23 * 3_600 + 60),
                                     journey: &journey, content: testCatalog.usageEvents, calendar: usageEventCalendar)
                }
                usageEventSettle(fuel, clients: [index < 14 ? "claude" : "codex": fuel], journey: &journey)
                CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
                if let letter = journey.letters.last, let reply = letter.replyOptions.first {
                    CareEngine.reply(letterId: letter.id, replyId: reply.id, date: date, journey: &journey, care: &care)
                }
                CareEngine.markCompanion(date: date, care: &care, calendar: usageEventCalendar)
            }
            return (journey, care)
        }
        let (withEvents, withCare) = run(eventsEnabled: true)
        let (withoutEvents, withoutCare) = run(eventsEnabled: false)
        #expect(withCare == withoutCare)
        #expect(withEvents.pet == withoutEvents.pet)
        #expect(withEvents.route == withoutEvents.route && withEvents.stamps == withoutEvents.stamps)
        #expect(withEvents.letters.map(\.kind) == withoutEvents.letters.map(\.kind))
        #expect(withEvents.letters.map(\.rewards) == withoutEvents.letters.map(\.rewards))
        #expect(withEvents.letters.map(\.rewardItems) == withoutEvents.letters.map(\.rewardItems))
        #expect(withEvents.letters.map(\.fulfilledReplyId) == withoutEvents.letters.map(\.fulfilledReplyId))
        #expect(withEvents.letters.map(\.carriedItem) == withoutEvents.letters.map(\.carriedItem))
        #expect(withEvents.letters.map(\.itemTriggered) == withoutEvents.letters.map(\.itemTriggered))
        #expect(withEvents.letters.map(\.storyId) == withoutEvents.letters.map(\.storyId))
        #expect(withEvents.usageEvents?.tickets.count == 2)
        #expect(withEvents.usageEvents?.nightcap != nil)
        #expect(withoutEvents.usageEvents?.tickets.isEmpty == true)
    }

    @Test(arguments: Array(1...6))
    func frozenJourneyVersionsDecodeWithoutUsageEventFieldsOrRetroactiveTickets(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-usage-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try #require(Bundle.module.url(forResource: "journey-v\(version)", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json.removeValue(forKey: "usageEvents") // Version 6 also shipped through earlier M2 development steps.
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("journey.json"))
        let store = SaveStore(directory: directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(var journey) = store.journey else { Issue.record("Journey v\(version) did not decode"); return }
        #expect(journey.version == JourneyState.currentVersion)
        #expect(journey.usageEvents == nil)
        let known = Set((journey.days.values.flatMap { $0.byClient.filter { $0.value > 0 }.map(\.key) }
            + journey.letters.flatMap { $0.vehicles.map(\.client) }).map(Vehicle.normalizeClientID).filter { !$0.isEmpty })
        journey.enableUsageEvents(on: journey.openDate)
        #expect(Set(journey.usageEvents!.seenTools) == known)
        #expect(journey.usageEvents?.tickets.isEmpty == true)
        #expect(journey.usageEvents?.pendingTea == nil && journey.usageEvents?.pendingFirstVoyage == nil)
        journey.sync(today: DayUsage(date: journey.openDate, fuel: known.count,
                                    byClient: Dictionary(known.map { ($0, 1) }, uniquingKeysWith: { first, _ in first })),
                     calendar: usageEventCalendar, catalog: testCatalog)
        #expect(journey.usageEvents?.tickets.isEmpty == true)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
    }

    @Test func contentProvidesSeededOriginalBilingualAlternativesForEveryEvent() {
        let content = testCatalog.usageEvents
        #expect(content.tea.count >= 4 && content.nightcap.count >= 4 && content.firstVoyage.count >= 4)
        #expect(Set((content.tea + content.nightcap + content.firstVoyage).map(\.id)).count
            == content.tea.count + content.nightcap.count + content.firstVoyage.count)
        for kind in ["tea", "nightcap", "firstVoyage"] {
            let notes = (UInt32(0)..<128).map {
                content.note(kind, seed: $0, date: "2026-11-15", tool: kind == "firstVoyage" ? "codex" : nil)
            }
            #expect(Set(notes.map(\.id)).count >= 4)
            #expect(notes.allSatisfy { note in
                Language.allCases.allSatisfy { language in
                    let text = note.texts[language.rawValue] ?? ""
                    return !text.isEmpty && !text.contains("{") && !text.contains("}")
                }
            })
        }
    }

    @Test(arguments: ["version", "short", "duplicate", "missing-translation", "blank", "unsupported-slot", "tea-slot", "first-voyage-slot"])
    func invalidUsageEventContentIsRejected(failure: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-usage-content-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var content = testCatalog.usageEvents
        switch failure {
        case "version": content.version = 0
        case "short": content.nightcap = Array(content.nightcap.prefix(3))
        case "duplicate": content.tea[0].id = content.nightcap[0].id
        case "missing-translation": content.tea[0].texts.removeValue(forKey: "en")
        case "blank": content.tea[0].texts["zh-Hans"] = " \n "
        case "unsupported-slot": content.nightcap[0].texts["en"] = "A {reward} tonight."
        case "tea-slot": content.tea[0].texts = ["en": "Tea with {tool}.", "zh-Hans": "和{tool}喝茶。"]
        default: content.firstVoyage[0].texts = ["en": "A first voyage.", "zh-Hans": "第一次出航。"]
        }
        try JSONEncoder().encode(content).write(to: directory.appendingPathComponent("usage-events.json"))
        #expect(throws: ContentValidationError.self) { try UsageEventContent.load(directory: directory) }
        #expect(ContentValidator.validate(directory: directory).contains { $0.file == "usage-events.json" && $0.rule == "usageEvents" })
    }
}
