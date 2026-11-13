import Foundation
import Testing
@testable import VoyageCore

private func identityState(days: Int = 60, seed: UInt32 = 7) -> (JourneyState, CareState) {
    var (journey, care) = engineState(seed: seed)
    let start = DayKey.date(from: journey.startDate, calendar: careCalendar)!
    for offset in 0..<days {
        CareEngine.markCompanion(date: careCalendar.date(byAdding: .day, value: offset, to: start)!, care: &care, calendar: careCalendar)
    }
    journey.openDate = care.companionDays.last ?? journey.startDate
    care.habits.talkative = 80
    return (journey, care)
}

private func processIdentity(_ journey: inout JourneyState, _ care: inout CareState, catalog: CityCatalog = testCatalog, delivery: DeliveryTime = .standard) {
    CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog,
                       calendar: careCalendar, deliveryTime: delivery)
}

@Suite struct IdentityTests {
    @Test func scoringCountsOwnedDistinctIDsStampedCountriesAndPassportRegulars() throws {
        var (journey, care) = identityState()
        care.habits.talkative = 34
        care.habits.observant = 22
        care.menus = [.init(id: "meal-a", letterId: 1), .init(id: "meal-a", letterId: 2), .init(id: "meal-b", letterId: 3)]
        care.souvenirs = [.init(id: "gift-a", shelved: false), .init(id: "gift-a", shelved: true), .init(id: "gift-b", shelved: false)]
        journey.stamps = [.init(countryCode: "CN", cityId: "shanghai", date: journey.startDate),
                          .init(countryCode: "JP", cityId: "tokyo", date: journey.startDate),
                          .init(countryCode: "JP", cityId: "kyoto", date: journey.startDate)]
        let alias = try #require(testCatalog.city("xian").wikidata)
        journey.route = ["xian", alias, "xian", "tokyo", "tokyo", "shanghai"]
        let visits = CityStays.all(journey: journey, catalog: testCatalog)
        #expect(visits.first { $0.id == "xian" }?.count == 3)
        #expect(visits.filter(\.isRegular).map(\.id) == ["xian"])
        #expect(IdentityRules.scores(journey: journey, care: care, catalog: testCatalog) == [
            .liaison: 34, .sketcher: 22, .gourmet: 6, .collector: 4, .pathfinder: 8, .neighbour: 10,
        ])
    }

    @Test(arguments: [(100, 90, true), (100, 91, true), (100, 89, false), (11, 10, true), (11, 9, false)])
    func tieWindowIncludesExactlyNinetyPercent(top: Int, contender: Int, included: Bool) {
        var scores = Dictionary(uniqueKeysWithValues: TravellerIdentity.allCases.map { ($0, 0) })
        scores[.liaison] = top
        scores[.sketcher] = contender
        #expect(IdentityRules.candidates(scores: scores).contains(.sketcher) == included)
        #expect(IdentityRules.candidates(scores: scores).contains(.liaison))
    }

    @Test func seededDrawIsStableUsesEachStageThresholdAndIncludesEveryZeroScoreCandidate() {
        let scores = Dictionary(uniqueKeysWithValues: TravellerIdentity.allCases.map { ($0, 0) })
        #expect(IdentityRules.candidates(scores: scores) == TravellerIdentity.allCases)
        var outcomes: Set<TravellerIdentity> = []
        var stageDrawsDiffer = false
        for seed: UInt32 in 0..<100 {
            let chosen = IdentityRules.choose(scores: scores, seed: seed, stage: .traveler)
            let reversed = Dictionary(uniqueKeysWithValues: scores.reversed().map { ($0.key, $0.value) })
            #expect(chosen == IdentityRules.choose(scores: reversed, seed: seed, stage: .traveler))
            outcomes.insert(chosen)
            var stages: Set<TravellerIdentity> = []
            for (stage, days) in CareRules.stageThresholds where IdentityRules.stages.contains(stage) {
                var random = SplitMix64(seed: seed, stopCount: days, salt: .identity)
                let expected = TravellerIdentity.allCases[Int(random.next() % 6)]
                let actual = IdentityRules.choose(scores: scores, seed: seed, stage: stage)
                #expect(actual == expected)
                stages.insert(actual)
            }
            if stages.count > 1 { stageDrawsDiffer = true }
        }
        #expect(outcomes == Set(TravellerIdentity.allCases))
        #expect(stageDrawsDiffer)
    }

    @Test func noIdentityBeforeTravellerAndAllZeroStillWritesOneHonestLetter() throws {
        var (journey, care) = identityState(days: 59)
        processIdentity(&journey, &care)
        #expect(care.identity == nil && journey.letters.allSatisfy { $0.kind != .identity })
        CareEngine.markCompanion(date: DayKey.next(journey.openDate, calendar: careCalendar), care: &care, calendar: careCalendar)
        journey.openDate = care.companionDays.last!
        care.habits = .init()
        journey.stamps = []
        processIdentity(&journey, &care)
        let letter = try #require(journey.letters.last)
        let identity = try #require(letter.identitySettlement?.identity)
        let templates = testCatalog.identities.entry(identity).letters["zero"]!
        #expect(care.identity == identity.rawValue && care.settledIdentityStages == [.traveler])
        #expect(letter.texts == templates.mapValues { StorySlots.render($0, values: ["pet": care.petName]) })
    }

    @Test(arguments: [170, 340], [false, true])
    func zeroScoreLaterStagesExplainWhetherTheIdentityChanges(days: Int, same: Bool) throws {
        var (journey, care) = identityState(days: days)
        care.habits = .init()
        journey.stamps = []
        let scores = IdentityRules.scores(journey: journey, care: care, catalog: testCatalog)
        let stage = Stage.current(companionDays: days)
        let chosen = IdentityRules.choose(scores: scores, seed: journey.seed, stage: stage)
        care.identity = same ? chosen.rawValue : TravellerIdentity.allCases.first { $0 != chosen }!.rawValue
        care.settledIdentityStages = days == 170 ? [.traveler] : [.traveler, .veteran]
        processIdentity(&journey, &care)
        let letter = try #require(journey.letters.last)
        let variant = same ? "zeroSame" : "zeroChanged"
        #expect(letter.texts == testCatalog.identities.entry(chosen).letters[variant]!.mapValues { StorySlots.render($0, values: ["pet": care.petName]) })
        #expect(care.identity == chosen.rawValue)
    }

    @Test(arguments: [false, true])
    func eachStageSettlesOnceAndLaterStagesCanChangeOrKeepAnIdentity(changeAtLegend: Bool) throws {
        var (journey, care) = identityState()
        for (days, expected) in [(60, TravellerIdentity.liaison), (170, .sketcher), (340, changeAtLegend ? .gourmet : .sketcher)] {
            let (advancedJourney, advancedCare) = identityState(days: days)
            journey.openDate = advancedJourney.openDate
            care.companionDays = advancedCare.companionDays
            if days > 60 { care.habits.talkative = 0; care.habits.observant = 100 }
            if days == 340, changeAtLegend { care.menus = (0..<40).map { .init(id: "menu-\($0)", letterId: 1) } }
            processIdentity(&journey, &care)
            #expect(care.identity == expected.rawValue)
            let before = (journey, care)
            for _ in 0..<3 { processIdentity(&journey, &care) }
            #expect(journey == before.0 && care == before.1)
            let letter = try #require(journey.letters.last)
            let variant = days == 60 ? "first" : days == 170 || changeAtLegend ? "changed" : "same"
            #expect(letter.texts == testCatalog.identities.entry(expected).letters[variant]!.mapValues { StorySlots.render($0, values: ["pet": care.petName]) })
        }
        #expect(care.settledIdentityStages == [.traveler, .veteran, .legend])
        #expect(journey.letters.filter { $0.kind == .identity }.count == 3)
    }

    @Test(arguments: [(60, Stage.traveler), (169, .traveler), (170, .veteran), (250, .veteran), (340, .legend), (400, .legend)])
    func legacySavesOnlySettleCurrentStageOnTheUpgradeDay(days: Int, expected: Stage) throws {
        var (journey, care) = identityState(days: days)
        care.settledIdentityStages = nil
        journey.openDate = DayKey.next(journey.openDate, calendar: careCalendar)
        processIdentity(&journey, &care)
        #expect(care.settledIdentityStages == [expected])
        let letter = try #require(journey.letters.last)
        #expect(letter.kind == .identity && letter.date == journey.openDate)
        #expect(letter.identitySettlement?.stage == expected)
        processIdentity(&journey, &care)
        #expect(journey.letters.filter { $0.kind == .identity }.count == 1)
    }

    @Test func journeyFirstCrashReplayRestoresDecisionScoresAndTextEvenAfterContentAndInputsChange() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        var (journey, care) = identityState()
        let beforeCare = care
        processIdentity(&journey, &care)
        let letter = try #require(journey.letters.last)
        let savedJourney = try JSONEncoder().encode(journey)
        try box.edit("identities.json") { json in
            var identities = json["identities"] as! [[String: Any]]
            for i in identities.indices {
                identities[i]["name"] = ["zh-Hans": "修订名", "en": "Edited name"]
                identities[i]["letters"] = Dictionary(uniqueKeysWithValues: ["first", "changed", "same", "zero", "zeroChanged", "zeroSame"].map { ($0, ["zh-Hans": "新正文，{pet}。", "en": "Edited body for {pet}."]) })
            }
            json["identities"] = identities
        }
        let updated = try CityCatalog.load(directory: box.directory)
        var replay = beforeCare
        replay.habits.talkative = 0
        replay.habits.observant = 100
        journey = try JSONDecoder().decode(JourneyState.self, from: savedJourney)
        processIdentity(&journey, &replay, catalog: updated)
        #expect(replay.identity == care.identity && replay.settledIdentityStages == [.traveler])
        #expect(journey.letters.last == letter)
        #expect(journey.letters.filter { $0.kind == .identity }.count == 1)
        let savedCare = try JSONEncoder().encode(replay)
        var again = try JSONDecoder().decode(CareState.self, from: savedCare)
        processIdentity(&journey, &again, catalog: updated)
        #expect(again == replay && journey.letters.last == letter)
    }

    @Test func nextMorningDeliveryUsesLocalCalendarIncludingDST() throws {
        var calendar = careCalendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var (journey, care) = identityState()
        journey.openDate = "2026-10-31"
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog,
                           calendar: calendar, deliveryTime: DeliveryTime(hour: 9, minute: 30)!)
        let mail = try #require(journey.letters.last)
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 30))!
        #expect(mail.date == "2026-10-31" && mail.deliverAt == due)
        #expect(!journey.deliveredLetters(now: due.addingTimeInterval(-1)).contains(mail))
        #expect(journey.deliveredLetters(now: due).contains(mail))
    }

    @Test func settlementHasNoTravelRewardPromiseHabitOrWeeklySideEffects() throws {
        var (journey, care) = identityState()
        care.pendingPromises = [.init(replyId: "ask-next-time", letterId: 1, attempts: 2)]
        care.pity = 8
        care.bag.todayItem = "sketchbook"
        care.trailClues = ["shanghai": 7]
        care.sponsoredDeliveryWeeks = ["2026-11-02": 2]
        MemoryBook.backfill(journey: journey, care: &care)
        var expected = care
        let priorJourney = journey
        processIdentity(&journey, &care)
        let mail = try #require(journey.letters.last)
        #expect(mail.rewards == StoryRewards() && mail.replyOptions.isEmpty && mail.learnedTexts.isEmpty)
        #expect(mail.carriedItem == nil && mail.itemTriggered == nil && mail.fulfilledReplyId == nil)
        #expect(mail.sponsor == nil && mail.rewardItems.isEmpty && mail.enrichmentDone)
        expected.identity = care.identity
        expected.settledIdentityStages = [.traveler]
        let adventure = try #require(journey.letters.first { $0.kind == .adventure })
        expected.metFriends = care.metFriends
        expected.settledFriendThresholds = [48]
        expected.specialDays.append(.init(kind: .friendMet, date: adventure.date, letterId: adventure.id))
        #expect(care == expected)
        var expectedJourney = priorJourney
        expectedJourney.letters += [adventure, mail]
        #expect(journey == expectedJourney)
        #expect(!CareEngine.reply(letterId: mail.id, replyId: "anything", date: journey.openDate, journey: &journey, care: &care))
    }

    @Test func oldCareFixtureDecodesWithoutNewFieldsAndRoundTripsAtVersionOne() throws {
        let fixture = Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures")!
        let care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture))
        #expect(care.settledIdentityStages == nil && care.identity == nil && care.version == 1)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
        #expect(CareState.currentVersion == 1)
    }
}
