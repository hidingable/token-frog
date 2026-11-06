import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class CollectionSnapshotDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { defaultName == "language" ? "en" : nil }
    override func string(forKey defaultName: String) -> String? { defaultName == "language" ? "en" : nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@Suite @MainActor struct CollectionSnapshotTests {
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    }

    @Test func collectionExamplesIncludeSelectedBagItemAcquisitionsAndDuplicateClues() throws {
        let examples = Snapshots.collectionExamples(catalog: localizationCatalog, now: now, petName: "Ginkgo")
        #expect(examples.care.bag.todayItem == "sketchbook")
        #expect(examples.care.bag.owned.contains("sketchbook"))
        #expect(examples.journey.letters.filter { $0.carriedItem == "sketchbook" }.count == 5)
        #expect(examples.care.souvenirs.count == 3)
        #expect(examples.care.menus.isEmpty)
        #expect(examples.care.trailClues == ["shanghai": 2])
        #expect(examples.care.processedLetterIds == [1, 2, 3, 4, 5])
        for souvenir in examples.care.souvenirs {
            let letter = try #require(examples.journey.letters.first { $0.id == souvenir.letterId })
            #expect(letter.rewards.itemIds.contains(souvenir.id))
            #expect(letter.rewards.duplicateClueCityId == nil)
            #expect(localizationCatalog.items.find(souvenir.id)?.kind == "souvenir")
        }
        let rareLetter = try #require(examples.journey.letters.first { $0.id == 3 })
        let duplicateLetter = try #require(examples.journey.letters.first { $0.id == 5 })
        #expect(rareLetter.rewards.dropRarity == "rare")
        #expect(rareLetter.rewards.duplicateClueCityId == nil)
        #expect(duplicateLetter.rewards.dropRarity == "rare")
        #expect(duplicateLetter.rewards.itemIds == rareLetter.rewards.itemIds)
        #expect(duplicateLetter.rewards.duplicateClueCityId == "shanghai")
        #expect(examples.care.souvenirs.first { $0.id == rareLetter.rewards.itemIds.first }?.shelved == true)
        #expect(examples.journey.letters.allSatisfy { $0.deliverAt <= now && $0.enrichmentDone })
    }

    @Test func collectionExamplesReplayWithoutGrantingAnythingTwice() {
        let examples = Snapshots.collectionExamples(catalog: localizationCatalog, now: now, petName: "Ginkgo")
        var journey = examples.journey
        var care = examples.care
        CareEngine.process(journey: &journey, care: &care, stories: localizationCatalog.stories, catalog: localizationCatalog)
        #expect(journey == examples.journey)
        #expect(care == examples.care)
    }

    @Test func snapshotRitualOverridesRestoreStateAndCareWithoutSavingOrFetching() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-collection-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let examples = Snapshots.collectionExamples(catalog: localizationCatalog, now: now, petName: "Ginkgo")
        var savedJourney = examples.journey
        for index in savedJourney.letters.indices { savedJourney.letters[index].read = true }
        do {
            let store = SaveStore(directory: directory, journeyMigrations: .journey(catalog: localizationCatalog))
            store.load()
            try store.save(savedJourney)
            try store.save(examples.care)
        }
        let journeyURL = directory.appendingPathComponent("journey.json")
        let careURL = directory.appendingPathComponent("care.json")
        let savedJourneyData = try Data(contentsOf: journeyURL)
        let savedCareData = try Data(contentsOf: careURL)
        let model = AppModel(isSnapshot: true, defaults: CollectionSnapshotDefaults(), directory: directory, catalog: localizationCatalog,
                             now: { now }, quotaReader: { Issue.record("Snapshot must not request quotas"); return [] },
                             usageReader: { _, _ in Issue.record("Snapshot must not read usage"); return [] },
                             enrichmentReader: { _ in Issue.record("Snapshot must not request enrichment"); return Enrichment() },
                             runtimeEnabled: false)
        let originalJourney = model.state
        let originalCare = model.care
        model.withSnapshotState({ state in
            state = examples.journey
            for index in state.letters.indices { state.letters[index].read = state.letters[index].id != 3 }
        }) {
            model.withSnapshotCare({ $0 = examples.care }) {
                model.activateHomeAction()
                #expect(model.ritualLetterID == 3)
                #expect(model.unread == 0)
                #expect(model.care?.companionDays.count == 1)
                model.advanceRitual()
                #expect(model.ritualLetterID == nil)
                #expect(model.tab == .home)
            }
        }
        #expect(model.state == originalJourney)
        #expect(model.care == originalCare)
        #expect(try Data(contentsOf: journeyURL) == savedJourneyData)
        #expect(try Data(contentsOf: careURL) == savedCareData)
    }
}
