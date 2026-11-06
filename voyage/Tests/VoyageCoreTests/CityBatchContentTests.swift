import Foundation
import Testing
@testable import VoyageCore

let firstBatchCityIds = ["shanghai", "hangzhou", "suzhou", "quanzhou", "jingdezhen", "kyoto"]
let secondBatchCityIds = ["beijing", "chengdu", "xian", "tokyo", "osaka", "fukuoka", "seoul", "busan", "taipei", "hongkong", "bangkok", "hanoi"]
let thirdBatchCityIds = ["singapore", "istanbul", "rome", "paris", "lisbon", "barcelona", "london", "newyork", "mexicocity", "cairo", "marrakesh", "chiangmai"]
let fullContentCityIds = firstBatchCityIds + secondBatchCityIds + thirdBatchCityIds

@Suite struct CityBatchContentTests {
    @Test func fullCitiesHaveSourcedFactsStoriesMenusAndLocalSouvenirs() throws {
        #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
        #expect(Set(testCatalog.all.filter { $0.level == "full" }.map(\.id)) == Set(fullContentCityIds))
        let report = try String(contentsOf: contentDirectory.appendingPathComponent("sources-review.md"), encoding: .utf8)
        for id in fullContentCityIds {
            let city = try #require(testCatalog.find(id))
            #expect(city.level == "full")
            #expect(city.facts.filter { $0.type == "place" }.count == 2)
            #expect(city.facts.filter { $0.type == "food" }.count == 2)
            for fact in city.facts {
                #expect(!fact.sources.isEmpty && fact.sources.allSatisfy { $0.hasPrefix("https://") })
                for language in ["zh-Hans", "en"] { #expect(fact.summary?[language]?.isEmpty == false) }
                #expect(report.contains("\(id).\(fact.id)"))
                #expect(fact.sources.allSatisfy { report.contains($0) })
            }
            let stories = testCatalog.stories.all.filter { $0.cityId == id }
            let arrivals = stories.filter { $0.kind == "arrival" }
            #expect(arrivals.count >= 4)
            #expect(arrivals.filter { !$0.factIds.isEmpty }.count >= 2)
            for habit in ["talkative", "observant"] {
                #expect(arrivals.contains { $0.requires.habit == habit })
            }
            #expect(Set(stories.flatMap(\.factIds)) == Set(city.facts.map(\.id)))
            let replies = Set(stories.flatMap { $0.replies.map(\.id) })
            #expect(stories.contains { $0.kind == "fulfill" && !$0.fulfills.isEmpty && Set($0.fulfills).isSubset(of: replies) })
            for story in stories { #expect(story.lead != nil && story.replies.count == 2) }
            let items = testCatalog.items.all.filter { $0.cityId == id }
            let menus = items.filter { $0.kind == "menu" }
            #expect(menus.count == 2)
            #expect(Set(stories.flatMap { $0.rewards.menuIds }) == Set(menus.map(\.id)))
            for (rarity, count) in [("common", 2), ("uncommon", 1), ("rare", 1)] {
                #expect(items.filter { $0.kind == "souvenir" && $0.rarity == rarity }.count == count)
            }
        }
    }

    @Test(arguments: ["hangzhou", "suzhou", "quanzhou", "jingdezhen"])
    func newDossiersReplaceBaseRowsWithoutMovingOrRenamingThem(id: String) throws {
        let city = try #require(testCatalog.find(id))
        let base = try #require(CityContent.readBase(directory: contentDirectory).first { $0.id == city.wikidata })
        #expect(testCatalog.find(base.id)?.id == id)
        #expect(testCatalog.find(base.id.uppercased()) == city)
        #expect(testCatalog.all.filter { $0.wikidata == base.id }.count == 1)
        #expect(!testCatalog.all.contains { $0.id == base.id })
        #expect(city.coordinate == base.coordinate)
        #expect(city.countryCode == base.countryCode && city.continent == base.continent)
        #expect(city.tier == base.tier && city.names == base.names)
        let published = try String(contentsOf: contentDirectory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(published.contains(id) && published.contains(base.id))
    }

    @Test func shanghaiFirstStopIsNearbyAndHasRealContent() {
        var selected: Set<String> = []
        for seed in UInt32(0)..<64 {
            let journey = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
            selected.insert(journey.targetCityId)
            #expect(["hangzhou", "suzhou"].contains(journey.targetCityId))
            #expect(testCatalog.city(journey.targetCityId).level == "full")
            #expect(journey.legCost <= DestinationPicker.configuration.minimumMedianFuel)
        }
        #expect(selected == ["hangzhou", "suzhou"])
        #expect(testCatalog.find("q4970")?.id == "hangzhou")
    }

    @Test(arguments: fullContentCityIds, ["new", "talkative", "observant"])
    func actualArrivalsSnapshotFactsAndCollectEachMenuOnce(cityId: String, habit: String) throws {
        var (journey, care) = engineState(seed: 42)
        care.bag.owned = []
        if habit == "talkative" { care.habits.talkative = 10 }
        if habit == "observant" { care.habits.observant = 10 }
        for id in 1...16 {
            journey.letters.append(engineLetter(id, arrivals: [cityId], cityId: cityId))
            CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
            let letter = try #require(journey.letters.last)
            let story = try #require(testCatalog.stories.all.first { $0.id == letter.storyId })
            #expect(story.cityId == cityId && story.kind == "arrival")
            #expect(!letter.facts.isEmpty)
            for snapshot in letter.facts {
                let fact = try #require(testCatalog.city(cityId).facts.first { $0.id == snapshot.id })
                #expect(snapshot.names == fact.names && snapshot.sources == fact.sources && snapshot.summary == fact.summary)
            }
            for (language, text) in try #require(letter.texts) {
                let withoutPet = text.replacingOccurrences(of: care.petName, with: "Pip")
                #expect((withoutPet.range(of: #"\p{Han}"#, options: .regularExpression) != nil) == (language == "zh-Hans"))
            }
            #expect(letter.rewards.itemIds.count == 1)
            #expect(testCatalog.items.find(letter.rewards.itemIds[0])?.cityId == cityId)
        }
        let menus = testCatalog.items.all.filter { $0.cityId == cityId && $0.kind == "menu" }
        #expect(Set(care.menus.map(\.id)) == Set(menus.map(\.id)))
        #expect(care.menus.count == 2)
        let savedJourney = journey
        let savedCare = care
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey == savedJourney && care == savedCare)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
    }

    @Test(arguments: fullContentCityIds)
    func realCityPromiseContinuesTheExactReplyOnTheNextLetter(cityId: String) throws {
        let payoff = try #require(testCatalog.stories.all.first { $0.cityId == cityId && $0.kind == "fulfill" })
        let replyId = try #require(payoff.fulfills.first)
        let origin = try #require(testCatalog.stories.all.first { $0.replies.contains { $0.id == replyId } })
        var (journey, care) = engineState()
        care.bag.owned = []
        care.habits.talkative = 10
        care.habits.observant = 10
        journey.letters.append(engineLetter(1, arrivals: [cityId], cityId: cityId))
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [origin]), catalog: testCatalog)
        #expect(CareEngine.reply(letterId: 1, replyId: replyId, date: "2026-11-02", journey: &journey, care: &care))
        journey.letters.append(engineLetter(2, arrivals: [], cityId: cityId))
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let letter = try #require(journey.letters.last)
        #expect(letter.storyId == payoff.id && letter.fulfilledReplyId == replyId)
        #expect(care.pendingPromises.isEmpty)
        let reply = try #require(origin.replies.first { $0.id == replyId })
        for language in ["zh-Hans", "en"] {
            #expect(letter.leadTexts[language]?.contains(reply.text[language]!) == true)
        }
    }

    @Test(arguments: fullContentCityIds)
    func localSouvenirsAreReachableAndAuthoredRewardsRespectRolledRarity(cityId: String) throws {
        let local = testCatalog.items.all.filter { $0.cityId == cityId && $0.kind == "souvenir" }
        let letter = engineLetter(1, arrivals: [cityId], cityId: cityId)
        let (_, care) = engineState()
        var found: Set<String> = []
        for seed in UInt32(0)..<256 {
            let drop = testCatalog.items.drop(rewards: .init(), letter: letter, care: care, seed: seed)
            found.formUnion(drop.itemIds)
        }
        #expect(found == Set(local.map(\.id)))
        for item in local {
            var rewards = StoryRewards()
            rewards.itemIds = [item.id]
            for seed in UInt32(0)..<64 {
                let drop = testCatalog.items.drop(rewards: rewards, letter: letter, care: care, seed: seed)
                #expect(testCatalog.items.find(drop.itemIds[0])?.rarity == drop.dropRarity)
                if item.rarity == drop.dropRarity { #expect(drop.itemIds == [item.id]) }
                else { #expect(drop.itemIds != [item.id]) }
            }
        }
    }

    @Test(arguments: ["basic", "facts", "full"], ["missing", "empty", "english-only", "blank-chinese"])
    func summaryDecodesOptionallyButIsRequiredForNonBasicFacts(level: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit { city in
            city["level"] = level
            var facts = city["facts"] as! [[String: Any]]
            switch failure {
            case "missing": facts[0].removeValue(forKey: "summary")
            case "empty": facts[0]["summary"] = [String: String]()
            case "english-only": facts[0]["summary"] = ["en": "A riverfront."]
            default: facts[0]["summary"] = ["en": "A riverfront.", "zh-Hans": " \n "]
            }
            city["facts"] = facts
        }
        let catalog = try CityCatalog.load(directory: box.directory)
        if failure == "missing" { #expect(catalog.city("shanghai").facts[0].summary == nil) }
        let issues = ContentValidator.validate(directory: box.directory)
        #expect(issues.contains { $0.rule == "factSummary" } == (level != "basic"))
        if level == "basic" { #expect(issues.isEmpty) }
    }

    @Test func oldLetterFactsDecodeWithoutSummaryAndReviewMarkdownIsIgnored() throws {
        let old = Data(#"{"id":"old","names":{"en":"A place","zh-Hans":"地点"},"sources":["https://whc.unesco.org/"]}"#.utf8)
        let snapshot = try JSONDecoder().decode(Letter.FactSnapshot.self, from: old)
        #expect(snapshot.summary == nil)
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try Data("This is deliberately not JSON: {".utf8).write(to: box.directory.appendingPathComponent("sources-review.md"))
        #expect(ContentValidator.validate(directory: box.directory).isEmpty)
        let catalog = try CityCatalog.load(directory: box.directory)
        #expect(catalog.all == testCatalog.all && catalog.items.all == testCatalog.items.all && catalog.stories.all == testCatalog.stories.all)
    }
}
