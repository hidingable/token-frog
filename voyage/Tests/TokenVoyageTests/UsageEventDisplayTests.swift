import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class UsageEventDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

private actor UsageEventReader {
    var usage: DayUsage
    init(_ usage: DayUsage) { self.usage = usage }
    func set(_ value: DayUsage) { usage = value }
    func read() -> [DayDetail] {
        [DayDetail(date: usage.date, rows: [.init(client: "codex", model: "test", tokens: .init(input: usage.fuel, cacheRead: usage.observedTokens - usage.fuel))])]
    }
}

@Suite @MainActor struct UsageEventDisplayTests {
    @Test(arguments: [false, true])
    func scanObservesOnlyLiveIncrementsAndReloadDoesNotReplayOfflineUsage(cacheOnly: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-usage-event-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 23, minute: 10))!
        let key = DayKey.string(from: current)
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: key, now: current, catalog: localizationCatalog)
        let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: key)
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        let reader = UsageEventReader(DayUsage(date: key, fuel: cacheOnly ? 0 : 100, observedTokens: 100))
        func model() -> AppModel {
            AppModel(defaults: UsageEventDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                     now: { current }, usageReader: { _, _ in await reader.read() },
                     enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        }
        let first = model()
        await first.scan()
        #expect(first.nightcapNote == nil)
        // Offline work is visible in the new scan, but not a live observation pair.
        await reader.set(DayUsage(date: key, fuel: cacheOnly ? 0 : 500, observedTokens: 500))
        let reloaded = model()
        await reloaded.scan()
        #expect(reloaded.nightcapNote == nil)
        let careBeforeNight = reloaded.care
        current = current.addingTimeInterval(60)
        await reader.set(DayUsage(date: key, fuel: cacheOnly ? 0 : 501, observedTokens: 501))
        await reloaded.scan()
        let note = try #require(reloaded.nightcapNote)
        #expect(reloaded.care == careBeforeNight)
        #expect(reloaded.state?.totalFuel == (cacheOnly ? 0 : 501))
        #expect(reloaded.state?.totalKm == 0.000501)
        #expect(reloaded.todayTokens == 501)
        reloaded.languagePreference = .zhHans
        #expect(reloaded.nightcapText == note.texts["zh-Hans"])
        reloaded.languagePreference = .en
        #expect(reloaded.nightcapText == note.texts["en"])
        let saved = reloaded.state
        await reloaded.scan()
        #expect(reloaded.state == saved)
        #expect(reloaded.state?.letters.count == 1)
        let afterRestart = model()
        #expect(afterRestart.nightcapNote == note)
        current = Calendar.current.date(bySettingHour: 5, minute: 0, second: 0,
            of: Calendar.current.date(byAdding: .day, value: 1, to: current)!)!
        afterRestart.tick()
        #expect(afterRestart.nightcapNote == nil)
    }

    @Test(arguments: [true, false])
    func eventMailSnapshotsSwitchLanguagesAndTicketDatesUseLocalizedFormatting(tea: Bool) throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        let example = Snapshots.usageEventExamples(catalog: localizationCatalog, now: now, petName: "Pip", tea: tea)
        let letter = try #require(example.journey.letters.last)
        #expect(Vehicle.toolName("claude-code") == "Claude")
        let note = try #require(letter.usageEventNotes?.first)
        #expect(letter.usageEventNotes?.count == 1)
        #expect(note.id.hasPrefix(tea ? "tea." : "firstVoyage."))
        for language in Language.allCases {
            let l10n = L10n(language: language)
            let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: example.journey.letters)
            #expect(text.voice.contains(try #require(note.texts[language.rawValue])))
            #expect(!text.voice.contains("{tool}"))
            #expect(!l10n("tickets.empty").contains("0"))
            if let ticket = example.journey.usageEvents?.tickets.first {
                #expect(ticket.toolID == "claude" && Vehicle.toolName(ticket.toolID) == "Claude")
                let date = l10n.day(ticket.date, full: true)
                #expect(date != ticket.date)
                #expect(l10n("tickets.firstVoyage", date).contains(date))
            }
        }
        #expect(example.journey.usageEvents?.tickets.count == (tea ? 0 : 1))
    }

    @Test func nightcapRenderingIsTemporaryForEveryPetAndRoomCache() throws {
        for pet in localizationCatalog.pets.all.map(\.id) {
            let ordinary = Sprites.petPixels(pet, catalog: localizationCatalog.pets)
            let cap = Sprites.petPixels(pet, catalog: localizationCatalog.pets, nightcap: true)
            #expect(ordinary != cap)
            #expect(Sprites.petPixels(pet, catalog: localizationCatalog.pets) == ordinary)
            let room = RoomArt.image(pet: pet, shelf: [], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets)
            let capped = RoomArt.image(pet: pet, shelf: [], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets, nightcap: true)
            #expect(room !== capped)
            #expect(try #require(room.dataProvider?.data) as Data != #require(capped.dataProvider?.data) as Data)
            let restored = RoomArt.image(pet: pet, shelf: [], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets)
            #expect(try #require(room.dataProvider?.data) as Data == #require(restored.dataProvider?.data) as Data)
        }
    }
}
