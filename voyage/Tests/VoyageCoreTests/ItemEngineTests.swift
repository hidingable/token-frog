import Foundation
import Testing
@testable import VoyageCore

func engineItem(_ id: String, kind: String = "souvenir", rarity: String? = "common", city: String? = nil) -> Item {
    Item(id: id, kind: kind, cityId: city, rarity: rarity, icon: "note", habit: nil,
         names: ["zh-Hans": "旅途小物", "en": "A little keepsake"],
         descriptions: ["zh-Hans": "路上收到的小礼物。", "en": "A small gift from the road."])
}

private func dropLibrary(_ extra: [Item] = []) -> ItemLibrary {
    ItemLibrary(items: ["common", "uncommon", "rare"].map { (rarity: String) in
        engineItem("generic.\(rarity)", rarity: rarity)
    } + extra)
}

private func triggerSeed(letterId: Int = 1, triggered: Bool = true) -> UInt32 {
    (UInt32(0)..<1000).first { CareEngine.itemTrigger(seed: $0, letterId: letterId) == triggered }!
}

@Suite struct ItemEngineTests {
    @Test func rarityDistributionWithoutPityIsSeventyTwentyFiveFive() {
        var counts: [String: Int] = [:]
        let sampleCount = 100_000
        for seed in UInt32(0)..<1000 {
            for id in 1...100 {
                counts[ItemDropRules.rarity(seed: seed, letterId: id, pity: 0), default: 0] += 1
            }
        }
        for (rarity, expected) in [("common", 0.70), ("uncommon", 0.25), ("rare", 0.05)] {
            let fraction = Double(counts[rarity, default: 0]) / Double(sampleCount)
            #expect(abs(fraction - expected) < 0.02, "\(rarity): \(fraction)")
        }
    }

    @Test func eightNonRareLettersForceTheNinthAndResetPity() {
        // Find an actual run of eight non-rares with pity disabled, then process it normally.
        let seed = (UInt32(0)..<10_000).first { seed in
            (1...9).allSatisfy { ItemDropRules.rarity(seed: seed, letterId: $0, pity: 0) != "rare" }
        }!
        var (journey, care) = engineState(seed: seed)
        for id in 1...8 {
            journey.letters.append(engineLetter(id))
            CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
            #expect(journey.letters.last?.rewards.dropRarity != "rare")
            #expect(care.pity == id)
        }
        journey.letters.append(engineLetter(9, arrivals: []))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.rewards.dropRarity == "rare")
        #expect(care.pity == 0)
    }

    @Test func twoHundredLettersNeverHaveMoreThanEightConsecutiveNonRares() {
        var (journey, care) = engineState(seed: 412)
        var streak = 0
        for id in 1...200 {
            journey.letters.append(engineLetter(id, arrivals: id % 2 == 0 ? [] : ["xian"]))
            CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
            let letter = journey.letters.last!
            streak = letter.rewards.dropRarity == "rare" ? 0 : streak + 1
            #expect(streak <= 8 && care.pity == streak)
            #expect(letter.rewards.itemIds.count == 1)
        }
    }

    @Test func authoredRewardReplacesTheDropOnlyWhenItsRarityMatches() {
        let (_, care) = engineState()
        let seed: UInt32 = 73
        let letter = engineLetter(1)
        let rarity = ItemDropRules.rarity(seed: seed, letterId: letter.id, pity: care.pity)
        let library = dropLibrary([
            engineItem("story.gift", rarity: rarity, city: "xian"),
            engineItem("story.wrong-rarity", rarity: rarity == "rare" ? "common" : "rare"),
            engineItem("shanghai.local", rarity: rarity, city: "shanghai"),
        ])
        var rewards = StoryRewards()
        rewards.itemIds = ["story.wrong-rarity", "story.gift"]
        rewards.menuIds = ["menu.sketch"]
        let result = library.drop(rewards: rewards, letter: letter, care: care, seed: seed)
        #expect(result.itemIds == ["story.gift"] && result.dropRarity == rarity)
        #expect(result.menuIds == rewards.menuIds)
        rewards.itemIds = ["story.wrong-rarity"]
        #expect(library.drop(rewards: rewards, letter: letter, care: care, seed: seed).itemIds == ["shanghai.local"])
    }

    @Test func currentCityWinsEvenWhenOwnedAndTheTransitTargetNeverSuppliesTheDrop() {
        var (_, care) = engineState()
        care.pity = 8
        care.souvenirs = [.init(id: "shanghai.local", letterId: 0, shelved: true)]
        let library = dropLibrary([
            engineItem("shanghai.local", rarity: "rare", city: "shanghai"),
            engineItem("xian.target", rarity: "rare", city: "xian"),
        ])
        let result = library.drop(rewards: .init(), letter: engineLetter(1, arrivals: []), care: care, seed: 9)
        #expect(result.itemIds == ["shanghai.local"] && result.duplicateClueCityId == "shanghai")
    }

    @Test func genericDrawsPreferUnownedThenContinueToDrawFromTheWholePool() {
        var (_, care) = engineState()
        care.pity = 8
        let library = dropLibrary([engineItem("generic.another-rare", rarity: "rare")])
        care.souvenirs = [.init(id: "generic.rare", letterId: 0, shelved: true)]
        for seed in UInt32(0)..<64 {
            let result = library.drop(rewards: .init(), letter: engineLetter(1), care: care, seed: seed)
            #expect(result.itemIds == ["generic.another-rare"] && result.duplicateClueCityId == nil)
        }
        care.souvenirs.append(.init(id: "generic.another-rare", letterId: 0, shelved: false))
        let results = (UInt32(0)..<64).map { library.drop(rewards: .init(), letter: engineLetter(1), care: care, seed: $0) }
        #expect(Set(results.flatMap(\.itemIds)) == ["generic.rare", "generic.another-rare"])
        #expect(results.allSatisfy { $0.duplicateClueCityId == "shanghai" })
    }

    @Test(arguments: [true, false])
    func duplicateCluesUseTheSouvenirCityOrTheLetterCityForGenericItems(local: Bool) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let item = engineItem("test.keepsake", rarity: "rare", city: local ? "xian" : nil)
        try JSONEncoder().encode([item]).write(to: box.directory.appendingPathComponent("items/test.json"))
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        care.pity = 8
        care.souvenirs = [.init(id: item.id, letterId: 0, shelved: true)]
        var story = engineStory("authored")
        story.rewards.itemIds = [item.id]
        journey.letters.append(engineLetter(1))
        let before = care
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story]), catalog: catalog)
        let city = local ? "xian" : "shanghai"
        #expect(journey.letters[1].rewards.itemIds == [item.id])
        #expect(journey.letters[1].rewards.duplicateClueCityId == city)
        #expect(care.trailClues == [city: 1] && care.souvenirs == before.souvenirs)
        #expect(care.pity == 0)
        let expected = care
        care = before
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(care == expected) // Removed content does not change clue attribution during recovery.
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(care == expected)
    }

    @Test func menusAreExtraToExactlyOneSouvenirAndAreGrantedOnlyOnce() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let menu = engineItem("test.menu", kind: "menu", rarity: nil)
        try JSONEncoder().encode([menu]).write(to: box.directory.appendingPathComponent("items/test.json"))
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        var story = engineStory("menu", kind: "transit")
        story.rewards.menuIds = [menu.id]
        for id in 1...2 {
            journey.letters.append(engineLetter(id, arrivals: []))
            CareEngine.process(journey: &journey, care: &care, stories: .init(stories: [story]), catalog: catalog)
            #expect(journey.letters.last?.rewards.itemIds.count == 1)
            #expect(journey.letters.last?.rewards.menuIds == [menu.id])
        }
        #expect(care.menus == [.init(id: menu.id, letterId: 1)])
        #expect(care.souvenirs.count == 2)
        #expect(care.souvenirs.allSatisfy { !$0.shelved })
    }

    @Test func explicitOwnedChoiceWinsAndIsClearedWithoutConsumingTheItem() {
        for item in ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"] {
            var (journey, care) = engineState()
            care.bag.owned.append(contentsOf: ["old-camera", "lunchbox"])
            care.bag.todayItem = item
            let owned = care.bag.owned
            journey.letters.append(engineLetter(1))
            CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
            #expect(journey.letters.last?.carriedItem == item)
            #expect(care.bag.todayItem == nil && care.bag.owned == owned)
        }
    }

    @Test func randomCarryIgnoresUnownedChoicesAndOwnedOrderAndHandlesAnEmptyBag() {
        var seen: Set<String> = []
        for seed in UInt32(0)..<32 {
            var results: [String?] = []
            for mode in 0..<3 {
                var (journey, care) = engineState(seed: seed)
                care.bag.todayItem = mode == 0 ? nil : "old-camera"
                if mode == 2 { care.bag.owned.reverse() }
                journey.letters.append(engineLetter(1))
                CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
                results.append(journey.letters.last?.carriedItem)
                #expect(care.bag.todayItem == nil)
            }
            #expect(results[0] == results[1] && results[0] == results[2])
            seen.insert(results[0]!)
        }
        #expect(seen == ["sketchbook", "note-slip", "raincoat"])
        var (journey, care) = engineState()
        care.bag.owned = []
        care.bag.todayItem = "sketchbook"
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.carriedItem == nil && journey.letters.last?.itemTriggered == false)
        #expect(care.bag.todayItem == nil && journey.letters.last?.rewards.itemIds.count == 1)
    }

    @Test func triggerDecisionIsHalfTheLettersAndIndependentOfRarity() {
        var triggered = 0
        var combinations: Set<String> = []
        for seed in UInt32(0)..<1000 {
            for id in 1...100 {
                let trigger = CareEngine.itemTrigger(seed: seed, letterId: id)
                if trigger { triggered += 1 }
                combinations.insert("\(trigger).\(ItemDropRules.rarity(seed: seed, letterId: id, pity: 0))")
            }
        }
        #expect(abs(Double(triggered) / 100_000 - 0.5) < 0.02)
        #expect(combinations.count == 6)
    }

    @Test(arguments: ["sketchbook", "note-slip", "old-camera", "lunchbox"])
    func itemStoryPrefersTheCurrentCityThenGenericAndBonusesApplyOnTransitToo(item: String) {
        for transit in [false, true] {
            let kind = transit ? "transit" : "arrival"
            var local = engineStory("local-item", kind: kind, city: "shanghai")
            local.requires.item = item
            var generic = local
            generic.id = "generic-item"
            generic.cityId = nil
            var tool = engineStory("tool", kind: kind)
            tool.requires.tool = "codex"
            for hasLocal in [true, false] {
                var (journey, care) = engineState(seed: triggerSeed())
                care.bag.owned = [item]
                care.bag.todayItem = item
                journey.letters.append(engineLetter(1, arrivals: transit ? [] : ["shanghai"]))
                let stories = engineStories([generic, tool] + (hasLocal ? [local] : []))
                CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog)
                #expect(journey.letters.last?.storyId == (hasLocal ? local.id : generic.id))
                #expect(journey.letters.last?.itemTriggered == true)
                #expect(care.habits.talkative + care.habits.observant == 3)
                #expect(care.habits.talkative == (["note-slip", "lunchbox"].contains(item) ? 3 : 0))
                let after = care
                CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog)
                #expect(care == after)
            }
        }
    }

    @Test func itemStoriesCannotEnterToolHabitWishOrFallbackTiersWithoutATrigger() {
        var item = engineStory("item", city: "shanghai")
        item.requires = .init(habit: "talkative", item: "sketchbook", season: "autumn", tool: "codex", rainySeason: false)
        item.tags = ["art"]
        var (journey, care) = engineState(seed: triggerSeed(triggered: false))
        care.habits.talkative = 10
        care.bag.todayItem = "sketchbook"
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories([item]), catalog: testCatalog, wishTags: ["art"])
        #expect(journey.letters.last?.storyId == "generic.arrival")
        #expect(journey.letters.last?.itemTriggered == false && care.habits.talkative == 10 && care.habits.observant == 0)
    }

    @Test func triggerHabitBonusCapsAtOneHundred() {
        for item in ["sketchbook", "note-slip"] {
            var (journey, care) = engineState(seed: triggerSeed())
            care.habits.talkative = 99
            care.habits.observant = 99
            care.bag.todayItem = item
            journey.letters.append(engineLetter(1))
            CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
            #expect(care.habits.talkative == (item == "note-slip" ? 100 : 99))
            #expect(care.habits.observant == (item == "sketchbook" ? 100 : 99))
        }
    }

    @Test func fulfillmentOverridesItemTriggerAndStillDropsOneSouvenir() {
        var (journey, care) = engineState(seed: triggerSeed(letterId: 2))
        care.bag.owned = ["sketchbook"]
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        CareEngine.reply(letterId: 1, replyId: "ask-next-time", date: "later", journey: &journey, care: &care)
        let before = care.habits
        care.pity = 8
        journey.letters.append(engineLetter(2, arrivals: []))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.fulfilledReplyId == "ask-next-time")
        #expect(journey.letters.last?.carriedItem == "sketchbook" && journey.letters.last?.itemTriggered == false)
        #expect(care.habits == before && care.pity == 0)
        #expect(journey.letters.last?.rewards.itemIds.count == 1 && journey.letters.last?.rewards.dropRarity == "rare")
    }

    @Test func raincoatNeedsTheLocalRainySeasonAndNeverChangesHabits() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit { $0["rainyMonths"] = [11] }
        let rainyCatalog = try CityCatalog.load(directory: box.directory)
        let seed = triggerSeed()
        var results: [Letter] = []
        for catalog in [testCatalog, rainyCatalog] {
            var (journey, care) = engineState(seed: seed)
            care.bag.todayItem = "raincoat"
            journey.letters.append(engineLetter(1))
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
            let letter = journey.letters.last!
            let story = catalog.stories.all.first { $0.id == letter.storyId }!
            #expect((story.requires.item == "raincoat") == (catalog.city("shanghai").rainyMonths == [11]))
            #expect(care.habits == .init() && letter.itemTriggered == false)
            results.append(letter)
        }
        #expect(results[0].rewards == results[1].rewards)
    }

    @Test func savedCarryTriggerAndRewardsRepairCareWithoutDrawingAgain() throws {
        var (journey, care) = engineState(seed: triggerSeed())
        care.bag.owned = ["sketchbook"]
        care.bag.todayItem = "sketchbook"
        let before = care
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let expectedJourney = journey
        let expectedCare = care
        care = before
        // A new selection would carry raincoat, but recovery must use the saved sketchbook.
        care.bag.todayItem = "raincoat"
        care.bag.owned = ["raincoat"]
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(journey == expectedJourney)
        #expect(care.habits == expectedCare.habits && care.souvenirs == expectedCare.souvenirs && care.pity == expectedCare.pity)
        #expect(care.bag.todayItem == nil && journey.letters.last?.carriedItem == "sketchbook")
        let recovered = care
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(care == recovered)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
    }

    @Test func savedOldStoriesWithoutDropFieldsNeverReceiveRetroactiveDrops() throws {
        var (journey, care) = engineState()
        var old = engineLetter(1)
        old.storyId = "old.saved.story"
        old.texts = ["en": "Already sent.", "zh-Hans": "已经寄出的信。"]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "carriedItem")
        json.removeValue(forKey: "itemTriggered")
        json["rewards"] = ["itemIds": [], "menuIds": []]
        let decoded = try JSONDecoder().decode(Letter.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.carriedItem == nil && decoded.itemTriggered == nil && decoded.rewards.dropRarity == nil)
        journey.letters.append(decoded)
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(journey.letters.last == decoded)
        #expect(care.pity == 0 && care.souvenirs.isEmpty && care.trailClues.isEmpty && care.menus.isEmpty)
        #expect(care.processedLetterIds == [1])
    }
}
