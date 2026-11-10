import Foundation
import Testing
@testable import VoyageCore

private func revisit(_ id: String = "shanghai.revisit", city: String = "shanghai") -> Story {
    var story = engineStory(id, kind: "revisit", city: city)
    story.lead = ["zh-Hans": "又回来了。", "en": "Back again."]
    story.replies = story.replies.map { reply in
        var reply = reply
        reply.id = id + "." + reply.habit
        return reply
    }
    return story
}

private func stayedState(seed: UInt32 = 7) -> (JourneyState, CareState) {
    var (journey, care) = engineState(seed: seed)
    journey.letters.append(engineLetter(1))
    CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
    return (journey, care)
}

private func process(_ journey: inout JourneyState, _ care: inout CareState, _ stories: StoryLibrary) {
    CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog)
}

@Suite struct RevisitTests {
    @Test(arguments: [2, 3])
    func threeCumulativeCluesUnlockWithoutSpending(clues: Int) {
        var (journey, care) = stayedState()
        let stories = engineStories([revisit()])
        care.trailClues["shanghai"] = clues
        #expect(RevisitStories.progress(in: "shanghai", care: care, library: stories) == (clues == 3 ? .unlocked : .collecting(required: 3)))
        journey.letters.append(engineLetter(2, date: "2026-11-02"))
        process(&journey, &care, stories)
        #expect((journey.letters.last?.isRevisit == true) == (clues == 3))
        #expect((care.toldRevisitStoryIds ?? []) == (clues == 3 ? ["shanghai.revisit"] : []))
        #expect(care.trailClues["shanghai", default: 0] >= clues)
    }

    @Test func everyArrivalInAMultiStayLetterCountsAsAPriorStay() {
        var (journey, care) = engineState()
        let stories = engineStories([revisit(), engineStory("xian.arrival", city: "xian")])
        care.trailClues["shanghai"] = 9
        // The first letter covers both stays; the next letter can revisit either city.
        journey.route = ["shanghai", "xian", "shanghai"]
        journey.letters.append(engineLetter(1, arrivals: ["shanghai", "xian"]))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.cityId == "xian")
        journey.letters.append(engineLetter(2, date: "2026-11-02"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.isRevisit == true)
        #expect(RevisitStories.progress(in: "shanghai", care: care, library: stories) == .told)
        journey.letters.append(engineLetter(3, date: "2026-11-03"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.isRevisit != true)
    }

    @Test func dueFulfillmentWinsAndLeavesTheRevisitForNextArrival() throws {
        var (journey, care) = stayedState()
        let stories = engineStories([revisit()])
        care.trailClues["shanghai"] = 3
        #expect(CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "2026-11-02", journey: &journey, care: &care))
        journey.letters.append(engineLetter(2, date: "2026-11-02"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.fulfilledReplyId == "ask-next-time")
        #expect(journey.letters.last?.isRevisit != true)
        #expect((care.toldRevisitStoryIds ?? []).isEmpty)
        journey.letters.append(engineLetter(3, date: "2026-11-03"))
        process(&journey, &care, stories)
        let letter = try #require(journey.letters.last)
        #expect(letter.isRevisit == true && letter.fulfilledReplyId == nil)
        #expect(CareEngine.reply(letterId: 3, replyId: letter.replyOptions[0].id, date: "2026-11-04", journey: &journey, care: &care))
        journey.letters.append(engineLetter(4, date: "2026-11-04"))
        // A revisit's reply uses the existing habit fallback and promise timing.
        for id in 4...6 {
            if id > 4 { journey.letters.append(engineLetter(id, date: "2026-11-0\(id)")) }
            process(&journey, &care, stories)
            if care.pendingPromises.isEmpty { break }
        }
        #expect(care.pendingPromises.isEmpty)
        #expect(journey.letters.contains { $0.fulfilledReplyId == letter.replyOptions[0].id })
        #expect(journey.letters.filter { $0.isRevisit == true }.count == 1)
    }

    @Test func revisitPrecedesItemsToolsHabitsAndWishesWithoutChangingTheItemBonus() {
        for seed: UInt32 in 0..<8 {
            var (journey, care) = stayedState(seed: seed)
            care.trailClues["shanghai"] = 3
            care.habits.observant = 20
            care.bag.todayItem = "sketchbook"
            var tool = engineStory("tool", city: "shanghai")
            tool.requires.tool = "codex"
            var item = engineStory("item", city: "shanghai")
            item.requires.item = "sketchbook"
            var habit = engineStory("habit", city: "shanghai")
            habit.requires.habit = "observant"
            var wish = engineStory("wish", city: "shanghai")
            wish.tags = ["art"]
            let stories = engineStories([revisit(), tool, item, habit, wish])
            journey.letters.append(engineLetter(2, date: "2026-11-02"))
            CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog, wishTags: ["art"])
            #expect(journey.letters.last?.isRevisit == true)
            let triggered = CareEngine.itemTrigger(seed: seed, letterId: 2)
            #expect(journey.letters.last?.itemTriggered == triggered)
            #expect(care.habits.observant == 20 + (triggered ? 3 : 0))
            #expect(journey.letters.last?.rewards.itemIds.count == 1)
            #expect(journey.letters.last?.rewards.dropRarity != nil)
        }
    }

    @Test func everyStayGetsItsRevisitAndTransitNeverConsumesOne() {
        var (journey, care) = stayedState()
        let stories = engineStories([revisit(), revisit("xian.revisit", city: "xian")])
        journey.letters.append(engineLetter(2, arrivals: ["xian"], date: "2026-11-02"))
        process(&journey, &care, stories)
        care.trailClues = ["shanghai": 3, "xian": 3]
        journey.letters.append(engineLetter(3, arrivals: [], date: "2026-11-03"))
        process(&journey, &care, stories)
        #expect((care.toldRevisitStoryIds ?? []).isEmpty)
        journey.letters.append(engineLetter(4, arrivals: ["shanghai", "xian", "no-story"], date: "2026-11-04"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.cityId == "no-story")
        #expect(journey.letters.last?.arrivalStories.map(\.cityId) == ["shanghai", "xian", "no-story"])
        #expect(Set(care.toldRevisitStoryIds ?? []) == ["shanghai.revisit", "xian.revisit"])
        #expect(RevisitStories.next(in: "shanghai", care: care, library: stories) == nil)
    }

    @Test func catchUpReplaysAndRestartTellOnlyOnceAndRepairInterruptedCareSave() throws {
        var (journey, care) = stayedState()
        let stories = engineStories([revisit()])
        care.trailClues["shanghai"] = 3
        let beforeCare = care
        for id in 2...5 { journey.letters.append(engineLetter(id, date: "2026-11-0\(id)")) }
        process(&journey, &care, stories)
        #expect(journey.letters.filter { $0.isRevisit == true }.count == 1)
        #expect(care.toldRevisitStoryIds == ["shanghai.revisit"])
        let expectedJourney = journey
        let expectedCare = care
        for _ in 0..<3 { process(&journey, &care, stories) }
        #expect(journey == expectedJourney && care == expectedCare)
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        care = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care))
        process(&journey, &care, stories)
        #expect(journey == expectedJourney && care == expectedCare)
        care = beforeCare
        // The saved marker repairs care even after the story is removed from the pack.
        process(&journey, &care, engineStories())
        #expect(journey == expectedJourney && care == expectedCare)
        journey.letters.append(engineLetter(6, date: "2026-11-06"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.isRevisit != true)
    }

    @Test func currentLettersStayUnchangedAndTodaysDropCannotRetroactivelyUnlockItsStory() {
        var (journey, care) = stayedState()
        let stories = engineStories([revisit()])
        care.trailClues["shanghai"] = 2
        care.souvenirs = testCatalog.items.all.filter { $0.kind == "souvenir" }.map { .init(id: $0.id, shelved: false) }
        journey.letters.append(engineLetter(2, date: "2026-11-02"))
        process(&journey, &care, stories)
        #expect(care.trailClues["shanghai"] == 3)
        let saved = journey.letters
        process(&journey, &care, stories)
        #expect(journey.letters == saved)
        journey.letters.append(engineLetter(3, date: "2026-11-03"))
        process(&journey, &care, stories)
        #expect(journey.letters.last?.isRevisit == true)
        #expect(Array(journey.letters.dropLast()) == saved)
    }

    @Test func eachFurtherStoryNeedsAnotherThreeCumulativeClues() {
        var (_, care) = engineState()
        let stories = engineStories([revisit("shanghai.revisit.b"), revisit("shanghai.revisit.a")])
        care.trailClues["shanghai"] = 3
        #expect(RevisitStories.next(in: "shanghai", care: care, library: stories)?.id == "shanghai.revisit.a")
        care.toldRevisitStoryIds = ["shanghai.revisit.a"]
        care.trailClues["shanghai"] = 5
        #expect(RevisitStories.progress(in: "shanghai", care: care, library: stories) == .collecting(required: 6))
        care.trailClues["shanghai"] = 6
        #expect(RevisitStories.next(in: "shanghai", care: care, library: stories)?.id == "shanghai.revisit.b")
        care.toldRevisitStoryIds?.append("shanghai.revisit.b")
        #expect(RevisitStories.progress(in: "shanghai", care: care, library: stories) == .told)
        #expect(care.trailClues["shanghai"] == 6)
        care.trailClues["xian"] = 99
        #expect(RevisitStories.progress(in: "xian", care: care, library: stories) == .unavailable)
        #expect(RevisitStories.unlockedCities(care: care, library: stories).isEmpty)
    }

    @Test func oldSavesDecodeEmptyAndExistingCluesUnlockWithoutSendingLetters() throws {
        let url = try #require(Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["trailClues"] = ["shanghai": 3]
        var care = try JSONDecoder().decode(CareState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect((care.toldRevisitStoryIds ?? []).isEmpty)
        let stories = engineStories([revisit()])
        #expect(RevisitStories.unlockedCities(care: care, library: stories) == ["shanghai"])
        var (journey, _) = engineState()
        let letters = journey.letters
        process(&journey, &care, stories)
        #expect(journey.letters == letters)
        #expect(JourneyState.currentVersion == 8 && CareState.currentVersion == 1)
        let journeyURL = try #require(Bundle.module.url(forResource: "journey-v6", withExtension: "json", subdirectory: "Fixtures"))
        let legacyJourney = try decodeOldJourneyFixture(Data(contentsOf: journeyURL))
        #expect(legacyJourney.letters.allSatisfy { $0.isRevisit == nil })
    }

    @Test(arguments: [false, true])
    func unlockedCitiesTripleTheExistingWeightAndToldCitiesRestoreIt(wish: Bool) {
        var (_, care) = engineState()
        let stories = engineStories([revisit()])
        let city = testCatalog.city("shanghai")
        let tags: Set<String> = wish ? Set(city.tags) : []
        care.trailClues[city.id] = 3
        let base = DestinationPicker.cityWeight(city, route: [city.id], stampedCountries: [city.countryCode], wishTags: tags)
        let weighted = DestinationPicker.cityWeight(city, route: [city.id], stampedCountries: [city.countryCode], wishTags: tags,
                                                   revisitCities: RevisitStories.unlockedCities(care: care, library: stories))
        #expect(weighted == base * 3)
        care.toldRevisitStoryIds = ["shanghai.revisit"]
        #expect(DestinationPicker.cityWeight(city, route: [city.id], stampedCountries: [city.countryCode], wishTags: tags,
                                            revisitCities: RevisitStories.unlockedCities(care: care, library: stories)) == base)
    }

    @Test func revisitWeightsReachLiveAndFinalizedDrawsAndNeverRedrawTheSavedTarget() {
        var (initial, _) = engineState()
        initial.route = [initial.targetCityId]
        initial.currentCityId = initial.targetCityId
        initial.phase = .returning
        initial.phaseSince = DayKey.date(from: initial.openDate, calendar: careCalendar)!
        initial.legFrom = initial.legTo
        initial.legTo = initial.homeCoordinate
        initial.targetCityId = initial.homeCityId
        initial.legCost = max(returnTokensPerKm, Int(initial.legFrom.distanceKm(to: initial.legTo) * Double(returnTokensPerKm)))
        let cities: Set<String> = ["shanghai", "hangzhou", "beijing"]
        let usage = DayUsage(date: initial.openDate, fuel: initial.legCost, byClient: ["codex": initial.legCost])
        var live = initial
        var catchUp = initial
        live.sync(today: usage, now: DayKey.date(from: (usage).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, revisitCities: cities)
        let expected = DestinationPicker.pick(from: initial.homeCoordinate, currentCityId: initial.homeCityId, route: live.route,
                                              stampedCountries: Set(live.stamps.map(\.countryCode)), medianKm: 0,
                                              revisitCities: cities, catalog: testCatalog, seed: initial.seed, tripCount: 1)
        #expect(live.targetCityId == expected)
        live.sync(today: DayUsage(date: "2026-11-02"), finalized: [usage], now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, revisitCities: cities)
        catchUp.sync(today: DayUsage(date: "2026-11-02"), finalized: [usage], hourly: [usage.date: [HourUsage(date: usage.date, hour: 11, tokens: .init(input: usage.observedTokens))]], now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, revisitCities: cities)
        #expect(live == catchUp)
        let saved = live
        live.sync(today: DayUsage(date: live.openDate), now: DayKey.date(from: (DayUsage(date: live.openDate)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, revisitCities: ["xian"])
        #expect(live == saved)
    }
}

@Suite struct RevisitContentTests {
    @Test func everyFullCityHasOneBilingualRevisitUsingItsOwnFacts() {
        let full = testCatalog.all.filter { $0.level == "full" }
        #expect(full.count == fullContentCityIds.count)
        for city in full {
            let stories = testCatalog.stories.all.filter { $0.kind == "revisit" && $0.cityId == city.id }
            #expect(stories.count == 1)
            for story in stories {
                #expect(story.lead != nil && story.requires.isEmpty && story.rewards == StoryRewards())
                #expect(!story.factIds.isEmpty && Set(story.factIds).isSubset(of: Set(city.facts.map(\.id))))
                #expect(Set(story.replies.map(\.habit)) == ["talkative", "observant"])
                for text in [story.text, story.lead ?? [:]] + story.replies.map(\.text) {
                    #expect(text["zh-Hans"]?.isEmpty == false && text["en"]?.isEmpty == false)
                }
            }
        }
        #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
    }

    @Test(arguments: ["missing", "foreign-fact", "missing-city", "missing-lead", "missing-reply", "reward"])
    func invalidRevisitContentIsRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("stories/shanghai.json")
        var stories = try JSONDecoder().decode([Story].self, from: Data(contentsOf: file))
        let index = try #require(stories.firstIndex { $0.kind == "revisit" })
        var rule: String
        switch failure {
        case "missing": stories.remove(at: index); rule = "revisitBaseline"
        case "foreign-fact":
            let localFacts = Set(testCatalog.city("shanghai").facts.map(\.id))
            let foreignFact = try #require(testCatalog.city("xian").facts.first { !localFacts.contains($0.id) })
            stories[index].factIds = [foreignFact.id]; rule = "storyFacts"
        case "missing-city": stories[index].cityId = nil; rule = "revisitCity"
        case "missing-lead": stories[index].lead = nil; rule = "revisitFormat"
        case "missing-reply": stories[index].replies.removeLast(); rule = "revisitFormat"
        default: stories[index].rewards.dropRarity = "rare"; rule = "revisitRules"
        }
        try JSONEncoder().encode(stories).write(to: file)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
    }
}

private func revisitReplay(seed: UInt32, multiplier: Int, slices: Int = 1, catalog: CityCatalog) -> (JourneyState, CareState) {
    var journey = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: catalog)
    var care = CareState(petName: "Pip", species: catalog.pets.defaultID, hatchedAt: journey.startDate)
    let revisits = catalog.all.filter { $0.level == "full" }.map { revisit($0.id + ".revisit", city: $0.id) }
    let stories = engineStories(revisits)
    care.trailClues = Dictionary(revisits.map { ($0.cityId!, 3) }, uniquingKeysWith: { first, _ in first })
    care.bag.owned = ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"]
    for offset in 0..<90 {
        let date = journey.openDate
        let next = DayKey.next(date, calendar: careCalendar)
        let amount = offset % 9 == 8 ? 0 : (offset % 5 + 1) * 3_000_000 * multiplier
        let cities = RevisitStories.unlockedCities(care: care, library: stories)
        for slice in 1...slices {
            let usage = amount * slice / slices
            journey.sync(today: DayUsage(date: date, fuel: usage, byClient: ["codex": usage], observedTokens: usage * 100), now: DayKey.date(from: (DayUsage(date: date, fuel: usage, byClient: ["codex": usage], observedTokens: usage * 100)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar,
                         catalog: catalog, revisitCities: cities)
            CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog)
        }
        care.bag.todayItem = ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"][offset % 5]
        journey.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount, byClient: ["codex": amount], observedTokens: amount * 100)], now: DayKey.date(from: (DayUsage(date: next)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600),
                     calendar: careCalendar, catalog: catalog, revisitCities: cities)
        CareEngine.markCompanion(date: next, care: &care)
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog)
        if let letter = journey.letters.last, letter.kind == .daily, letter.id % 4 == 1 {
            let habit = letter.id % 8 == 1 ? "talkative" : "observant"
            let reply = letter.replyOptions.first { $0.habit == habit }!
            CareEngine.reply(letterId: letter.id, replyId: reply.id, date: next, journey: &journey, care: &care)
        }
    }
    return (journey, care)
}

@Suite struct RevisitReplayTests {
    @Test(arguments: [UInt32(1), 7, 42])
    func sameSeedAndIntradayScansProduceTheSameResult(seed: UInt32) throws {
        let box = try PickerCatalogSandbox(["shanghai", "hangzhou", "beijing", "xian", "quanzhou", "jingdezhen"].map { testCatalog.city($0) })
        defer { box.cleanUp() }
        let (journey, care) = revisitReplay(seed: seed, multiplier: 1, catalog: box.catalog)
        let (recomputed, recomputedCare) = revisitReplay(seed: seed, multiplier: 1, catalog: box.catalog)
        let (sliced, slicedCare) = revisitReplay(seed: seed, multiplier: 1, slices: 3, catalog: box.catalog)
        #expect(journey == recomputed && care == recomputedCare)
        #expect(journey == sliced && care == slicedCare)
        #expect(journey.letters.contains { $0.isRevisit == true })
    }

    @Test(arguments: [UInt32(1), 7, 42])
    func doublingUsageKeepsHabitsDropsPityCompanionshipAndLetterCounts(seed: UInt32) throws {
        let box = try PickerCatalogSandbox(["shanghai", "hangzhou", "beijing", "xian", "quanzhou", "jingdezhen"].map { testCatalog.city($0) })
        defer { box.cleanUp() }
        let (journey, care) = revisitReplay(seed: seed, multiplier: 1, catalog: box.catalog)
        let (doubled, doubledCare) = revisitReplay(seed: seed, multiplier: 2, catalog: box.catalog)
        #expect(journey.letters.count == doubled.letters.count)
        #expect(journey.letters.map(\.kind) == doubled.letters.map(\.kind))
        #expect(journey.letters.map(\.date) == doubled.letters.map(\.date))
        #expect(journey.letters.map(\.deliverAt) == doubled.letters.map(\.deliverAt))
        #expect(journey.letters.map(\.rewards.dropRarity) == doubled.letters.map(\.rewards.dropRarity))
        #expect(journey.letters.map(\.itemTriggered) == doubled.letters.map(\.itemTriggered))
        #expect(journey.letters.map { $0.fulfilledReplyId != nil } == doubled.letters.map { $0.fulfilledReplyId != nil })
        #expect(care.habits == doubledCare.habits && care.pity == doubledCare.pity)
        #expect(care.companionDays == doubledCare.companionDays && care.weekly == doubledCare.weekly)
        #expect(care.identity == doubledCare.identity)
        #expect(doubled.totalFuel == journey.totalFuel * 2)
        #expect(doubled.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } == journey.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } * 2)
    }
}
