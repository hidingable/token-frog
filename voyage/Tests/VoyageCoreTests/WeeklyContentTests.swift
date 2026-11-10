import Foundation
import Testing
@testable import VoyageCore

@Suite struct WeeklyContentTests {
    @Test func boxPackHasSixteenExclusiveBilingualCommonSouvenirsAndOrderedBags() throws {
        let boxes = testCatalog.items.boxes
        #expect(boxes.souvenirIds.count >= 16)
        #expect(boxes.souvenirIds.first == "box.tea-paper")
        #expect(boxes.bagItemIds == ["old-camera", "lunchbox"])
        #expect(Set(boxes.souvenirIds).count == boxes.souvenirIds.count)
        #expect(Set(testCatalog.items.all.filter { $0.source == "box" }.map(\.id)) == Set(boxes.souvenirIds))
        for id in boxes.souvenirIds {
            let item = try #require(testCatalog.items.find(id))
            #expect(item.kind == "souvenir" && item.rarity == "common" && item.source == "box")
            #expect(item.cityId == nil)
            for texts in [item.names, item.descriptions] {
                #expect(!texts["zh-Hans"]!.isEmpty && !texts["en"]!.isEmpty)
            }
        }
    }

    @Test(arguments: ["missing-souvenir", "wrong-souvenir-kind", "ordinary-souvenir", "missing-bag", "wrong-bag-kind", "duplicate-souvenir", "duplicate-bag", "duplicate-across-lists"])
    func invalidBoxReferencesAndDuplicatesAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("boxes.json") { json in
            switch failure {
            case "missing-souvenir": json["souvenirIds"] = ["missing"]
            case "wrong-souvenir-kind": json["souvenirIds"] = ["old-camera"]
            case "ordinary-souvenir": json["souvenirIds"] = [testCatalog.items.all.first { $0.kind == "souvenir" && $0.source == nil }!.id]
            case "missing-bag": json["bagItemIds"] = ["missing"]
            case "wrong-bag-kind": json["bagItemIds"] = ["box.tea-paper"]
            case "duplicate-souvenir": json["souvenirIds"] = ["box.tea-paper", "box.tea-paper"]
            case "duplicate-bag": json["bagItemIds"] = ["old-camera", "old-camera"]
            default: json["bagItemIds"] = ["box.tea-paper"]
            }
        }
        let rule = failure.hasPrefix("duplicate") ? "boxDuplicate" : failure.hasSuffix("bag") || failure == "wrong-bag-kind" ? "boxBag" : "boxSouvenir"
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "boxes.json" && $0.rule == rule })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: ["missing", "malformed", "missing-souvenir-list", "missing-bag-list"])
    func boxFileMustBeReadableAndComplete(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("boxes.json")
        if failure == "missing" { try FileManager.default.removeItem(at: file) }
        else if failure == "malformed" { try Data("{".utf8).write(to: file) }
        else { try box.edit("boxes.json") { $0.removeValue(forKey: failure == "missing-souvenir-list" ? "souvenirIds" : "bagItemIds") } }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "boxes" })
    }

    @Test(arguments: ["unknown", "bag", "uncommon"])
    func sourceOnlyAllowsBoxOnCommonSouvenirs(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            let index = items.firstIndex { $0.id == "box.tea-paper" }!
            if failure == "unknown" { items[index].source = "drop" }
            else if failure == "bag" { items[index].kind = "bag"; items[index].rarity = nil }
            else { items[index].rarity = "uncommon" }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemSource" })
    }

    @Test func boxSouvenirsCannotReplaceTheOrdinaryCommonDropBaseline() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            items.removeAll { $0.kind == "souvenir" && $0.rarity == "common" && $0.source == nil }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemBaseline" })
    }

    @Test func dropsExcludeBoxSouvenirsEvenWhenAuthoredOrLocal() {
        var (_, care) = engineState()
        let ordinary = ["common", "uncommon", "rare"].map { (rarity: String) in engineItem("ordinary.\(rarity)", rarity: rarity) }
        var boxed = engineItem("box.only", city: "shanghai")
        boxed.source = "box"
        let library = ItemLibrary(items: ordinary + [boxed])
        var rewards = StoryRewards()
        rewards.itemIds = [boxed.id]
        for seed in UInt32(0)..<128 {
            for id in 1...16 {
                let result = library.drop(rewards: rewards, letter: engineLetter(id), care: care, seed: seed)
                #expect(result.itemIds.allSatisfy { library.find($0)?.source == nil })
                care.pity = result.dropRarity == "rare" ? 0 : care.pity + 1
            }
        }
    }

    @Test func allThirtyGenericDedicatedAndEightHabitFulfillmentsHaveShortBilingualLearnedTexts() throws {
        let dedicated = testCatalog.stories.all.filter { !$0.fulfills.isEmpty && $0.cityId == nil }
        let habits = testCatalog.stories.all.filter { $0.fulfillsHabit != nil }
        #expect(dedicated.count == 30 && habits.count == 8)
        for story in dedicated + habits {
            let learned = try #require(story.learned)
            let chinese = try #require(learned["zh-Hans"])
            let english = try #require(learned["en"])
            #expect((1...16).contains(chinese.count) && !english.isEmpty)
            #expect(chinese.range(of: #"\p{Han}"#, options: .regularExpression) != nil)
            #expect(english.range(of: #"\p{Han}"#, options: .regularExpression) == nil)
            #expect(learned.values.allSatisfy { !$0.contains("{") && !$0.contains("}") })
        }
    }

    @Test(arguments: ["zh-Hans", "en"], ["missing", "blank", "slot", "malformed-slot"])
    func learnedTextsRequireCompleteTranslationsWithoutSlots(language: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            let index = stories.firstIndex { $0["learned"] != nil }!
            var learned = stories[index]["learned"] as! [String: String]
            learned[language] = ["blank": " \n ", "slot": "{pet}", "malformed-slot": "{pet"][failure]
            stories[index]["learned"] = learned
        }
        let rule = failure.contains("slot") ? "storyLearnedSlots" : "storyLearnedTranslation"
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
    }

    @Test func learnedChineseLengthIsValidated() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            stories[0]["learned"] = ["zh-Hans": String(repeating: "看", count: 17), "en": "Look closer."]
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyLearnedLength" })
    }

    @Test func learnedIsAnImmutableLetterSnapshotAndRecentEntriesSortByLetterId() throws {
        var (journey, care) = engineState()
        var story = engineStory("learned")
        story.learned = ["zh-Hans": "多看一眼会有新发现", "en": "Another look reveals more."]
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story]), catalog: testCatalog)
        let saved = journey
        story.learned = ["zh-Hans": "换过的心得", "en": "Changed lesson."]
        // Replay care after a split-write recovery, with a replacement pack.
        var recoveredCare = engineState().1
        CareEngine.process(journey: &journey, care: &recoveredCare, stories: .init(stories: [story]), catalog: testCatalog)
        #expect(journey == saved)
        #expect(journey.letters[1].learnedTexts != story.learned)
        journey.letters.append(engineLetter(2)) // No learned text: omitted from the profile list.
        var newest = engineLetter(3)
        newest.learnedTexts = story.learned!
        journey.letters.insert(newest, at: 0)
        let recent = CareEngine.recentLearned(journey: journey, limit: 10)
        #expect(recent.map(\.letterId) == [3, 1])
        #expect(recent[1].learnedTexts == saved.letters[1].learnedTexts)
        #expect(CareEngine.recentLearned(journey: journey, limit: 1).map(\.letterId) == [3])
        #expect(CareEngine.recentLearned(journey: journey, limit: 0).isEmpty)
        #expect(CareEngine.recentLearned(journey: journey, limit: -1).isEmpty)
        let decoded = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        #expect(decoded == journey)
    }

    @Test func legacyCareSouvenirAndLettersDecodeWithoutNewFields() throws {
        let careURL = try #require(Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures"))
        let care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: careURL))
        #expect(care.version == 1 && CareState.currentVersion == 1)
        #expect(care.boxesOpened == 0 && care.boxItemIndex == 0)
        #expect(care.souvenirs[0].letterId == 3 && care.souvenirs[0].boxId == nil)
        let souvenir = try JSONDecoder().decode(CareState.Souvenir.self, from: Data(#"{"id":"old","letterId":2,"shelved":true}"#.utf8))
        #expect(souvenir.letterId == 2 && souvenir.boxId == nil && souvenir.shelved)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
        let journeyURL = try #require(Bundle.module.url(forResource: "journey-v5", withExtension: "json", subdirectory: "Fixtures"))
        let journey = try decodeOldJourneyFixture(Data(contentsOf: journeyURL))
        #expect(journey.letters.allSatisfy { $0.learnedTexts.isEmpty })
    }

    @Test(arguments: ["boxesOpened", "boxItemIndex"])
    func negativePersistedBoxCountersAreRejected(key: String) throws {
        let url = try #require(Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json[key] = -1
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CareState.self, from: data) }
    }
}
