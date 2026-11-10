import Foundation
import Testing
@testable import VoyageCore

private func replayCare(seed: UInt32, multiplier: Int, stories: StoryLibrary, wish: Bool = false, openFloor: Bool = false) -> (JourneyState, CareState) {
    var (journey, care) = engineState(seed: seed)
    if wish { WishEngine.write("看海", tags: ["coast"], at: DayKey.date(from: journey.openDate)!, care: &care) }
    for day in 0..<60 {
        let date = journey.openDate
        let next = DayKey.next(date, calendar: careCalendar)
        let amount = day % 9 == 8 ? 0 : (day % 5 + 1) * 3_000_000 * multiplier
        journey.sync(
            today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount, byClient: ["codex": amount], observedTokens: amount * 100)], now: DayKey.date(from: (DayUsage(date: next)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600),
            calendar: careCalendar, catalog: testCatalog, wishTags: WishEngine.tags(in: care)
        )
        // The same policy exercises explicit choices, random carry and invalid unowned choices.
        care.bag.owned = ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"]
        care.bag.todayItem = ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox", nil, "unowned"][day % 7]
        if day % 6 != 5 { CareEngine.markCompanion(date: next, care: &care) }
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog, wishTags: WishEngine.tags(in: care))
        if openFloor {
            for parcel in HomeFloor.parcels(journey: journey, care: care) {
                HomeFloor.openParcel(parcel.id, journey: &journey, care: care)
            }
            _ = HomeFloor.looseBoardRoll(seed: journey.seed, tripCount: journey.tripCount)
            for city in journey.route { _ = HomeFloor.rugColorIndex(cityID: city) }
        }
        if let letter = journey.letters.last, letter.kind == .daily, letter.id % 4 == 1 {
            // Policy depends only on letter number, including which habit to encourage.
            let replyId = letter.id % 8 == 1 ? "ask-next-time" : "look-closer"
            CareEngine.reply(letterId: letter.id, replyId: replyId, date: next, journey: &journey, care: &care)
        }
    }
    return (journey, care)
}

// This immutable fixture contains one story per catalog city. Build it once rather than
// regenerating thousands of identical stories for every letter in the replay checks.
private let cachedReplayStories: StoryLibrary = {
    let itemStories = ["sketchbook", "note-slip", "old-camera", "lunchbox"].flatMap { item in
        ["arrival", "transit"].map { kind in
            var story = engineStory("item.\(item).\(kind)", kind: kind)
            story.requires.item = item
            return story
        }
    }
    return engineStories(itemStories + testCatalog.all.map { city in
        var story = engineStory("\(city.id).fulfill", city: city.id)
        story.fulfills = ["ask-next-time", "look-closer"]
        // This also matches an ordinary selection tier: it must never accelerate the promise.
        story.requires.tool = "codex"
        story.lead = ["zh-Hans": "你说“{reply}”，我记着呢。", "en": "I kept your note: {reply}."]
        return story
    })
}()

private func replayStories() -> StoryLibrary { cachedReplayStories }

@Suite struct CareReplayTests {
    @Test(arguments: [UInt32(1), 7, 42])
    func savedWishAndDoubledUsagePreserveRaising(seed: UInt32) {
        let (normal, care) = replayCare(seed: seed, multiplier: 1, stories: replayStories(), wish: true)
        let (doubled, doubledCare) = replayCare(seed: seed, multiplier: 2, stories: replayStories(), wish: true)
        #expect(normal.letters.map(\.date) == doubled.letters.map(\.date))
        #expect(normal.letters.map(\.fulfilledReplyId) == doubled.letters.map(\.fulfilledReplyId))
        #expect(normal.letters.map(\.rewards.dropRarity) == doubled.letters.map(\.rewards.dropRarity))
        #expect(normal.letters.map(\.carriedItem) == doubled.letters.map(\.carriedItem))
        #expect(normal.letters.map(\.itemTriggered) == doubled.letters.map(\.itemTriggered))
        #expect(care.habits == doubledCare.habits && care.pity == doubledCare.pity)
        #expect(care.companionDays == doubledCare.companionDays && care.weekly == doubledCare.weekly)
        #expect(care.identity == doubledCare.identity && care.pendingPromises == doubledCare.pendingPromises)
        #expect(care.memories == doubledCare.memories && care.specialDays == doubledCare.specialDays)
        #expect(Stage.current(companionDays: care.companionDays.count) == Stage.current(companionDays: doubledCare.companionDays.count))
        #expect(doubled.totalFuel == normal.totalFuel * 2)
        #expect(doubled.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } == normal.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } * 2)
    }

    @Test(arguments: Array(UInt32(0)..<32))
    func sixtyDaysOfDoubledUsagePreserveAllCompanionProgress(seed: UInt32) {
        let stories = replayStories()
        let (normal, care) = replayCare(seed: seed, multiplier: 1, stories: stories)
        let (doubled, doubledCare) = replayCare(seed: seed, multiplier: 2, stories: stories, openFloor: true)
        #expect(normal.letters.map(\.id) == doubled.letters.map(\.id))
        #expect(normal.letters.map(\.date) == doubled.letters.map(\.date))
        #expect(normal.letters.map(\.fulfilledReplyId) == doubled.letters.map(\.fulfilledReplyId))
        #expect(care.habits == doubledCare.habits)
        #expect(care.companionDays == doubledCare.companionDays) // The days used for form progression.
        #expect(care.companionDays.count == 50)
        #expect(Stage.current(companionDays: care.companionDays.count) == Stage.current(companionDays: doubledCare.companionDays.count))
        #expect(care.weekly == doubledCare.weekly)
        #expect(care.identity == doubledCare.identity)
        #expect(care.pity == doubledCare.pity)
        #expect(normal.letters.map(\.rewards.dropRarity) == doubled.letters.map(\.rewards.dropRarity))
        #expect(normal.letters.map(\.carriedItem) == doubled.letters.map(\.carriedItem))
        #expect(normal.letters.map(\.itemTriggered) == doubled.letters.map(\.itemTriggered))
        #expect(care.memories == doubledCare.memories)
        #expect(care.specialDays == doubledCare.specialDays)
        #expect(care.pendingPromises == doubledCare.pendingPromises)
        #expect(normal.letters[2].fulfilledReplyId == "ask-next-time")
        #expect(normal.letters.contains { $0.storyId?.hasSuffix(".fulfill") == true })
        #expect(doubled.totalFuel == normal.totalFuel * 2)
        #expect(doubled.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } == normal.days.values.reduce(0) { $0 + ($1.tokens ?? 0) } * 2)
    }

    @Test(arguments: [UInt32(1), 7, 42])
    func floorInteractionsLeaveAllRewardsAndCareUntouched(seed: UInt32) {
        let (normal, care) = replayCare(seed: seed, multiplier: 1, stories: replayStories())
        let (opened, openedCare) = replayCare(seed: seed, multiplier: 1, stories: replayStories(), openFloor: true)
        #expect(care == openedCare)
        #expect(normal.letters == opened.letters)
        #expect(normal.route == opened.route && normal.totalKm == opened.totalKm && normal.travelFund == opened.travelFund)
    }

    @Test func everySeedFulfillsTheFirstReplyNextLetterAndLaterRepliesWithinThreeHeadLetters() throws {
        var observedDelays: Set<Int> = []
        for seed in UInt32(0)..<64 {
            var (journey, care) = engineState(seed: seed)
            var outstanding: (letter: Int, reply: String)?
            for id in 1...64 {
                journey.letters.append(engineLetter(id, arrivals: id % 2 == 0 ? [] : ["shanghai"]))
                CareEngine.process(journey: &journey, care: &care, stories: replayStories(), catalog: testCatalog)
                if let promise = outstanding {
                    if journey.letters.last?.fulfilledReplyId == promise.reply {
                        observedDelays.insert(id - promise.letter)
                        #expect((1...3).contains(id - promise.letter))
                        if promise.letter == 1 { #expect(id == 2) }
                        outstanding = nil
                    } else { #expect(id - promise.letter < 3) }
                }
                if id % 4 == 1 {
                    // With replies four letters apart, each one reaches the head immediately.
                    let reply = id % 8 == 1 ? "ask-next-time" : "look-closer"
                    #expect(CareEngine.reply(letterId: id, replyId: reply, date: "reply-date", journey: &journey, care: &care))
                    outstanding = (id, reply)
                }
            }
            #expect(outstanding == nil)
            #expect(care.memories.filter { $0.kind == "reply" }.count == care.memories.filter { $0.kind == "fulfilled" }.count)
        }
        #expect(observedDelays == [1, 2, 3])
    }

    @Test func backloggedPromisesCountThreeLettersOnlyAfterReachingTheHead() throws {
        var observedDelays: Set<Int> = []
        for seed in UInt32(0)..<64 {
            var (journey, care) = engineState(seed: seed)
            // Answer eight already-sent letters together, creating a real backlog.
            for id in 1...8 {
                var letter = engineLetter(id)
                letter.storyId = "sent.\(id)"
                letter.replyOptions = [.init(id: "sent.\(id).reply", habit: "talkative", text: ["zh-Hans": "再聊一句", "en": "Keep the chat going"])]
                journey.letters.append(letter)
                care.processedLetterIds.append(id)
                #expect(CareEngine.reply(letterId: id, replyId: letter.replyOptions[0].id, date: "later", journey: &journey, care: &care))
            }
            var headSince = 9
            var fulfilledLetters: [Int] = []
            for id in 9...32 {
                let head = try #require(care.pendingPromises.first)
                let beforeCount = care.pendingPromises.count
                let beforeMemories = care.memories.count
                journey.letters.append(engineLetter(id))
                CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
                if let fulfilled = journey.letters.last?.fulfilledReplyId {
                    #expect(fulfilled == head.replyId)
                    #expect(care.pendingPromises.count == beforeCount - 1)
                    #expect(care.memories.count == beforeMemories + 1)
                    let delay = id - headSince + 1
                    observedDelays.insert(delay)
                    #expect((1...3).contains(delay))
                    if fulfilledLetters.isEmpty { #expect(id == 9) }
                    fulfilledLetters.append(id)
                    headSince = id + 1
                    #expect(care.pendingPromises.allSatisfy { $0.attempts == 0 })
                } else {
                    #expect(care.pendingPromises.count == beforeCount)
                    #expect(care.memories.count == beforeMemories)
                    #expect(care.pendingPromises[0].attempts == head.attempts + 1)
                    #expect(id - headSince + 1 < 3)
                    #expect(care.pendingPromises.dropFirst().allSatisfy { $0.attempts == 0 })
                }
                if care.pendingPromises.isEmpty { break }
            }
            #expect(care.pendingPromises.isEmpty && fulfilledLetters.count == 8)
            #expect(Set(fulfilledLetters).count == 8) // At most one promise per letter.
            #expect(fulfilledLetters.last! - 8 > 3) // Waiting behind others does not consume the window.
        }
        #expect(observedDelays == [1, 2, 3])
    }

    @Test(arguments: Array(UInt32(0)..<12))
    func seededReplayIsExactEvenWhenContentEnumerationOrderChanges(seed: UInt32) {
        let stories = replayStories()
        let (first, firstCare) = replayCare(seed: seed, multiplier: 1, stories: stories)
        let (second, secondCare) = replayCare(seed: seed, multiplier: 1, stories: .init(stories: stories.all.reversed()))
        #expect(first.letters.map(\.storyId) == second.letters.map(\.storyId))
        #expect(first.letters.map(\.texts) == second.letters.map(\.texts))
        #expect(first == second && firstCare == secondCare)
    }

    @Test func realContentRendersEveryTemplateWithoutSlotsAndKeepsPetNameInBothLanguages() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit { $0["rainyMonths"] = [11] }
        let catalog = try CityCatalog.load(directory: box.directory)
        for story in testCatalog.stories.all where !["postcard", "reunion"].contains(story.kind) {
            var (journey, care) = engineState(seed: 1)
            care.petName = "Pip 小信使"
            care.habits.talkative = 10
            care.habits.observant = 10
            if let item = story.requires.item { care.bag.owned = [item]; care.bag.todayItem = item }
            if story.kind == "revisit" {
                journey.letters.append(engineLetter(1, arrivals: [story.cityId!], cityId: story.cityId!))
                care.processedLetterIds.append(1)
                care.trailClues[story.cityId!] = 3
            }
            if story.kind == "fulfill" {
                let origin = story.fulfills.first.flatMap { replyId in
                    testCatalog.stories.all.first { $0.replies.contains { $0.id == replyId } }
                } ?? engineStory("origin")
                journey.letters.append(engineLetter(1, arrivals: origin.kind == "transit" ? [] : [origin.cityId ?? "shanghai"], cityId: origin.cityId ?? "shanghai"))
                CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [origin]), catalog: catalog)
                let replyId = story.fulfills.first ?? origin.replies.first { $0.habit == story.fulfillsHabit }!.id
                CareEngine.reply(letterId: 1, replyId: replyId, date: "later", journey: &journey, care: &care)
            }
            journey.letters.append(engineLetter(["fulfill", "revisit"].contains(story.kind) ? 2 : 1,
                                               arrivals: story.kind == "transit" ? [] : [story.cityId ?? "shanghai"],
                                               date: story.kind == "revisit" ? "2026-11-02" : "2026-11-01",
                                               cityId: story.cityId ?? "shanghai"))
            CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story] + (story.kind == "fulfill" ? [engineStory("arrival-fallback")] : [])), catalog: catalog)
            let letter = journey.letters.last!
            #expect(letter.storyId == story.id)
            for (language, text) in letter.texts! {
                #expect(!text.contains("{") && !text.contains("}"))
                if StorySlots.names(in: story.text[language]!).contains("pet") { #expect(text.contains(care.petName)) }
            }
            for text in Array(letter.leadTexts.values) + letter.replyOptions.flatMap({ Array($0.text.values) }) {
                #expect(!text.contains("{") && !text.contains("}"))
            }
        }
    }

    @Test func realRepliesProduceTheirDedicatedBodiesAndThenUseHabitTemplates() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit { $0["rainyMonths"] = [11] }
        let catalog = try CityCatalog.load(directory: box.directory)
        let stories = testCatalog.stories
        for origin in stories.all where ["arrival", "transit"].contains(origin.kind) {
            for reply in origin.replies {
                var (journey, care) = engineState(seed: 1)
                care.habits.talkative = 10
                care.habits.observant = 10
                if let item = origin.requires.item { care.bag.owned = [item]; care.bag.todayItem = item }
                journey.letters.append(engineLetter(1, arrivals: origin.kind == "transit" ? [] : [origin.cityId ?? "shanghai"], cityId: origin.cityId ?? "shanghai"))
                CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [origin]), catalog: catalog)
                #expect(CareEngine.reply(letterId: 1, replyId: reply.id, date: "later", journey: &journey, care: &care))
                // A payoff must work even when the next letter is written on the road.
                journey.letters.append(engineLetter(2, arrivals: [], cityId: origin.cityId ?? "shanghai"))
                CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog)
                let letter = try #require(journey.letters.last)
                let payoff = try #require(stories.all.first { $0.id == letter.storyId })
                let hasDedicatedPayoff = stories.all.contains { $0.fulfills == [reply.id] && ($0.cityId == nil || $0.cityId == origin.cityId) }
                if hasDedicatedPayoff {
                    #expect(payoff.fulfills == [reply.id] && payoff.fulfillsHabit == nil)
                } else {
                    #expect(payoff.fulfills.isEmpty && payoff.fulfillsHabit == reply.habit)
                }
                #expect(letter.fulfilledReplyId == reply.id)
                for language in ["zh-Hans", "en"] {
                    let replyText = try #require(reply.text[language])
                    let template = try #require(payoff.text[language])
                    let expected = template.replacingOccurrences(of: "{pet}", with: care.petName)
                        .replacingOccurrences(of: "{reply}", with: replyText)
                        .replacingOccurrences(of: "{city}", with: catalog.city(letter.cityId).names[language]!)
                    #expect(letter.texts?[language] == expected)
                    #expect(letter.leadTexts[language]?.contains(replyText) == true)
                }
                for followUp in letter.replyOptions {
                    var continuedJourney = journey
                    var continuedCare = care
                    #expect(CareEngine.reply(letterId: 2, replyId: followUp.id, date: "later", journey: &continuedJourney, care: &continuedCare))
                    for id in 3...5 {
                        continuedJourney.letters.append(engineLetter(id, arrivals: [], cityId: origin.cityId ?? "shanghai"))
                        CareEngine.process(journey: &continuedJourney, care: &continuedCare, stories: stories, catalog: catalog)
                        guard let next = continuedJourney.letters.last, next.fulfilledReplyId != nil else { continue }
                        let template = try #require(stories.all.first { $0.id == next.storyId })
                        #expect(next.fulfilledReplyId == followUp.id)
                        #expect(template.fulfills.isEmpty && template.fulfillsHabit == followUp.habit)
                        for language in ["zh-Hans", "en"] {
                            #expect(next.leadTexts[language]?.contains(followUp.text[language]!) == true)
                        }
                        break
                    }
                    #expect(continuedCare.pendingPromises.isEmpty)
                }
            }
        }
    }

    @Test func factsBodiesRepliesAndLeadsAreSnapshotsAfterAContentUpdate() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let source = "https://en.wikipedia.org/wiki/Window"
        let summary = ["zh-Hans": "测试用窗。", "en": "A test window."]
        try box.edit { $0["facts"] = [["id": "window", "type": "place", "names": ["zh-Hans": "窗", "en": "Window"], "sources": [source], "summary": summary]] }
        var story = engineStory("local.snapshot", city: "shanghai")
        story.factIds = ["window"]
        story.rewards.itemIds = [testCatalog.items.all.first { $0.kind == "souvenir" }!.id]
        let file = box.directory.appendingPathComponent("stories/local.json")
        try JSONEncoder().encode([story]).write(to: file)
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story] + (story.kind == "fulfill" ? [engineStory("arrival-fallback")] : [])), catalog: catalog)
        let snapshot = journey.letters[1]
        #expect(snapshot.storyVersion == 1 && snapshot.rewards.itemIds.count == 1 && snapshot.rewards.dropRarity != nil)
        #expect(snapshot.facts.first?.names == ["zh-Hans": "窗", "en": "Window"])
        #expect(snapshot.facts.first?.sources == [source])
        #expect(snapshot.facts.first?.summary == summary)
        let encoded = try JSONEncoder().encode(journey)
        #expect(try JSONDecoder().decode(JourneyState.self, from: encoded).letters[1].facts == snapshot.facts)
        story.version = 2
        story.text = ["zh-Hans": "新的文字", "en": "Replacement body"]
        story.replies[0].text = ["zh-Hans": "改过的回应", "en": "Edited reply"]
        try JSONEncoder().encode([story]).write(to: file)
        try box.edit { $0["facts"] = [] }
        story.factIds = []
        try JSONEncoder().encode([story]).write(to: file)
        let updatedCatalog = try CityCatalog.load(directory: box.directory)
        CareEngine.process(journey: &journey, care: &care, stories: updatedCatalog.stories, catalog: updatedCatalog)
        #expect(journey.letters[1] == snapshot)
        CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "later", journey: &journey, care: &care)
        journey.letters.append(engineLetter(2))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: updatedCatalog)
        #expect(journey.letters.last?.leadTexts["en"] == "You wrote: Ask next time.")
        let before = journey.letters.last
        CareEngine.process(journey: &journey, care: &care, stories: updatedCatalog.stories, catalog: updatedCatalog)
        #expect(journey.letters.last == before)
    }

    @Test func slotsInsideALiteralPetNameAreNotExpandedAgain() {
        var (journey, care) = engineState()
        care.petName = "Pip {city}"
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.texts?["en"] == "A letter from Pip {city}, writing in Shanghai.")
        #expect(journey.letters.last?.texts?["zh-Hans"] == "Pip {city}从上海寄来一封信。")
    }
}
