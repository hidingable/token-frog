import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class IdentityDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = ["cityContentEnabled": false, "wishResolveEnabled": false]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor private final class IdentityNotifications: LetterNotificationCenter {
    var onResponse: (@MainActor (Int?) -> Void)?
    private(set) var sent: [LetterNotification] = []
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func send(_ notification: LetterNotification) async throws { sent.append(notification) }
}

@Suite @MainActor struct IdentityDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test(arguments: [Language.zhHans, .en])
    func profileUsesBilingualNamesAndQualitativeBasisOnlyFromTheTravelerStage(language: Language) throws {
        let example = Snapshots.identityExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let l10n = L10n(language: language)
        #expect(example.care.companionDays.count == 60 && example.care.identity == "liaison")
        for identity in TravellerIdentity.allCases {
            var care = example.care
            care.identity = identity.rawValue
            let display = try #require(IdentityDisplay(journey: example.journey, care: care, catalog: localizationCatalog, now: now, l10n: l10n))
            #expect(display.name == localizationCatalog.identities.entry(identity).name[language.rawValue])
            #expect(display.basis == l10n("identity.basis.\(identity.rawValue)"))
            #expect(!display.name.isEmpty && !display.basis.isEmpty && !display.basis.hasPrefix("identity."))
            #expect((display.name + display.basis).rangeOfCharacter(from: .decimalDigits) == nil)
            if language == .en { #expect(!containsHan(display.name + display.basis)) }
        }
        var beforeTraveler = example.care
        beforeTraveler.companionDays.removeLast()
        #expect(IdentityDisplay(journey: example.journey, care: beforeTraveler, catalog: localizationCatalog, now: now, l10n: l10n) == nil)
        let letter = try #require(example.journey.letters.first { $0.kind == .identity })
        let pending = try #require(IdentityDisplay(journey: example.journey, care: example.care, catalog: localizationCatalog,
                                                  now: letter.deliverAt.addingTimeInterval(-1), l10n: l10n))
        #expect(pending.letterID == nil)
        #expect(IdentityDisplay(journey: example.journey, care: example.care, catalog: localizationCatalog,
                                now: letter.deliverAt, l10n: l10n)?.letterID == letter.id)
    }

    @Test(arguments: [Language.zhHans, .en])
    func identityMailUsesSavedBodyAndUnnumberedReferencesWithoutTakingATravelNumber(language: Language) throws {
        let example = Snapshots.identityExamples(catalog: localizationCatalog, now: now, petName: "Pip {pet}")
        let letter = try #require(example.journey.letters.first { $0.kind == .identity })
        let l10n = L10n(language: language)
        #expect(letter.deliverAt <= now && letter.identitySettlement?.stage == .traveler)
        #expect(MailFilter.allCases.filter { $0.includes(letter) } == [.all])
        #expect(LetterComposer.number(for: letter, letters: example.journey.letters) == nil)
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Pip {pet}", catalog: localizationCatalog, letters: example.journey.letters)
        #expect(text.title == l10n("identity.letterTitle"))
        #expect(text.voice == letter.texts?[language.rawValue] && !text.voice.isEmpty)
        #expect(text.voice.contains("Pip {pet}") && text.itinerary.isEmpty)
        #expect(LetterComposer.origin(for: letter, letters: example.journey.letters, l10n: l10n, catalog: localizationCatalog)
                == l10n("collection.companionOrigin", text.title))
        #expect(LetterComposer.citation(for: letter, letters: example.journey.letters, l10n: l10n)
                == l10n("memory.citedCompanion", text.title))
        #expect(letter.rewards == StoryRewards() && letter.rewardItems.isEmpty && letter.replyOptions.isEmpty)
        var daily = try #require(Snapshots.mailExamples(catalog: localizationCatalog, now: now, petName: "Pip").letters.first { $0.kind == .daily })
        daily.id = letter.id + 1
        let withIdentity = example.journey.letters + [daily]
        #expect(LetterComposer.number(for: daily, letters: withIdentity) == letter.id - 1)
        var withoutIdentity = daily
        withoutIdentity.id -= 1
        #expect(LetterComposer.number(for: daily, letters: withIdentity)
                == LetterComposer.number(for: withoutIdentity, letters: example.journey.letters.filter { $0.kind != .identity } + [withoutIdentity]))
        if language == .en { #expect(!containsHan(text.title + text.voice)) }
    }

    @Test func readingTheSixtiethDaySettlesImmediatelyAndIdentityMailWaitsForCustomDeliveryWithoutOtherCareEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-identity-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.current
        var current = now
        let start = calendar.date(byAdding: .day, value: -59, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: localizationCatalog)
        journey.openDate = DayKey.string(from: now)
        journey.letters[0].read = false
        for language in Language.allCases {
            journey.letters[0].place[language.rawValue] = .init(title: "Saved place", summary: "Saved introduction", url: nil)
        }
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        for offset in 0..<59 {
            CareEngine.markCompanion(date: calendar.date(byAdding: .day, value: offset, to: start)!, care: &care)
        }
        care.habits.talkative = 80
        care.habits.observant = 20
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        let defaults = IdentityDefaults()
        defaults.set("15:30", forKey: "deliveryTime")
        let model = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                             now: { current }, usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
                             enrichmentReader: { _ in Issue.record("Identity mail must not request online enrichment"); return Enrichment() },
                             hubClient: HubClient(baseURL: nil), runtimeEnabled: false)
        #expect(model.care?.companionDays.count == 59 && model.care?.identity == nil)
        #expect(model.state?.letters.contains { $0.kind == .identity } == false)
        let ordinary = try #require(model.letters.first)
        model.openLetter(ordinary)
        let identity = try #require(model.state?.letters.first { $0.kind == .identity })
        let delivery = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15, minute: 30))!
        #expect(model.care?.companionDays.count == 60 && model.care?.identity == "liaison")
        #expect(identity.date == "2026-11-09" && identity.deliverAt == delivery && identity.enrichmentDone)
        #expect(identity.identitySettlement?.stage == .traveler && identity.identitySettlement?.identity == .liaison)
        #expect(!model.letters.contains(identity) && !model.openCollectionLetter(identity.id))
        model.openLetter(ordinary)
        model.markRead(identity)
        #expect(model.care?.companionDays.count == 60 && model.state?.letters.filter { $0.kind == .identity }.count == 1)
        current = delivery.addingTimeInterval(-1)
        model.openNotificationLetter(identity.id)
        #expect(model.selectedLetterID == nil)
        current = delivery
        model.openNotificationLetter(identity.id)
        #expect(model.selectedLetterID == identity.id && model.letters.contains(identity))
        model.mailFilter = .travel
        #expect(model.openCollectionLetter(identity.id))
        #expect(model.tab == .mail && model.mailFilter == .all && model.selectedLetterID == identity.id)
        var expected = try #require(model.care)
        CareEngine.markCompanion(date: current, care: &expected)
        model.openLetter(identity)
        model.openLetter(identity)
        #expect(model.care == expected && model.care?.companionDays.count == 61)
        #expect(model.state?.letters.first { $0.id == identity.id }?.read == true)
        await model.enrichPlace(letterId: identity.id)
        await model.enrichLatest()
        let reloaded = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                                now: { current }, hubClient: HubClient(baseURL: nil), runtimeEnabled: false)
        #expect(reloaded.state == model.state && reloaded.care == model.care)
    }

    @Test func restartingWithOldCareRestoresTheSavedDecisionWithoutRerollingOrGrantingRewards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-identity-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let example = Snapshots.identityExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let letter = try #require(example.journey.letters.first { $0.kind == .identity })
        var oldCare = example.care
        oldCare.identity = nil
        oldCare.settledIdentityStages = nil
        oldCare.habits.talkative = 0
        oldCare.habits.observant = 100
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(example.journey)
        try store.save(oldCare)
        func load() -> AppModel {
            AppModel(defaults: IdentityDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                     now: { now }, hubClient: HubClient(baseURL: nil), runtimeEnabled: false)
        }
        let first = load()
        #expect(first.care?.identity == "liaison" && first.care?.settledIdentityStages == [.traveler])
        #expect(first.care?.habits == oldCare.habits && first.care?.bag == oldCare.bag)
        #expect(first.care?.souvenirs == oldCare.souvenirs && first.care?.menus == oldCare.menus)
        #expect(first.state?.letters.filter { $0.kind == .identity } == [letter])
        let second = load()
        #expect(second.state == first.state && second.care == first.care)
    }

    @Test(arguments: [false, true])
    func identityAndTravelMailShareTheOncePerDayNotificationGate(identityFirst: Bool) async throws {
        var example = Snapshots.identityExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let identity = try #require(example.journey.letters.first { $0.kind == .identity })
        var daily = identity
        daily.id += 1
        daily.kind = .daily
        daily.identitySettlement = nil
        daily.deliverAt = identity.deliverAt.addingTimeInterval(identityFirst ? 1800 : -1800)
        example.journey.letters = [identity, daily]
        let firstDelivery = min(identity.deliverAt, daily.deliverAt)
        let lastDelivery = max(identity.deliverAt, daily.deliverAt)
        let center = IdentityNotifications()
        let defaults = IdentityDefaults()
        var service = LetterNotificationService(defaults: defaults, center: center)
        func evaluate(_ time: Date) async {
            await service.evaluate(state: example.journey, now: time, l10n: L10n(language: .en), petName: "Pip", catalog: localizationCatalog)
        }
        await evaluate(firstDelivery.addingTimeInterval(-1))
        #expect(center.sent.isEmpty)
        await evaluate(firstDelivery)
        #expect(center.sent.map(\.letterID) == [identityFirst ? identity.id : daily.id])
        await evaluate(lastDelivery)
        service = LetterNotificationService(defaults: defaults, center: center)
        await evaluate(lastDelivery.addingTimeInterval(3600))
        #expect(center.sent.count == 1 && defaults.string(forKey: "notificationLastSentDate") == "2026-11-09")
        if identityFirst {
            #expect(center.sent.first?.body == LetterNotificationService.firstSentence(identity.texts!["en"]!))
        }
    }
}
