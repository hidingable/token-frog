import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class FriendDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = ["cityContentEnabled": false, "wishResolveEnabled": false]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor private final class FriendNotifications: LetterNotificationCenter {
    var onResponse: (@MainActor (Int?) -> Void)?
    private(set) var sent: [LetterNotification] = []
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func send(_ notification: LetterNotification) async throws { sent.append(notification) }
}

@Suite @MainActor struct FriendDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test func tabStaysHiddenUntilMeetingAndSnapshotContainsMetAndUnmetFriends() throws {
        #expect(!CollectionTab.visible(care: nil).contains(.friends))
        var example = Snapshots.friendExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        #expect(example.care.metFriends?.count == 3)
        #expect(localizationCatalog.friends.friends.count == 6)
        #expect(CollectionTab.visible(care: example.care) == CollectionTab.allCases)
        #expect(example.care.specialDays.filter { $0.kind == .friendMet }.count == 3)
        #expect(Set(example.care.specialDays.map(\.id)).count == example.care.specialDays.count)
        let before = example
        CareEngine.process(journey: &example.journey, care: &example.care, stories: localizationCatalog.stories, catalog: localizationCatalog)
        #expect(example.journey == before.journey && example.care == before.care)
        example.care.metFriends = []
        #expect(!CollectionTab.visible(care: example.care).contains(.friends))
    }

    @Test(arguments: [Language.zhHans, .en])
    func collectionAndMemoryUseBilingualNamesDatesPlacesNotesAndLetterLinks(language: Language) throws {
        let example = Snapshots.friendExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let l10n = L10n(language: language)
        let memory = MemoryBookDisplay(journey: example.journey, care: example.care, now: now, l10n: l10n, catalog: localizationCatalog)
        let friends = memory.entries.filter { $0.id.hasPrefix("special:friendMet:") }
        #expect(friends.count == 3)
        for met in example.care.metFriends ?? [] {
            let friend = try #require(localizationCatalog.friends.friends.first { $0.id == met.id })
            let display = FriendDisplay(friend: friend, met: met, journey: example.journey, catalog: localizationCatalog, now: now, l10n: l10n)
            #expect(display.name == friend.name[language.rawValue] && display.intro == friend.intro[language.rawValue])
            #expect(display.meeting.contains(l10n.day(met.date, full: true)))
            let place = met.cityId.map { l10n.cityName(localizationCatalog.city($0)) } ?? l10n("friends.onTheRoad")
            #expect(display.meeting.contains(place))
            let note = FriendRules.noteIndex(seed: example.journey.seed, friendId: met.id, date: DayKey.string(from: now), count: friend.notes.count)
            #expect(display.note == friend.notes[note][language.rawValue] && display.letterID == met.letterId)
            let letter = try #require(example.journey.letters.first { $0.id == met.letterId })
            let pending = FriendDisplay(friend: friend, met: met, journey: example.journey, catalog: localizationCatalog,
                                        now: letter.deliverAt.addingTimeInterval(-1), l10n: l10n)
            #expect(pending.letterID == nil)
            let entry = try #require(friends.first { $0.letterId == met.letterId })
            #expect(entry.text == l10n("friends.memoryMet", letter.friendSettlement!.names[language.rawValue]!))
            #expect(entry.location == met.cityId.map { l10n.cityName(localizationCatalog.city($0)) })
            if language == .en { #expect(!containsHan(display.name + display.intro + display.note + entry.text)) }
        }
    }

    @Test(arguments: [Language.zhHans, .en])
    func adventureMailUsesSavedBodyAllFilterAndUnnumberedReferences(language: Language) throws {
        let example = Snapshots.friendExamples(catalog: localizationCatalog, now: now, petName: "Pip {city}")
        let letter = try #require(example.journey.letters.last { $0.kind == .adventure })
        let l10n = L10n(language: language)
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Pip {city}", catalog: localizationCatalog, letters: example.journey.letters)
        #expect(MailFilter.allCases.filter { $0.includes(letter) } == [.all])
        #expect(LetterComposer.number(for: letter, letters: example.journey.letters) == nil)
        #expect(text.title == l10n("friends.letterTitle") && text.voice == letter.texts?[language.rawValue])
        #expect(text.voice.contains("Pip {city}") && text.itinerary.isEmpty)
        #expect(LetterComposer.origin(for: letter, letters: example.journey.letters, l10n: l10n, catalog: localizationCatalog)
                == l10n("collection.companionOrigin", text.title))
        #expect(LetterComposer.citation(for: letter, letters: example.journey.letters, l10n: l10n)
                == l10n("memory.citedCompanion", text.title))
        var daily = letter
        daily.id += 1
        daily.kind = .daily
        daily.friendSettlement = nil
        let numbered = example.journey.letters + [daily]
        #expect(LetterComposer.number(for: daily, letters: numbered) == daily.id - 3)
        if language == .en { #expect(!containsHan(text.title + text.voice)) }
    }

    @Test func readingDaySixWritesOnceWaitsForCustomMorningAndReplaysFromJourneyOnRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-friend-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = now
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -5, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: localizationCatalog)
        journey.openDate = DayKey.string(from: now)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        for offset in 0..<5 { CareEngine.markCompanion(date: calendar.date(byAdding: .day, value: offset, to: start)!, care: &care) }
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        let defaults = FriendDefaults()
        defaults.set("15:30", forKey: "deliveryTime")
        func load() -> AppModel {
            AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes, now: { current },
                     usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
                     enrichmentReader: { _ in Issue.record("Adventure mail must not fetch online enrichment"); return Enrichment() },
                     hubClient: HubClient(baseURL: nil), runtimeEnabled: false)
        }
        let model = load()
        #expect(model.care?.metFriends == nil)
        let ordinary = try #require(model.letters.first)
        model.openLetter(ordinary)
        let letter = try #require(model.state?.letters.first { $0.kind == .adventure })
        let delivery = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15, minute: 30))!
        #expect(letter.deliverAt == delivery && letter.date == DayKey.string(from: now))
        #expect(letter.enrichmentDone && letter.replyOptions.isEmpty && letter.rewards == StoryRewards())
        #expect(model.care?.companionDays.count == 6 && model.care?.settledFriendThresholds == [6])
        #expect(!model.letters.contains(letter) && !model.openCollectionLetter(letter.id))
        model.openLetter(ordinary)
        model.markRead(letter)
        #expect(model.care?.companionDays.count == 6 && model.care?.metFriends?.count == 1)
        // Emulate a crash after journey was saved but before care was written.
        let settled = model.care
        try store.save(care)
        let replay = load()
        #expect(replay.care?.metFriends == settled?.metFriends && replay.care?.settledFriendThresholds == [6])
        #expect(replay.state?.letters.filter { $0.kind == .adventure } == [letter])
        current = delivery
        model.openNotificationLetter(letter.id)
        model.mailFilter = .travel
        #expect(model.openCollectionLetter(letter.id))
        #expect(model.tab == .mail && model.mailFilter == .all && model.selectedLetterID == letter.id)
        model.openLetter(letter)
        model.openLetter(letter)
        #expect(model.care?.companionDays.count == 7 && model.care?.metFriends?.count == 1)
        await model.enrichPlace(letterId: letter.id)
        #expect(load().state == model.state && load().care == model.care)
    }

    @Test(arguments: [false, true])
    func adventureSharesTheDailyNotificationGateWithIdentity(adventureFirst: Bool) async throws {
        var example = Snapshots.friendExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let adventure = try #require(example.journey.letters.last { $0.kind == .adventure })
        var identity = adventure
        identity.id += 1
        identity.kind = .identity
        identity.friendSettlement = nil
        identity.deliverAt = adventure.deliverAt.addingTimeInterval(adventureFirst ? 1800 : -1800)
        example.journey.letters = [adventure, identity]
        let first = min(adventure.deliverAt, identity.deliverAt)
        let last = max(adventure.deliverAt, identity.deliverAt)
        let center = FriendNotifications()
        let defaults = FriendDefaults()
        var service = LetterNotificationService(defaults: defaults, center: center)
        await service.evaluate(state: example.journey, now: first.addingTimeInterval(-1), l10n: L10n(language: .en), petName: "Pip", catalog: localizationCatalog)
        #expect(center.sent.isEmpty)
        await service.evaluate(state: example.journey, now: first, l10n: L10n(language: .en), petName: "Pip", catalog: localizationCatalog)
        #expect(center.sent.map(\.letterID) == [adventureFirst ? adventure.id : identity.id])
        await service.evaluate(state: example.journey, now: last, l10n: L10n(language: .en), petName: "Pip", catalog: localizationCatalog)
        service = LetterNotificationService(defaults: defaults, center: center)
        await service.evaluate(state: example.journey, now: last.addingTimeInterval(3600), l10n: L10n(language: .en), petName: "Pip", catalog: localizationCatalog)
        #expect(center.sent.count == 1)
        if adventureFirst { #expect(center.sent.first?.body == LetterNotificationService.firstSentence(adventure.texts!["en"]!)) }
    }
}
