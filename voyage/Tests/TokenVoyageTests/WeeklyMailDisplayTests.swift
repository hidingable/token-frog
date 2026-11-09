import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class WeeklyMailDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@Suite @MainActor struct WeeklyMailDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test(arguments: [Language.zhHans, .en])
    func filtersAndNumberingUseTheSameDeliveredMailAndBilingualSnapshots(language: Language) throws {
        let l10n = L10n(language: language)
        let examples = Snapshots.weeklyMailExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        #expect(examples.journey.openDate == DayKey.string(from: now))
        let letters = examples.journey.deliveredLetters(now: now)
        #expect(Set(letters.map(\.kind)) == [.daily, .logbook, .postcard, .reunion, .weekly])
        for letter in letters where [.daily, .postcard, .reunion, .weekly].contains(letter.kind) {
            #expect(letter.texts?[language.rawValue]?.isEmpty == false)
        }
        for filter in MailFilter.allCases {
            let filtered = letters.filter(filter.includes)
            #expect(!filtered.isEmpty)
            switch filter {
            case .all: #expect(filtered == letters)
            case .travel: #expect(filtered.allSatisfy { $0.kind == .daily })
            case .postcards: #expect(filtered.allSatisfy { $0.kind == .postcard })
            case .weekly: #expect(filtered.allSatisfy { $0.kind == .weekly })
            }
            #expect(l10n.mailFilter(filter) != L10n.mailFilterKeys[filter])
            #expect(l10n(L10n.mailEmptyKeys[filter]!) != L10n.mailEmptyKeys[filter])
        }
        let weekly = try #require(letters.first { $0.kind == .weekly })
        #expect(LetterComposer.number(for: weekly, letters: letters) == nil)
        #expect(!MailFilter.postcards.includes(weekly) && !MailFilter.travel.includes(weekly))
        let text = LetterComposer.text(for: weekly, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: letters)
        #expect(text.title == l10n("letter.weeklyTitle") && !text.voice.isEmpty && text.itinerary.isEmpty)
        #expect(text.voice == weekly.texts?[language.rawValue])
        #expect(!text.voice.contains("{distance}") && !text.voice.contains("{event}"))
        #expect(LetterComposer.origin(for: weekly, letters: letters, l10n: l10n, catalog: localizationCatalog) == l10n("collection.companionOrigin", text.title))
        #expect(LetterComposer.citation(for: weekly, letters: letters, l10n: l10n) == l10n("memory.citedCompanion", text.title))
        var next = try #require(letters.first { $0.kind == .daily })
        next.id = (letters.map(\.id).max() ?? 0) + 1
        let withNext = letters + [next]
        #expect(LetterComposer.number(for: next, letters: withNext) == letters.filter { $0.kind == .daily }.count + 1)
        #expect(examples.journey.letters.first { $0.kind == .weekly } == weekly)
        if language == .en { #expect(!containsHan(text.voice)) }
    }

    @Test func appScanPersistsWeeklyMailBeforeDeliveryAndOnlyReadingEarnsCompanionship() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-weekly-display-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.current
        var current = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 8, minute: 59))!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-02", now: .distantPast, catalog: localizationCatalog)
        journey.days["2026-11-04", default: DayRecord()].mainWindowOpened = true
        let care = CareState(petName: "Pip", species: localizationCatalog.pets.defaultID, hatchedAt: "2026-11-02")
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        let model = AppModel(defaults: WeeklyMailDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                             now: { current }, usageReader: { _, _ in [] },
                             enrichmentReader: { _ in Issue.record("Weekly mail must not request enrichment"); return Enrichment() }, runtimeEnabled: false)
        await model.scan()
        let mail = try #require(model.state?.letters.first { $0.kind == .weekly })
        #expect(!model.letters.contains(mail) && model.care?.companionDays.isEmpty == true)
        await model.enrichPlace(letterId: mail.id)
        model.markRead(mail)
        #expect(model.care?.companionDays.isEmpty == true)
        await model.scan()
        #expect(model.state?.letters.filter { $0.kind == .weekly }.count == 1)
        current = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!
        model.tick()
        #expect(model.letters.contains(mail))
        model.mailFilter = .weekly
        #expect(model.filteredLetters == [mail])
        model.openLetter(mail)
        model.openLetter(mail)
        #expect(model.care?.companionDays == ["2026-11-08"])
        #expect(model.care?.weekly.stamps == ["2026-11-08"])
        await model.enrichPlace(letterId: mail.id)
        let reloaded = AppModel(defaults: WeeklyMailDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes, now: { current }, runtimeEnabled: false)
        #expect(reloaded.state == model.state && reloaded.care == model.care)
    }

    @Test func legacyActivationIsSavedEvenWhenTheFirstScanFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-weekly-activation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        examples.journey.weeklyMailEligibleFrom = nil
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(examples.journey)
        try store.save(examples.care)
        let model = AppModel(defaults: WeeklyMailDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes, now: { self.now },
                             usageReader: { _, _ in throw UsageError.missingBinary }, runtimeEnabled: false)
        await model.scan()
        #expect(model.state?.weeklyMailEligibleFrom == "2026-11-15")
        let reloaded = AppModel(defaults: WeeklyMailDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                                now: { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16))! }, runtimeEnabled: false)
        #expect(reloaded.state?.weeklyMailEligibleFrom == "2026-11-15")
        #expect(reloaded.state?.letters.contains { $0.kind == .weekly } == false)
    }
}
