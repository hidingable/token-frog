import Foundation
import Testing
@testable import VoyageCore

let careCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

func engineStory(_ id: String, kind: String = "arrival", city: String? = nil, habit: String? = nil) -> Story {
    Story(
        id: id, version: 1, kind: kind, cityId: city, factIds: [], tags: [], requires: .init(), fulfills: [],
        fulfillsHabit: habit, lead: kind == "fulfill" ? ["zh-Hans": "你说过“{reply}”。", "en": "You wrote: {reply}."] : nil,
        text: ["zh-Hans": "{pet}从{city}寄来一封信。", "en": "A letter from {pet}, writing in {city}."],
        replies: [
            .init(id: "ask-next-time", habit: "talkative", text: ["zh-Hans": "下回问问", "en": "Ask next time"]),
            .init(id: "look-closer", habit: "observant", text: ["zh-Hans": "仔细看看", "en": "Take a closer look"]),
        ], rewards: .init()
    )
}

func engineStories(_ extra: [Story] = []) -> StoryLibrary {
    StoryLibrary(stories: [
        engineStory("generic.arrival"), engineStory("generic.transit", kind: "transit"),
        engineStory("generic.talkative", kind: "fulfill", habit: "talkative"),
        engineStory("generic.observant", kind: "fulfill", habit: "observant"),
    ] + extra)
}

func engineState(seed: UInt32 = 7) -> (JourneyState, CareState) {
    (
        JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: testCatalog),
        CareState(petName: "小邮差 Pip", species: PetID(rawValue: "pigeon"), hatchedAt: "2026-11-01")
    )
}

func engineLetter(_ id: Int, arrivals: [String] = ["shanghai"], date: String = "2026-11-01") -> Letter {
    Letter(
        id: id, kind: .daily, date: date, pet: PetID(rawValue: "pigeon"), cityId: "shanghai",
        transitTargetId: arrivals.isEmpty ? "xian" : nil, arrivals: arrivals, newCountries: [], fuel: 100,
        compareToMedianPercent: nil, vehicles: [.init(client: "codex", percent: 100)], isDeepVisit: false,
        deliverAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite struct CareEngineTests {
    @Test(arguments: [2, 3, 4, 5, 6])
    func ordinarySelectionUsesTheFirstEligibleTier(tier: Int) {
        var (journey, care) = engineState()
        care.habits.talkative = 10
        care.bag.todayItem = "sketchbook"
        var tool = engineStory("tool", city: "shanghai")
        tool.requires = .init(habit: "talkative", season: "autumn", tool: "codex", rainySeason: false)
        var habit = engineStory("habit", city: "shanghai")
        habit.requires.habit = "talkative"
        var wish = engineStory("wish", city: "shanghai")
        wish.tags = ["art"]
        let city = engineStory("city", city: "shanghai")
        let extras = [(2, tool), (3, habit), (4, wish), (5, city)].filter { $0.0 >= tier }.map(\.1)
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(extras), catalog: testCatalog, wishTags: ["art"])
        let expected = [2: "tool", 3: "habit", 4: "wish", 5: "city", 6: "generic.arrival"]
        #expect(journey.letters.last?.storyId == expected[tier])
    }

    @Test(arguments: ["habit", "item", "season", "tool", "rainySeason"])
    func everyRequirementMustMatch(requirement: String) {
        var (journey, care) = engineState(seed: 1)
        care.habits.talkative = 10
        care.bag.todayItem = "sketchbook"
        var story = engineStory("conditional", city: "shanghai")
        story.requires = .init(habit: "talkative", item: "sketchbook", season: "autumn", tool: "codex", rainySeason: false)
        story.tags = ["art"]
        switch requirement {
        case "habit": care.habits.talkative = 9
        case "item": care.bag.todayItem = "raincoat"
        case "season": story.requires.season = "spring"
        case "tool": story.requires.tool = "claude"
        default: story.requires.rainySeason = true
        }
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([story]), catalog: testCatalog, wishTags: ["art"])
        #expect(journey.letters.last?.storyId == "generic.arrival")
    }

    @Test func seasonAndRainyMonthsUseLetterDateAndSouthernLatitude() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("cities/melbourne.json") { $0["rainyMonths"] = [11] }
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        var story = engineStory("spring-rain", city: "melbourne")
        story.requires = .init(season: "spring", rainySeason: true)
        journey.letters.append(engineLetter(1, arrivals: ["melbourne"]))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([story]), catalog: catalog)
        #expect(journey.letters.last?.storyId == story.id)
        #expect(catalog.city("shanghai").rainyMonths.isEmpty)
    }

    @Test func thePrimaryVehicleAndTodaysItemAreTheOnlyMatchingInputs() {
        var (journey, care) = engineState()
        care.bag.todayItem = "raincoat"
        var story = engineStory("secondary-tool", city: "shanghai")
        story.requires.tool = "claude"
        journey.letters.append(engineLetter(1))
        journey.letters[1].vehicles.append(.init(client: "claude", percent: 25))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([story]), catalog: testCatalog)
        #expect(journey.letters[1].storyId == "generic.arrival")
        #expect(care.habits == .init()) // The raincoat never changes habits.
    }

    @Test func longDayUsesTheLastArrivedCityWithStoriesAndOtherwiseTheLastArrival() {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1, arrivals: ["tokyo", "shanghai", "xian"]))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([engineStory("local", city: "shanghai")]), catalog: testCatalog)
        #expect(journey.letters.last?.cityId == "shanghai")
        #expect(journey.letters.last?.storyId == "local")
        journey.letters.append(engineLetter(2, arrivals: ["tokyo", "xian"]))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.cityId == "xian")
    }

    @Test func aDayWithoutArrivalUsesTransitAndPreservesItsCity() {
        var (journey, care) = engineState()
        var transit = engineStory("road", kind: "transit")
        transit.text = ["zh-Hans": "{pet}从{city}去{target}。", "en": "{pet} is on the way from {city} to {target}."]
        journey.letters.append(engineLetter(1, arrivals: []))
        CareEngine.process(journey: &journey, care: &care, stories: StoryLibrary(stories: [transit]), catalog: testCatalog)
        #expect(journey.letters.last?.cityId == "shanghai")
        #expect(journey.letters.last?.storyId == "road")
        #expect(journey.letters.last?.texts?["en"] == "小邮差 Pip is on the way from Shanghai to Xi'an.")
    }

    @Test(arguments: ["city", "generic", "habit", "any"], ["arrival", "transit", "fulfill"])
    func duePromiseUsesTheFulfillmentFallbackOrder(level: String, kind: String) throws {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "2026-11-02", journey: &journey, care: &care))
        var local = engineStory("city-fulfillment", kind: kind, city: "shanghai")
        local.fulfills = ["ask-next-time"]
        local.lead = ["zh-Hans": "记得你说“{reply}”。", "en": "I remember: {reply}."]
        var generic = local
        generic.id = "generic-dedicated-fulfillment"
        generic.cityId = nil
        var unrelated = engineStory("unrelated-fulfillment", kind: "fulfill")
        unrelated.fulfills = ["look-closer"]
        let extras = level == "city" ? [local, generic] : level == "generic" ? [generic] : []
        var stories = engineStories(extras + [unrelated]).all
        if level == "any" { stories.removeAll { $0.kind == "fulfill" && $0.fulfillsHabit == "talkative" } }
        journey.letters.append(engineLetter(2, date: "2026-11-02"))
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: stories), catalog: testCatalog)
        let letter = try #require(journey.letters.last)
        let expected = ["city": local.id, "generic": generic.id, "habit": "generic.talkative", "any": "generic.observant"]
        #expect(letter.storyId == expected[level])
        #expect(letter.fulfilledReplyId == "ask-next-time")
        #expect(letter.leadTexts["en"]?.contains("Ask next time") == true)
        #expect(letter.leadTexts["zh-Hans"]?.contains("下回问问") == true)
        #expect(care.pendingPromises.isEmpty)
        #expect(care.memories.last == .init(kind: "fulfilled", date: letter.date, letterId: 2, replyId: "ask-next-time"))
    }

    @Test(arguments: ["habit", "item", "season", "tool", "rainySeason", "city"])
    func ineligibleDedicatedFulfillmentsCannotOverrideTheGenericOne(requirement: String) {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "later", journey: &journey, care: &care)
        var local = engineStory("ineligible", city: "shanghai")
        local.fulfills = ["ask-next-time"]
        switch requirement {
        case "habit": local.requires.habit = "observant"
        case "item": local.requires.item = "old-camera"
        case "season": local.requires.season = "spring"
        case "tool": local.requires.tool = "claude"
        case "rainySeason": local.requires.rainySeason = true
        default: local.cityId = "xian"
        }
        var generic = engineStory("eligible", kind: "fulfill")
        generic.fulfills = ["ask-next-time"]
        journey.letters.append(engineLetter(2, arrivals: []))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([local, generic]), catalog: testCatalog)
        #expect(journey.letters.last?.storyId == generic.id)
    }

    @Test func recentTenStoriesAreAvoidedAndExhaustionRelaxesOnlyWithinTheWinningTier() {
        var (journey, care) = engineState()
        let locals = (1...11).map { engineStory("local.\($0)", city: "shanghai") }
        journey.letters += (1...10).map { id in
            var letter = engineLetter(id)
            letter.storyId = "local.\(id)"
            return letter
        }
        care.processedLetterIds = Array(1...10)
        journey.letters.append(engineLetter(11))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(locals), catalog: testCatalog)
        #expect(journey.letters.last?.storyId == "local.11")
        journey.letters.append(engineLetter(12))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([locals[10]]), catalog: testCatalog)
        #expect(journey.letters.last?.storyId == "local.11")
    }

    @Test func processingIsIdempotentAndRecoversCareWithoutReselectingASavedStory() throws {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "2026-11-02", journey: &journey, care: &care))
        let beforeCareWrite = care
        journey.letters.append(engineLetter(2))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        let expectedJourney = journey
        let expectedCare = care
        care = beforeCareWrite
        // The saved story no longer exists in this content pack.
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(journey == expectedJourney)
        #expect(care == expectedCare)
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey == expectedJourney && care == expectedCare)
        let roundTrip = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        #expect(roundTrip == journey)
    }

    @Test func aSavedNonfulfillingStoryStillAdvancesThePromiseAttemptExactlyOnce() {
        var (journey, care) = engineState(seed: 1)
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        care.memories.append(.init(kind: "fulfilled", date: "2026-10-31", letterId: -1, replyId: "older"))
        #expect(CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "2026-11-02", journey: &journey, care: &care))
        var saved = engineLetter(2)
        saved.storyId = "saved-body"
        saved.texts = ["en": "Saved", "zh-Hans": "已存"]
        journey.letters.append(saved)
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        let after = care
        #expect(care.pendingPromises.first?.attempts == 1)
        #expect(journey.letters.last == saved)
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(care == after)
    }

    @Test func repliesAreValidatedCappedAndRecordedOnceWhileSkippingChangesNothing() {
        var (journey, care) = engineState()
        journey.letters += [engineLetter(1), engineLetter(2), engineLetter(3)]
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        let untouched = care
        #expect(!CareEngine.reply(letterId: 999, replyId: "ask-next-time", date: "later", journey: &journey, care: &care))
        #expect(!CareEngine.reply(letterId: 1, replyId: "missing", date: "later", journey: &journey, care: &care))
        #expect(care == untouched && care.habits == .init())
        #expect(CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "2026-11-05", journey: &journey, care: &care))
        #expect(care.habits.talkative == 10 && care.habits.observant == 0)
        #expect(care.memories == [.init(kind: "reply", date: "2026-11-05", letterId: 1, replyId: "ask-next-time")])
        #expect(care.pendingPromises == [.init(replyId: "ask-next-time", letterId: 1)])
        let after = care
        #expect(!CareEngine.reply(letterId: 1, replyId: "look-closer", date: "later", journey: &journey, care: &care))
        #expect(care == after)
        care.habits.observant = 95
        #expect(CareEngine.reply(letterId: 2, replyId: "look-closer", date: "later", journey: &journey, care: &care))
        #expect(care.habits.observant == 100 && journey.letters[2].selectedReplyId == "look-closer")
        #expect(journey.letters[3].selectedReplyId == nil) // Skipped now, still available later.
        care.habits.talkative = 100
        #expect(CareEngine.reply(letterId: 3, replyId: "ask-next-time", date: "later", journey: &journey, care: &care))
        #expect(care.habits.talkative == 100)
    }

    @Test func companionDaysAreUniqueAndDoNotDependOnTheJourney() {
        var (_, care) = engineState()
        CareEngine.markCompanion(date: "2026-11-02", care: &care)
        CareEngine.markCompanion(date: "2026-11-02", care: &care)
        CareEngine.markCompanion(date: "2026-11-03", care: &care)
        #expect(care.companionDays == ["2026-11-02", "2026-11-03"])
        #expect(care.habits == .init() && care.pity == 0)
    }

    @Test func legacyDailyLettersAndTheLogbookAreNotRewrittenOrGivenReplies() throws {
        let fixture = try #require(Bundle.module.url(forResource: "journey-v4", withExtension: "json", subdirectory: "Fixtures"))
        var journey = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: fixture))
        var care = CareState(petName: "Pip", species: PetID(rawValue: "snail"), hatchedAt: journey.startDate)
        let original = journey
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey == original)
        #expect(care.memories.isEmpty && care.pendingPromises.isEmpty && care.habits == .init())
        #expect(!CareEngine.reply(letterId: 7, replyId: "ask-next-time", date: "later", journey: &journey, care: &care))
    }
}
