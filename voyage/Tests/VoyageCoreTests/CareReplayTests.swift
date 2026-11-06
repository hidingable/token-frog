import Foundation
import Testing
@testable import VoyageCore

private func replayCare(seed: UInt32, multiplier: Int, stories: StoryLibrary) -> (JourneyState, CareState) {
    var (journey, care) = engineState(seed: seed)
    for day in 0..<60 {
        let date = journey.openDate
        let next = DayKey.next(date, calendar: careCalendar)
        let amount = day % 9 == 8 ? 0 : (day % 5 + 1) * 3_000_000 * multiplier
        journey.sync(
            today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount, byClient: ["codex": amount])],
            calendar: careCalendar, catalog: testCatalog
        )
        if day % 6 != 5 { CareEngine.markCompanion(date: next, care: &care) }
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog)
        if let letter = journey.letters.last, letter.kind == .daily, letter.id % 4 == 1 {
            // Policy depends only on letter number, including which habit to encourage.
            let replyId = letter.id % 8 == 1 ? "ask-next-time" : "look-closer"
            CareEngine.reply(letterId: letter.id, replyId: replyId, date: next, journey: &journey, care: &care)
        }
    }
    return (journey, care)
}

private func replayStories() -> StoryLibrary {
    engineStories(testCatalog.all.map { city in
        var story = engineStory("\(city.id).fulfill", city: city.id)
        story.fulfills = ["ask-next-time", "look-closer"]
        // This also matches an ordinary selection tier: it must never accelerate the promise.
        story.requires.tool = "codex"
        story.lead = ["zh-Hans": "你说“{reply}”，我记着呢。", "en": "I kept your note: {reply}."]
        return story
    })
}

@Suite struct CareReplayTests {
    @Test(arguments: Array(UInt32(0)..<32))
    func sixtyDaysOfDoubledUsagePreserveAllCompanionProgress(seed: UInt32) {
        let stories = replayStories()
        let (normal, care) = replayCare(seed: seed, multiplier: 1, stories: stories)
        let (doubled, doubledCare) = replayCare(seed: seed, multiplier: 2, stories: stories)
        #expect(normal.letters.map(\.id) == doubled.letters.map(\.id))
        #expect(normal.letters.map(\.date) == doubled.letters.map(\.date))
        #expect(normal.letters.map(\.fulfilledReplyId) == doubled.letters.map(\.fulfilledReplyId))
        #expect(care.habits == doubledCare.habits)
        #expect(care.companionDays == doubledCare.companionDays) // The days used for form progression.
        #expect(care.companionDays.count == 50)
        #expect(care.identity == doubledCare.identity)
        #expect(care.pity == doubledCare.pity && care.pity == 0)
        #expect(care.memories == doubledCare.memories)
        #expect(care.pendingPromises == doubledCare.pendingPromises)
        #expect(normal.letters[2].fulfilledReplyId == "ask-next-time")
        #expect(normal.letters.contains { $0.storyId?.hasSuffix(".fulfill") == true })
        #expect(doubled.totalFuel == normal.totalFuel * 2)
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

    @Test func realContentRendersEveryTemplateWithoutSlotsAndKeepsPetNameInBothLanguages() {
        for story in testCatalog.stories.all {
            var (journey, care) = engineState()
            care.petName = "Pip 小信使"
            if story.kind == "fulfill" {
                let origin = story.fulfills.first.flatMap { replyId in
                    testCatalog.stories.all.first { $0.replies.contains { $0.id == replyId } }
                } ?? engineStory("origin")
                journey.letters.append(engineLetter(1, arrivals: origin.kind == "transit" ? [] : ["shanghai"]))
                CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [origin]), catalog: testCatalog)
                let replyId = story.fulfills.first ?? origin.replies.first { $0.habit == story.fulfillsHabit }!.id
                CareEngine.reply(letterId: 1, replyId: replyId, date: "later", journey: &journey, care: &care)
            }
            journey.letters.append(engineLetter(story.kind == "fulfill" ? 2 : 1, arrivals: story.kind == "transit" ? [] : ["shanghai"]))
            CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story]), catalog: testCatalog)
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
        let stories = testCatalog.stories
        for origin in stories.all where ["arrival", "transit"].contains(origin.kind) {
            for reply in origin.replies {
                var (journey, care) = engineState()
                journey.letters.append(engineLetter(1, arrivals: origin.kind == "transit" ? [] : ["shanghai"]))
                CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [origin]), catalog: testCatalog)
                #expect(CareEngine.reply(letterId: 1, replyId: reply.id, date: "later", journey: &journey, care: &care))
                // A payoff must work even when the next letter is written on the road.
                journey.letters.append(engineLetter(2, arrivals: []))
                CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog)
                let letter = try #require(journey.letters.last)
                let payoff = try #require(stories.all.first { $0.id == letter.storyId })
                #expect(payoff.fulfills == [reply.id] && payoff.fulfillsHabit == nil)
                #expect(letter.fulfilledReplyId == reply.id)
                for language in ["zh-Hans", "en"] {
                    let replyText = try #require(reply.text[language])
                    let template = try #require(payoff.text[language])
                    let expected = template.replacingOccurrences(of: "{pet}", with: care.petName)
                        .replacingOccurrences(of: "{reply}", with: replyText)
                    #expect(letter.texts?[language] == expected)
                    #expect(letter.leadTexts[language]?.contains(replyText) == true)
                }
                for followUp in letter.replyOptions {
                    var continuedJourney = journey
                    var continuedCare = care
                    #expect(CareEngine.reply(letterId: 2, replyId: followUp.id, date: "later", journey: &continuedJourney, care: &continuedCare))
                    for id in 3...5 {
                        continuedJourney.letters.append(engineLetter(id, arrivals: []))
                        CareEngine.process(journey: &continuedJourney, care: &continuedCare, stories: stories, catalog: testCatalog)
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
        try box.edit { $0["facts"] = [["id": "window", "type": "place", "names": ["zh-Hans": "窗", "en": "Window"], "sources": [source]]] }
        var story = engineStory("local.snapshot", city: "shanghai")
        story.factIds = ["window"]
        story.rewards.itemIds = ["future-item"]
        let file = box.directory.appendingPathComponent("stories/local.json")
        try JSONEncoder().encode([story]).write(to: file)
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        let snapshot = journey.letters[1]
        #expect(snapshot.storyVersion == 1 && snapshot.rewards == .init())
        #expect(snapshot.facts.first?.names == ["zh-Hans": "窗", "en": "Window"])
        #expect(snapshot.facts.first?.sources == [source])
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
