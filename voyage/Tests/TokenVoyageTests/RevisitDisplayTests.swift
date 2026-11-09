import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class RevisitDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@Suite @MainActor struct RevisitDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test(arguments: [Language.zhHans, .en])
    func collectionShowsCumulativeProgressUnlockedAndToldWithoutZeroOrFalsePromises(language: Language) throws {
        let l10n = L10n(language: language)
        var care = CareState(petName: "Pip", species: localizationCatalog.pets.defaultID, hatchedAt: "2026-11-01")
        let library = localizationCatalog.stories
        #expect(TrailClueDisplay(cityId: "shanghai", care: care, library: library, l10n: l10n) == nil)
        care.trailClues["shanghai"] = 2
        let collecting = try #require(TrailClueDisplay(cityId: "shanghai", care: care, library: library, l10n: l10n))
        #expect(collecting.summary == l10n("collection.revisitProgress", 2, 3) && collecting.status == nil)
        care.trailClues["shanghai"] = 3
        let unlocked = try #require(TrailClueDisplay(cityId: "shanghai", care: care, library: library, l10n: l10n))
        #expect(unlocked.summary == l10n("collection.clueCount", 3))
        #expect(unlocked.status == l10n("collection.revisitUnlocked"))
        let story = try #require(library.all.first { $0.kind == "revisit" && $0.cityId == "shanghai" })
        care.toldRevisitStoryIds = [story.id]
        let told = try #require(TrailClueDisplay(cityId: "shanghai", care: care, library: library, l10n: l10n))
        #expect(told.summary == unlocked.summary && told.status == l10n("collection.revisitTold"))
        care.trailClues["dublin"] = 8
        let unavailable = try #require(TrailClueDisplay(cityId: "dublin", care: care, library: library, l10n: l10n))
        #expect(unavailable.summary == l10n("collection.clueCount", 8) && unavailable.status == nil)
        #expect(!unavailable.summary.contains("/"))
        for value in [collecting.summary, unlocked.status!, told.status!, l10n("letter.revisit")] {
            #expect(!value.hasPrefix("collection.") && !value.hasPrefix("letter."))
            if language == .en { #expect(!containsHan(value)) }
        }
    }

    @Test(arguments: [Language.zhHans, .en])
    func snapshotContainsAnActualRevisitAndAllThreeClueStatesWithTravelNumbering(language: Language) throws {
        let examples = Snapshots.revisitExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let l10n = L10n(language: language)
        let letter = try #require(examples.journey.letters.last)
        #expect(letter.isRevisit == true && letter.kind == .daily)
        #expect(MailFilter.travel.includes(letter) && !MailFilter.postcards.includes(letter))
        #expect(LetterComposer.number(for: letter, letters: examples.journey.letters) == 2)
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: examples.journey.letters)
        #expect(text.voice == letter.texts?[language.rawValue] && text.lead == letter.leadTexts[language.rawValue])
        #expect(examples.care.toldRevisitStoryIds == [letter.storyId!])
        #expect(RevisitStories.progress(in: "shanghai", care: examples.care, library: localizationCatalog.stories) == .collecting(required: 3))
        #expect(RevisitStories.progress(in: "xian", care: examples.care, library: localizationCatalog.stories) == .unlocked)
        #expect(RevisitStories.progress(in: "hangzhou", care: examples.care, library: localizationCatalog.stories) == .told)
        #expect(examples.care.trailClues["hangzhou", default: 0] >= 3)
        #expect(!text.title.contains("2026-11-"))
        #expect(letter.replyOptions.count == 2 && letter.rewards.itemIds.count == 1)
        if language == .en { #expect(!containsHan(text.voice + (text.lead ?? ""))) }
    }

    @Test func appLoadsAndReplaysRevisitSnapshotsWithoutChangingOldMailOrGrantingTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-revisit-display-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let example = Snapshots.revisitExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(example.journey)
        try store.save(example.care)
        func load() -> AppModel {
            AppModel(languageOverride: .en, defaults: RevisitDefaults(), directory: directory,
                     catalog: localizationCatalog, themes: testThemes, now: { now }, runtimeEnabled: false)
        }
        let first = load()
        let second = load()
        #expect(first.state?.letters == example.journey.letters && second.state?.letters == example.journey.letters)
        #expect(first.care?.toldRevisitStoryIds == example.care.toldRevisitStoryIds)
        #expect(second.care?.trailClues == example.care.trailClues && second.care?.souvenirs == example.care.souvenirs)
    }

    @Test(arguments: [false, true])
    func scanPassesRevisitCandidatesToLiveAndCatchUpDraws(finalize: Bool) async throws {
        let catalog = localizationCatalog
        let cities = Set(catalog.all.filter { $0.level == "full" }.map(\.id))
        let seed = try #require((UInt32(0)..<100).first { seed in
            let initial = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-08", catalog: catalog)
            var weighted = initial, ordinary = initial
            weighted.sync(today: DayUsage(date: initial.openDate, fuel: initial.legCost), catalog: catalog, revisitCities: cities)
            ordinary.sync(today: DayUsage(date: initial.openDate, fuel: initial.legCost), catalog: catalog)
            return weighted.targetCityId != ordinary.targetCityId
        })
        let journey = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-11-08", catalog: catalog)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        care.trailClues = Dictionary(cities.map { ($0, 3) }, uniquingKeysWith: { first, _ in first })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-revisit-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SaveStore(directory: directory, pets: catalog.pets, journeyMigrations: .journey(catalog: catalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        let current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: finalize ? 9 : 8, hour: 12))!
        let fuel = journey.legCost
        let model = AppModel(defaults: RevisitDefaults(), directory: directory, catalog: catalog, themes: testThemes,
                             now: { current }, usageReader: { _, _ in
            [DayDetail(date: "2026-11-08", rows: [.init(client: "codex", model: "test", tokens: .init(input: fuel))])]
        }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        #expect(model.state?.targetCityId == journey.targetCityId)
        var expected = journey
        let usage = DayUsage(date: journey.openDate, fuel: fuel, byClient: ["codex": fuel])
        expected.sync(today: finalize ? DayUsage(date: "2026-11-09") : usage, finalized: finalize ? [usage] : [],
                      catalog: catalog, revisitCities: cities)
        await model.scan()
        #expect(model.state?.targetCityId == expected.targetCityId && model.state?.route == expected.route)
    }
}
