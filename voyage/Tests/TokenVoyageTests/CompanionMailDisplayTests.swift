import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class CompanionDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@Suite @MainActor struct CompanionMailDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test func failedScansRetrySettlementWithoutDuplicatesAndOnlyReadingCountsAsCompanionship() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-m2-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        examples.journey.lastOpenedDate = "2026-11-06"
        for index in examples.journey.letters.indices { examples.journey.letters[index].read = true }
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(examples.journey)
        try store.save(examples.care)
        var current = now
        func model(fail: Bool = false) -> AppModel {
            AppModel(defaults: CompanionDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                     now: { current }, usageReader: { _, _ in if fail { throw UsageError.missingBinary }; return [] },
                     enrichmentReader: { _ in Issue.record("Companion mail must not request enrichment"); return Enrichment() }, runtimeEnabled: false)
        }
        let first = model(fail: true)
        first.navigate(to: .data) // Every main-window page records the open.
        first.setMainWindowPresented(true)
        await first.scan()
        #expect(first.letters.first?.kind == .reunion && first.unread == 1)
        #expect(first.state?.openDate == "2026-11-09" && first.care?.companionDays.isEmpty == true)
        let second = model()
        second.setMainWindowPresented(true)
        await second.scan()
        #expect(second.state?.days["2026-11-09"]?.mainWindowOpened == true)
        #expect(second.state?.letters.filter { $0.kind == .postcard }.isEmpty == true)
        #expect(second.care?.companionDays.isEmpty == true)
        current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8, minute: 59))!
        let failed = model(fail: true)
        await failed.scan()
        #expect(failed.state?.openDate == "2026-11-09")
        #expect(failed.state?.letters.filter { $0.kind == .postcard }.isEmpty == true)
        let retry = model()
        await retry.scan()
        let postcard = try #require(retry.state?.letters.first { $0.kind == .postcard })
        #expect(retry.state?.letters.filter { $0.kind == .weekly }.map(\.date) == ["2026-11-08"])
        #expect(postcard.date == "2026-11-09" && !retry.letters.contains(postcard))
        retry.markRead(postcard)
        #expect(retry.care?.companionDays.isEmpty == true)
        let saved = (retry.state, retry.care)
        await retry.scan()
        #expect(retry.state == saved.0 && retry.care == saved.1)
        current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        await retry.scan()
        #expect(retry.letters.contains(postcard) && retry.unread == 3)
        retry.mailFilter = .travel
        #expect(retry.filteredLetters.allSatisfy { $0.kind == .daily })
        retry.openCollectionLetter(postcard.id)
        #expect(retry.tab == .mail && retry.mailFilter == .all && retry.selectedLetterID == postcard.id)
        retry.openLetter(postcard)
        retry.openLetter(postcard)
        #expect(retry.unread == 2 && retry.care?.companionDays == ["2026-11-10"])
        #expect(retry.state?.letters.filter { $0.kind == .postcard }.count == 1)
        #expect(retry.state?.letters.filter { $0.kind == .reunion }.count == 1)
        let reloaded = model()
        #expect(reloaded.state == retry.state && reloaded.care == retry.care)
    }

    @Test(arguments: [Language.zhHans, .en])
    func everyNumberedSurfaceSkipsCompanionMailAndLegacyNumbersStayUnchanged(language: Language) throws {
        let l10n = L10n(language: language)
        let examples = Snapshots.companionMailExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let journey = examples.journey
        let daily = try #require(journey.letters.last { $0.kind == .daily })
        #expect(daily.id == 5)
        #expect(LetterComposer.number(for: daily, letters: journey.letters) == 4)
        let city = l10n.cityName(localizationCatalog.city(daily.cityId))
        let target = l10n.cityName(localizationCatalog.city(try #require(daily.transitTargetId)))
        let text = LetterComposer.text(for: daily, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: journey.letters)
        #expect(text.title == l10n("letter.transitTitle", 4, target))
        var arrival = daily
        arrival.transitTargetId = nil
        #expect(LetterComposer.text(for: arrival, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: journey.letters).title == l10n("letter.dailyTitle", 4, city))
        #expect(LetterComposer.origin(for: daily, letters: journey.letters, l10n: l10n, catalog: localizationCatalog) == l10n("collection.origin", 4, city))
        #expect(LetterComposer.citation(for: daily, letters: journey.letters, l10n: l10n) == l10n("memory.citedLetter", 4))
        var afterReunion = daily
        afterReunion.id = 7
        let interleaved = journey.letters + [afterReunion]
        #expect(LetterComposer.number(for: afterReunion, letters: interleaved) == 5)
        #expect(LetterComposer.text(for: afterReunion, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: interleaved).title == l10n("letter.transitTitle", 5, target))
        #expect(LetterComposer.origin(for: afterReunion, letters: interleaved, l10n: l10n, catalog: localizationCatalog) == l10n("collection.origin", 5, city))
        #expect(LetterComposer.citation(for: afterReunion, letters: interleaved, l10n: l10n) == l10n("memory.citedLetter", 5))
        for letter in journey.letters where [.postcard, .reunion].contains(letter.kind) {
            #expect(LetterComposer.number(for: letter, letters: journey.letters) == nil)
            let title = l10n(letter.kind == .postcard ? "letter.postcardTitle" : "letter.reunionTitle")
            #expect(LetterComposer.origin(for: letter, letters: journey.letters, l10n: l10n, catalog: localizationCatalog) == l10n("collection.companionOrigin", title))
            #expect(LetterComposer.citation(for: letter, letters: journey.letters, l10n: l10n) == l10n("memory.citedCompanion", title))
        }
        let legacy = Snapshots.mailExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        for letter in legacy.letters {
            #expect(LetterComposer.number(for: letter, letters: legacy.letters) == letter.id)
            #expect(LetterComposer.text(for: letter, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: legacy.letters)
                    == LetterComposer.text(for: letter, l10n: l10n, petName: "Pip", catalog: localizationCatalog))
        }
        #expect(journey == examples.journey)
    }

    @Test(arguments: [Language.zhHans, .en])
    func snapshotsReadInAllAndLinkBothWaysToMemoryWithSavedItemText(language: Language) throws {
        var examples = Snapshots.companionMailExamples(catalog: localizationCatalog, now: now, petName: "Pip {pet}")
        let l10n = L10n(language: language)
        // Imported duplicate IDs must not trap the reference lookup.
        examples.journey.letters.append(examples.journey.letters[1])
        let display = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now, l10n: l10n, catalog: localizationCatalog)
        let mail = examples.journey.letters.filter { [.postcard, .reunion].contains($0.kind) }
        #expect(mail.count == 2)
        for var letter in mail {
            let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Pip {pet}", catalog: localizationCatalog)
            #expect(!text.voice.isEmpty && text.lead?.isEmpty == false && text.itinerary.isEmpty)
            #expect(!text.title.hasPrefix("letter."))
            #expect(MailFilter.all.includes(letter) && !MailFilter.travel.includes(letter))
            let reference = try #require(letter.memoryReference)
            #expect(display.entries.contains { $0.letterId == reference.letterId && $0.citedLetterIds.contains(letter.id) })
            let original = LetterComposer.brought(for: letter, care: examples.care, catalog: localizationCatalog, l10n: l10n)
            #expect(original?.items.count == 1)
            letter.rewardItems[0].names[language.rawValue] = "Saved item snapshot"
            #expect(LetterComposer.brought(for: letter, care: examples.care, catalog: localizationCatalog, l10n: l10n)?.items[0].name == "Saved item snapshot")
        }
    }
}
