import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class ItemDefaults: UserDefaults, @unchecked Sendable {
    override func string(forKey defaultName: String) -> String? { defaultName == "language" ? "en" : nil }
    override func object(forKey defaultName: String) -> Any? { string(forKey: defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@MainActor private final class ItemClock {
    var date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
}

@MainActor private struct CollectionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-items-ui-\(UUID().uuidString)")
    let clock = ItemClock()

    init(update: (inout JourneyState, inout CareState) -> Void = { _, _ in }) throws {
        var examples = Snapshots.collectionExamples(catalog: localizationCatalog, now: clock.date, petName: "Ginkgo")
        update(&examples.journey, &examples.care)
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(examples.journey)
        try store.save(examples.care)
    }

    func model() -> AppModel {
        AppModel(defaults: ItemDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes, now: { clock.date },
                 quotaReader: { Issue.record("Item UI must not request quotas"); return [] },
                 usageReader: { _, _ in
                     [DayDetail(date: "2026-11-06", rows: [UsageRow(client: "codex", model: "example", tokens: UsageTotals(input: outboundTokensPerKm))])]
                 }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor struct CollectionTests {
    @Test func passportCountsOnlyStaysAndBecomesRegularAtThree() throws {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: .distantPast, catalog: localizationCatalog)
        let alias = try #require(localizationCatalog.city("xian").wikidata)
        journey.route = ["xian", "quanzhou", alias, "xian", "fukuoka"]
        // An in-transit letter, target and home never create a passport stay.
        journey.targetCityId = "london"
        journey.letters[0].cityId = "london"
        journey.letters[0].arrivals = []
        let before = journey
        let passport = PassportDisplay(journey: journey, catalog: localizationCatalog, now: .distantFuture)
        #expect(passport.cities.map(\.id) == ["fukuoka", "xian", "quanzhou"])
        #expect(passport.cities.map(\.count) == [1, 3, 1])
        #expect(passport.cities.map(\.isRegular) == [false, true, false])
        #expect(passport.cities.filter { $0.countryCode == "CN" }.map(\.id) == ["xian", "quanzhou"])
        for language in Language.allCases {
            let l10n = L10n(language: language)
            #expect(passport.cities[0].summary(l10n: l10n) == (language == .zhHans ? "停留 1 次" : "1 stay"))
            #expect(passport.cities[1].summary(l10n: l10n) == (language == .zhHans ? "停留 3 次 · 熟客" : "3 stays · Regular"))
        }
        #expect(journey == before)
        journey.route = ["xian", "xian"]
        #expect(!PassportDisplay(journey: journey, catalog: localizationCatalog, now: .distantFuture).cities[0].isRegular)
        journey.route = []
        #expect(PassportDisplay(journey: journey, catalog: localizationCatalog, now: .distantFuture).cities.isEmpty)
    }

    @Test func passportLinksEveryStayedCityToItsLatestDeliveredRelatedLetter() throws {
        let fixture = try CollectionFixture { journey, _ in
            journey.route = ["xian", "quanzhou", "fukuoka"]
            var first = journey.letters[0]
            first.id = 90
            first.date = "2026-11-03"
            first.kind = .daily
            first.cityId = "quanzhou"
            first.arrivals = ["xian", "quanzhou"]
            first.deliverAt = .distantPast
            var later = first
            later.id = 91
            later.date = "2026-11-04"
            later.cityId = "xian"
            later.arrivals = ["xian"]
            var future = later
            future.id = 92
            future.date = "2026-11-07"
            future.deliverAt = .distantFuture
            journey.letters = [first, later, future]
        }
        defer { fixture.remove() }
        let model = fixture.model()
        let passport = PassportDisplay(journey: try #require(model.state), catalog: localizationCatalog, now: model.now)
        #expect(passport.cities.first { $0.id == "fukuoka" }?.letterID == nil)
        #expect(passport.cities.first { $0.id == "xian" }?.letterID == 91)
        let quanzhou = try #require(passport.cities.first { $0.id == "quanzhou" })
        #expect(quanzhou.letterID == 90)
        #expect(model.openCollectionLetter(quanzhou.letterID))
        #expect(model.tab == .mail && model.selectedLetterID == 90)
    }

    @Test func todayItemAcceptsOnlyOwnedItemsClearsAndSurvivesReload() throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        #expect(model.setTodayItem("raincoat"))
        #expect(fixture.model().care?.bag.todayItem == "raincoat")
        let before = model.care
        #expect(!model.setTodayItem("old-camera"))
        #expect(!model.setTodayItem("missing-item"))
        #expect(model.care == before)
        #expect(fixture.model().care?.bag.todayItem == "raincoat")
        #expect(model.setTodayItem(nil))
        #expect(model.care?.bag.todayItem == nil)
        #expect(fixture.model().care?.bag.todayItem == nil)
        #expect(model.care?.bag.owned == before?.bag.owned)
    }

    @Test func nextLetterUsesThePersistedSelectionWithoutConsumingTheItem() async throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        #expect(fixture.model().setTodayItem("raincoat"))
        fixture.clock.date = Calendar.current.date(byAdding: .day, value: 1, to: fixture.clock.date)!
        let model = fixture.model()
        let owned = model.care?.bag.owned
        await model.scan()
        let next = try #require(model.state?.letters.first { $0.id == 6 })
        #expect(next.carriedItem == "raincoat")
        #expect(model.care?.bag.owned == owned)
        #expect(model.care?.bag.todayItem == nil)
        #expect(fixture.model().state?.letters.first { $0.id == 6 }?.carriedItem == "raincoat")
        #expect(model.carriedCount("raincoat") == 1)
    }

    @Test func carriedCountCountsLettersWithThatItemOnly() throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        #expect(model.carriedCount("sketchbook") == 5)
        #expect(model.carriedCount("note-slip") == 0)
        #expect(model.carriedCount("old-camera") == 0)
        model.setTodayItem("raincoat")
        #expect(model.carriedCount("raincoat") == 0)
        #expect(model.carriedCount("sketchbook") == 5)
    }

    @Test func shelveAndPutAwayPersistAndRejectUnownedSouvenirs() throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let item = try #require(model.care?.souvenirs.first { !$0.shelved })
        #expect(model.setSouvenirShelved(item.id, shelved: true))
        #expect(fixture.model().care?.souvenirs.first { $0.id == item.id }?.shelved == true)
        #expect(model.setSouvenirShelved(item.id, shelved: false))
        #expect(fixture.model().care?.souvenirs.first { $0.id == item.id }?.shelved == false)
        let before = model.care
        #expect(!model.setSouvenirShelved("missing-item", shelved: true))
        #expect(model.care == before)
    }

    @Test func souvenirOriginOpensItsOwnLetterAndExitsTheRitual() throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let souvenir = try #require(model.care?.souvenirs.last)
        model.activateHomeAction()
        model.mailFilter = .travel
        #expect(model.openCollectionLetter(souvenir.letterId))
        #expect(model.tab == .mail && model.mailFilter == .all)
        #expect(model.selectedLetterID == souvenir.letterId)
        #expect(model.ritualLetterID == nil)
        #expect(!model.openCollectionLetter(999))
    }

    @Test func rarityDuplicateCluesAndLegacyLettersHaveTheExpectedDisplayData() throws {
        let fixture = try CollectionFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        for language in Language.allCases {
            let l10n = L10n(language: language)
            let expectedRarities: [String?] = [nil, l10n("item.rarityUncommon"), l10n("item.rarityRare")]
            for id in 1...3 {
                let letter = try #require(model.state?.letters.first { $0.id == id })
                let brought = try #require(LetterComposer.brought(for: letter, care: model.care, catalog: localizationCatalog, l10n: l10n))
                let item = try #require(brought.items.first)
                #expect(item.rarity == expectedRarities[id - 1])
                #expect(item.name == item.item.names[language.rawValue])
                #expect(item.description == item.item.descriptions[language.rawValue])
                #expect(brought.duplicateMessage == nil && brought.clueProgress == nil)
                let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Ginkgo", catalog: localizationCatalog)
                let carriedItem = language == .zhHans ? "这趟带着：速写本" : "Carried on this trip: Sketchbook"
                #expect(text.itinerary.contains(carriedItem))
            }
            var duplicate = try #require(model.state?.letters.first { $0.id == 5 })
            let brought = try #require(LetterComposer.brought(for: duplicate, care: model.care, catalog: localizationCatalog, l10n: l10n))
            #expect(brought.duplicateMessage == l10n("letter.duplicateItem", brought.items[0].name))
            #expect(brought.clueProgress == l10n("collection.revisitProgress", 2, 3))
            if language == .en {
                #expect(!containsHan(([brought.duplicateMessage!, brought.clueProgress!] + brought.items.flatMap { [$0.name, $0.description, $0.rarity ?? ""] }).joined()))
            }
            // Letter rarity belongs to the saved reward even if the current catalog differs.
            duplicate.rewards.dropRarity = "common"
            let recorded = try #require(LetterComposer.brought(for: duplicate, care: model.care, catalog: localizationCatalog, l10n: l10n))
            #expect(recorded.items.first?.rarity == nil && recorded.items.first?.isRare == false)
            duplicate.rewards.dropRarity = nil
            #expect(LetterComposer.brought(for: duplicate, care: model.care, catalog: localizationCatalog, l10n: l10n) == nil)
        }
    }
}

@Suite @MainActor struct RitualTests {
    @Test func ritualReadsInDateOrderWithoutResponsesAndFinishesAtThePostOffice() throws {
        let fixture = try CollectionFixture { journey, _ in
            journey.letters[1].date = "2026-11-04"
            journey.letters[2].date = "2026-11-01"
            journey.letters[3].date = "2026-11-03"
            journey.letters[4].read = true
            journey.letters[5].deliverAt = .distantFuture
        }
        defer { fixture.remove() }
        let model = fixture.model()
        let before = model.care
        model.setTodayItem(nil)
        model.activateHomeAction()
        #expect(model.ritualLetterID == 2 && model.ritualRemainingCount == 2)
        #expect(model.ritualLetter?.read == true)
        model.advanceRitual()
        #expect(model.ritualLetterID == 3 && model.ritualRemainingCount == 1)
        model.advanceRitual()
        #expect(model.ritualLetterID == 1 && model.ritualRemainingCount == 0)
        model.advanceRitual()
        #expect(model.ritualLetterID == nil && model.tab == .home)
        #expect(model.unread == 0)
        #expect(model.state?.letters.allSatisfy { $0.selectedReplyId == nil } == true)
        #expect(model.care?.bag.todayItem == nil)
        #expect(model.care?.habits == before?.habits && model.care?.pendingPromises == before?.pendingPromises)
        #expect(model.care?.companionDays == ["2026-11-06"])
        let reloaded = fixture.model()
        #expect(reloaded.unread == 0 && reloaded.care?.companionDays == ["2026-11-06"])
        #expect(reloaded.state?.letters.first { $0.id == 5 }?.read == false)
    }

    @Test func collectAllMarksOnlyDeliveredUnreadLettersAndCountsTheDayOnce() throws {
        let fixture = try CollectionFixture { journey, _ in journey.letters[5].deliverAt = .distantFuture }
        defer { fixture.remove() }
        let model = fixture.model()
        model.activateHomeAction()
        #expect(model.ritualRemainingCount == 3)
        model.collectAllRitualLetters()
        #expect(model.unread == 0 && model.tab == .home && model.ritualLetterID == nil)
        #expect(model.care?.companionDays == ["2026-11-06"])
        let reloaded = fixture.model()
        #expect(reloaded.unread == 0 && reloaded.care?.companionDays == ["2026-11-06"])
        #expect(reloaded.state?.letters.first { $0.id == 5 }?.read == false)
    }

    @Test func singleUnreadLetterCanBeSentOffWithNoReplyOrItem() throws {
        let fixture = try CollectionFixture { journey, care in
            for index in journey.letters.indices { journey.letters[index].read = journey.letters[index].id != 3 }
            care.bag.todayItem = nil
        }
        defer { fixture.remove() }
        let model = fixture.model()
        model.activateHomeAction()
        #expect(model.ritualLetterID == 3 && model.ritualRemainingCount == 0)
        model.advanceRitual()
        #expect(model.tab == .home && model.ritualLetterID == nil && model.unread == 0)
        #expect(model.care?.bag.todayItem == nil && model.care?.companionDays.count == 1)
        #expect(model.state?.letters.first { $0.id == 3 }?.selectedReplyId == nil)
    }
}

@Test func catalogItemNamesAndDescriptionsUseTheLanguageFallbackOrder() throws {
    var item = try #require(localizationCatalog.items.find("sketchbook"))
    let en = L10n(language: .en)
    let zh = L10n(language: .zhHans)
    #expect(zh.itemName(item) == "速写本" && en.itemName(item) == "Sketchbook")
    #expect(zh.itemDescription(item) == item.descriptions["zh-Hans"])
    item.names = ["en": "English fallback"]
    item.descriptions = ["en": "English description"]
    #expect(zh.itemName(item) == "English fallback" && zh.itemDescription(item) == "English description")
    item.names = ["zh-Hans": "中文兜底"]
    item.descriptions = ["zh-Hans": "中文说明"]
    #expect(en.itemName(item) == "中文兜底" && en.itemDescription(item) == "中文说明")
    for original in localizationCatalog.items.all {
        #expect(!containsHan(en.itemName(original) + en.itemDescription(original)))
    }
}

@Test func menusAreEmptyByDefaultAndGroupAcquiredDishesByCityWithOrigins() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-menu-content-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var care = CareState(petName: "Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: "2026-11-01")
    #expect(ItemCollection.menuGroups(care: care, catalog: localizationCatalog, letters: []).isEmpty)
    try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content"), to: directory)
    var menus: [Item] = []
    for (id, city) in [("menu.shanghai-a", "shanghai"), ("menu.beijing", "beijing"), ("menu.shanghai-b", "shanghai")] {
        var item = try #require(localizationCatalog.items.find("sketchbook"))
        item.id = id
        item.kind = "menu"
        item.cityId = city
        item.icon = "bowl"
        item.habit = nil
        item.names = ["zh-Hans": "示例菜", "en": "Example dish"]
        item.descriptions = ["zh-Hans": "带回的吃法", "en": "A way to eat, brought home"]
        menus.append(item)
    }
    try JSONEncoder().encode(menus).write(to: directory.appendingPathComponent("items/menu-test.json"))
    let catalog = try CityCatalog.load(directory: directory)
    care.menus = try JSONDecoder().decode([CareState.Menu].self, from: Data(#"[{"id":"menu.shanghai-b","letterId":3},{"id":"menu.beijing","letterId":2},{"id":"menu.shanghai-a","letterId":1}]"#.utf8))
    let groups = ItemCollection.menuGroups(care: care, catalog: catalog, letters: [])
    #expect(groups.map(\.cityId) == ["beijing", "shanghai"])
    #expect(groups[0].entries.map(\.letterId) == [2])
    #expect(groups[1].entries.map(\.id) == ["menu.shanghai-a", "menu.shanghai-b"])
    #expect(groups[1].entries.map(\.letterId) == [1, 3])
    var letter = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: catalog).letters[0]
    letter.rewards.dropRarity = "common"
    letter.rewards.menuIds = ["menu.shanghai-a"]
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let brought = try #require(LetterComposer.brought(for: letter, care: care, catalog: catalog, l10n: l10n))
        #expect(brought.menus.count == 1)
        #expect(brought.menus[0].name == menus[0].names[language.rawValue])
        #expect(brought.menus[0].description == menus[0].descriptions[language.rawValue])
        if language == .en { #expect(!containsHan(l10n("letter.menuCollected", brought.menus[0].name))) }
    }
}
