import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class MemoryBookDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@Suite @MainActor struct MemoryBookDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test func savedReferencesSwitchLanguageAndKeepThePlayersNameVerbatim() throws {
        let name = "小信使 Pip {city}"
        let examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: name)
        let original = try JSONEncoder().encode(examples.care)
        let zh = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now,
                                   l10n: L10n(language: .zhHans), catalog: localizationCatalog)
        let en = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now,
                                   l10n: L10n(language: .en), catalog: localizationCatalog)
        #expect(zh.entries.map(\.id) == en.entries.map(\.id))
        for category in MemoryCategory.allCases { #expect(!en.entries(in: category).isEmpty) }
        for entry in en.entries {
            let chinese = try #require(zh.entries.first { $0.id == entry.id })
            #expect(entry.text != chinese.text)
            #expect(!containsHan(entry.text.replacingOccurrences(of: name, with: "")))
            #expect(entry.cause.map { !containsHan($0) } ?? true)
        }
        #expect(en.entries(in: .special).allSatisfy { $0.text.contains(name) })
        let learned = try #require(en.entries(in: .learned).first)
        #expect(learned.sourceLetterId == 1 && learned.letterId == 2)
        #expect(learned.cause?.contains(examples.journey.letters[1].replyOptions[0].text["en"]!) == true)
        #expect(try JSONDecoder().decode(CareState.self, from: original) == examples.care)
    }

    @Test func chronologicalReplyQueueKeepsRepeatedChoicesAndLateRepliesWithTheirOwnPayoff() throws {
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let reply = try #require(examples.journey.letters[1].selectedReplyId)
        var secondReply = examples.journey.letters[1]
        secondReply.id = 3
        var secondPayoff = examples.journey.letters[2]
        secondPayoff.id = 4
        examples.journey.letters = Array(examples.journey.letters.prefix(3)) + [secondReply, secondPayoff]
        examples.care.memories = [
            .init(kind: "reply", date: "2026-11-08", letterId: 3, replyId: reply),
            .init(kind: "reply", date: "2026-11-09", letterId: 1, replyId: reply),
            .init(kind: "fulfilled", date: "2026-11-10", letterId: 2, replyId: reply),
            .init(kind: "fulfilled", date: "2026-11-11", letterId: 4, replyId: reply),
        ]
        let display = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: .distantFuture,
                                        l10n: L10n(language: .en), catalog: localizationCatalog)
        #expect(display.entries(in: .learned).map(\.sourceLetterId) == [1, 3])
        #expect(display.entries(in: .replies).map(\.letterId) == [1, 3])
        #expect(display.entries(in: .learned).map(\.date) == ["2026-11-11", "2026-11-10"])
    }

    @Test func duplicateLetterIDsFromAnImportedSaveDoNotCrashTheBook() {
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        examples.journey.letters.append(examples.journey.letters[1])
        let display = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now,
                                        l10n: L10n(language: .en), catalog: localizationCatalog)
        #expect(display.entries(in: .replies).first?.letterId == 1)
    }

    @Test func futureLettersAreHiddenAndMissingReferencesKeepALocalizedPlaceholder() throws {
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        examples.journey.letters[2].deliverAt = .distantFuture
        var display = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now,
                                        l10n: L10n(language: .en), catalog: localizationCatalog)
        #expect(display.entries(in: .learned).isEmpty)
        examples.journey.letters.removeAll { $0.id == 1 || $0.id == 2 }
        display = MemoryBookDisplay(journey: examples.journey, care: examples.care, now: now,
                                    l10n: L10n(language: .en), catalog: localizationCatalog)
        #expect(display.entries(in: .replies).first?.letterId == nil)
        #expect(display.entries(in: .replies).first?.text == L10n(language: .en)("memory.unavailable"))
        #expect(display.entries(in: .learned).first?.sourceLetterId == nil)
    }

    @Test func emptyBookHasAllThreeLocalizedExplanations() {
        for language in Language.allCases {
            let l10n = L10n(language: language)
            for category in MemoryCategory.allCases {
                #expect(!category.title(l10n).isEmpty && !category.title(l10n).hasPrefix("memory."))
                #expect(!category.empty(l10n).isEmpty && !category.empty(l10n).hasPrefix("memory."))
            }
        }
    }

    @Test func oldCareLoadsBackfillsPersistsAndMemoryLinksOpenTheirExactLetters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-memory-book-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var examples = Snapshots.memoryExamples(catalog: localizationCatalog, now: now, petName: "原名 Pip")
        examples.care.specialDays = []
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(examples.journey)
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(examples.care)) as? [String: Any])
        oldJSON.removeValue(forKey: "specialDays")
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: directory.appendingPathComponent("care.json"))
        func load() -> AppModel {
            AppModel(defaults: MemoryBookDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                     now: { now }, runtimeEnabled: false)
        }
        let model = load()
        #expect(!model.isLocked)
        var loaded = try #require(model.care)
        #expect(loaded.specialDays.count == 2)
        loaded.specialDays = []
        #expect(loaded == examples.care)
        #expect(model.state == examples.journey)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("care.json"))
        let reloaded = load()
        #expect(reloaded.care == model.care)
        #expect(try Data(contentsOf: directory.appendingPathComponent("care.json")) == bytes)
        let display = MemoryBookDisplay(journey: examples.journey, care: model.care!, now: now,
                                        l10n: L10n(language: .en), catalog: localizationCatalog)
        let learned = try #require(display.entries(in: .learned).first)
        model.navigate(to: .collection)
        model.collectionTab = .memories
        #expect(model.openCollectionLetter(learned.letterId))
        #expect(model.tab == .mail && model.selectedLetterID == 2 && model.mailFilter == .all)
        #expect(model.openCollectionLetter(learned.sourceLetterId))
        #expect(model.selectedLetterID == 1)
    }
}
