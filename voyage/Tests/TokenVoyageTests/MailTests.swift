import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@MainActor
private final class MailClock {
    var date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    func advance() { date = Calendar.current.date(byAdding: .day, value: 1, to: date)! }
}

private actor MailUsageProbe {
    var days: [DayDetail] = []
    private(set) var scans = 0
    private(set) var quotas = 0
    func set(_ days: [DayDetail]) { self.days = days }
    func read(since: String?, until: String) -> [DayDetail] { scans += 1; return days }
    func readQuotas() -> [ProviderQuota] { quotas += 1; return [] }
}

private actor MailEnrichmentProbe {
    private(set) var queries: [Enricher.Query] = []
    let succeeds: Bool
    let delay: Bool
    init(succeeds: Bool = false, delay: Bool = false) { self.succeeds = succeeds; self.delay = delay }
    func fetch(_ query: Enricher.Query) async -> Enrichment {
        queries.append(query)
        if delay { try? await Task.sleep(for: .milliseconds(20)) }
        guard succeeds else { return Enrichment() }
        let title = query.city.wikipedia[query.language.rawValue] ?? "Example"
        let place = Letter.Place(title: title, summary: "Example summary", url: "https://en.wikipedia.org/wiki/Example")
        return Enrichment(weatherCode: query.includeWeather ? 61 : nil, temperatureC: query.includeWeather ? 14 : nil,
                          place: query.includePlace ? [query.language.rawValue: place] : [:])
    }
}

private final class MailDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = ["language": "en"]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
private struct MailFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-mail-\(UUID().uuidString)")
    let clock = MailClock()
    let usage = MailUsageProbe()
    let enrichment: MailEnrichmentProbe
    var journeyURL: URL { directory.appendingPathComponent("journey.json") }
    var careURL: URL { directory.appendingPathComponent("care.json") }

    init(days: Int = 0, enrichment: MailEnrichmentProbe = MailEnrichmentProbe(),
         update: (inout JourneyState, inout CareState) -> Void = { _, _ in }) throws {
        self.enrichment = enrichment
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: .distantPast, catalog: localizationCatalog)
        var care = CareState(petName: "Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: journey.startDate)
        for _ in 0..<days { Self.settle(&journey) }
        update(&journey, &care)
        try write(journey, care)
    }

    static func settle(_ journey: inout JourneyState) {
        let day = journey.openDate
        journey.sync(today: DayUsage(date: DayKey.next(day)), finalized: [
            DayUsage(date: day, fuel: 13_400_000, byClient: ["codex": 8_300_000, "claude": 5_100_000]),
        ], now: DayKey.date(from: DayKey.next(day))!.addingTimeInterval(12 * 3600), catalog: localizationCatalog)
    }

    func write(_ journey: JourneyState, _ care: CareState) throws {
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
    }

    func model(isSnapshot: Bool = false) -> AppModel {
        AppModel(isSnapshot: isSnapshot, defaults: MailDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { clock.date }, quotaReader: { await usage.readQuotas() },
                 usageReader: { since, until in await usage.read(since: since, until: until) },
                 enrichmentReader: { await enrichment.fetch($0) }, runtimeEnabled: false)
    }

    func disk() throws -> (JourneyState, CareState) {
        (try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: journeyURL)),
         try JSONDecoder().decode(CareState.self, from: Data(contentsOf: careURL)))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func mailUsage(_ day: String) -> DayDetail {
    DayDetail(date: day, rows: [UsageRow(client: "codex", model: "example", tokens: UsageTotals(input: 13_400_000))])
}

@Suite @MainActor struct MailTests {
    @Test func scanComposesNewMailAndReplayingTheBatchIsIdempotent() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        await fixture.usage.set([mailUsage("2026-11-01")])
        let model = fixture.model()
        await model.scan()
        let letter = try #require(model.letters.first { $0.kind == .daily })
        #expect(letter.storyId != nil && letter.texts?.isEmpty == false)
        #expect(letter.replyOptions.count == 2)
        let care = model.care
        await model.scan()
        #expect(model.state?.letters.filter { $0.kind == .daily } == [letter])
        #expect(model.care == care)
        #expect(model.care?.processedLetterIds == [letter.id])
        #expect(await fixture.usage.scans == 2)
        #expect(await fixture.usage.quotas == 0)
        let saved = try fixture.disk()
        #expect(saved.0.letters.contains(letter) && saved.1 == model.care)
    }

    @Test func startupRepairsTheCareHalfWithoutRecomposingSavedMail() throws {
        let fixture = try MailFixture(days: 1) { journey, care in
            let before = care
            CareEngine.process(journey: &journey, care: &care, stories: localizationCatalog.stories, catalog: localizationCatalog)
            journey.letters[1].texts?["en"] = "The saved edition stays exactly as written."
            care = before
        }
        defer { fixture.remove() }
        let before = try fixture.disk().0
        let model = fixture.model()
        #expect(model.state == before)
        #expect(model.care?.processedLetterIds == [1])
        #expect(try fixture.disk().0 == before)
        #expect(try fixture.disk().1 == model.care)
        #expect(model.lastScan == nil)
    }

    @Test func startupAlsoComposesMailInterruptedBeforeTheJourneyWrite() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        #expect(model.state?.letters[1].texts?.isEmpty == false)
        #expect(model.care?.processedLetterIds == [1])
        #expect(try fixture.disk().0 == model.state)
    }

    @Test func replyPersistsBothFilesAndRejectsASecondResponse() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        let letter = try #require(model.letters.first { $0.id == 1 })
        let option = try #require(letter.replyOptions.first { $0.habit == "talkative" })
        #expect(model.reply(to: letter.id, option: option.id))
        #expect(!model.reply(to: letter.id, option: letter.replyOptions[1].id))
        let reloaded = fixture.model()
        #expect(reloaded.state?.letters[1].selectedReplyId == option.id)
        #expect(reloaded.care?.habits.talkative == 10)
        #expect(reloaded.care?.habits.observant == 0)
        #expect(reloaded.care?.pendingPromises.first?.replyId == option.id)
        let memory = try #require(reloaded.care?.memories.first)
        #expect(memory.kind == "reply" && memory.replyId == option.id && memory.date == "2026-11-02")
        #expect(model.followUp(for: try #require(model.state?.letters[1])) == nil)
        #expect(reloaded.state == model.state && reloaded.care == model.care)
    }

    @Test func keepingAReplyForLaterOnlyCollapsesTheCurrentPresentation() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        let letter = try #require(model.letters.first { $0.id == 1 })
        model.openLetter(letter)
        let journeyData = try Data(contentsOf: fixture.journeyURL)
        let careData = try Data(contentsOf: fixture.careURL)
        let care = model.care
        model.deferReply(to: letter.id)
        #expect(model.deferredReplyLetterID == letter.id)
        #expect(model.care == care && model.state?.letters[1].selectedReplyId == nil)
        #expect(try Data(contentsOf: fixture.journeyURL) == journeyData)
        #expect(try Data(contentsOf: fixture.careURL) == careData)
        model.openLetter(letter)
        #expect(model.deferredReplyLetterID == nil)
        #expect(model.state?.letters[1].replyOptions == letter.replyOptions)
        #expect(try Data(contentsOf: fixture.journeyURL) == journeyData)
        #expect(try Data(contentsOf: fixture.careURL) == careData)
    }

    @Test func undeliveredMailCannotBeRepliedTo() throws {
        let fixture = try MailFixture(days: 1) { journey, _ in journey.letters[1].deliverAt = .distantFuture }
        defer { fixture.remove() }
        let model = fixture.model()
        let letter = try #require(model.state?.letters[1])
        let before = model.care
        #expect(!model.reply(to: letter.id, option: letter.replyOptions[0].id))
        #expect(model.care == before && model.state?.letters[1].selectedReplyId == nil)
        #expect(try fixture.disk().1 == before)
    }

    @Test func threeLettersShowTheQuotedReplyAndLinkBackToItsPayoff() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        await fixture.usage.set([mailUsage("2026-11-01")])
        await model.scan()
        let first = try #require(model.letters.first { $0.id == 1 })
        let option = first.replyOptions[0]
        #expect(model.reply(to: first.id, option: option.id))
        fixture.clock.advance()
        await fixture.usage.set([mailUsage("2026-11-02")])
        await model.scan()
        let second = try #require(model.letters.first { $0.id == 2 })
        #expect(second.fulfilledReplyId == option.id)
        for language in Language.allCases {
            #expect(second.leadTexts[language.rawValue]?.contains(try #require(option.text[language.rawValue])) == true)
        }
        fixture.clock.advance()
        await fixture.usage.set([mailUsage("2026-11-03")])
        await model.scan()
        let replied = try #require(model.state?.letters.first { $0.id == first.id })
        #expect(model.followUp(for: replied)?.id == second.id)
        model.mailFilter = .travel
        model.openFollowUp(second)
        #expect(model.selectedLetterID == 2 && model.mailFilter == .all && model.tab == .mail)
        #expect(model.care?.memories.map(\.kind) == ["reply", "fulfilled"])
        #expect(fixture.model().care == model.care)
        #expect(await fixture.usage.quotas == 0)
    }

    @Test func switchingLanguagesRendersTheSameStoryRepliesAndLegacyMailAgain() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        let story = try #require(model.letters.first { $0.id == 1 })
        var legacy = story
        legacy.texts = nil
        legacy.leadTexts = [:]
        let original = model.state
        model.selectedLetterID = story.id
        model.languagePreference = .zhHans
        let chinese = LetterComposer.text(for: story, l10n: model.l10n, petName: model.petName, catalog: localizationCatalog)
        let chineseLegacy = LetterComposer.text(for: legacy, l10n: model.l10n, petName: model.petName, catalog: localizationCatalog)
        let chineseReplies = story.replyOptions.map { LetterComposer.localized($0.text, l10n: model.l10n) }
        model.languagePreference = .en
        let english = LetterComposer.text(for: story, l10n: model.l10n, petName: model.petName, catalog: localizationCatalog)
        let englishLegacy = LetterComposer.text(for: legacy, l10n: model.l10n, petName: model.petName, catalog: localizationCatalog)
        let englishReplies = story.replyOptions.map { LetterComposer.localized($0.text, l10n: model.l10n) }
        #expect(chinese.voice != english.voice && chinese.title != english.title)
        #expect(chineseLegacy.voice != englishLegacy.voice && chineseLegacy.title != englishLegacy.title)
        #expect(chineseReplies != englishReplies)
        #expect(english.voice == story.texts?["en"])
        #expect(!containsHan(([english.title, english.voice, english.signature, englishLegacy.voice] + english.itinerary + englishReplies.compactMap { $0 }).joined()))
        #expect(model.selectedLetterID == story.id && model.state == original)
    }

    @Test func contentFallbackOrderAndPetNamesArePreserved() {
        let en = L10n(language: .en)
        let zh = L10n(language: .zhHans)
        #expect(LetterComposer.localized(nil, l10n: zh) == nil)
        #expect(LetterComposer.localized(["zh-Hans": "中文", "en": "English"], l10n: zh) == "中文")
        #expect(LetterComposer.localized(["en": "English"], l10n: zh) == "English")
        #expect(LetterComposer.localized(["zh-Hans": "中文"], l10n: en) == "中文")
        let examples = Snapshots.mailExamples(catalog: localizationCatalog, now: MailClock().date, petName: "银杏 Ginkgo")
        let second = examples.letters[2]
        for language in Language.allCases {
            let text = LetterComposer.text(for: second, l10n: L10n(language: language), petName: "银杏 Ginkgo", catalog: localizationCatalog)
            #expect(text.signature.hasSuffix("银杏 Ginkgo"))
            #expect(text.lead?.isEmpty == false && !text.voice.isEmpty)
            #expect(!text.voice.contains("{city}") && !text.voice.contains("{pet}"))
        }
    }

    @Test func itineraryRendersSemanticCountriesAndPassedCities() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        var letter = try #require(model.state?.letters[1])
        letter.cityId = "shanghai"
        letter.arrivals = ["beijing", "hangzhou", "shanghai"]
        letter.newCountries = ["CN"]
        letter.compareToMedianPercent = 12
        for language in Language.allCases {
            let l10n = L10n(language: language)
            let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Ginkgo", catalog: localizationCatalog)
            #expect(text.itinerary.contains(l10n("letter.newStamp", l10n.countryName(localizationCatalog.countryNames("CN")))))
            #expect(text.itinerary.last?.contains(l10n.cityName(localizationCatalog.city("beijing"))) == true)
            #expect(text.itinerary.last?.contains(l10n.cityName(localizationCatalog.city("hangzhou"))) == true)
        }
    }

    @Test func openingUnreadMailRecordsOneCompanionDayIndependentOfUsage() async throws {
        let fixture = try MailFixture(days: 2)
        defer { fixture.remove() }
        fixture.clock.advance()
        let model = fixture.model()
        let first = try #require(model.letters.first { $0.id == 1 })
        let second = try #require(model.letters.first { $0.id == 2 })
        #expect(model.care?.companionDays.isEmpty == true)
        model.markRead(first)
        model.markRead(first)
        model.markRead(second)
        #expect(model.care?.companionDays == ["2026-11-03"])
        #expect(model.state?.letters.first { $0.id == first.id }?.read == true)
        #expect(try fixture.disk().1.companionDays == ["2026-11-03"])
        fixture.clock.advance()
        await fixture.usage.set([mailUsage("2026-11-03")])
        await model.scan()
        #expect(model.care?.companionDays == ["2026-11-03"])
        #expect(fixture.model().care?.companionDays == ["2026-11-03"])
    }

    @Test func responseSaveFailureUsesRecoveryAndDoesNotWriteCareFirst() throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        let letter = try #require(model.letters.first { $0.id == 1 })
        let before = try Data(contentsOf: fixture.careURL)
        try FileManager.default.removeItem(at: fixture.journeyURL)
        try FileManager.default.createDirectory(at: fixture.journeyURL, withIntermediateDirectories: false)
        model.reply(to: letter.id, option: letter.replyOptions[0].id)
        #expect(model.isLocked && model.lastError != nil)
        #expect(try Data(contentsOf: fixture.careURL) == before)
    }

    @Test func mailSnapshotFixturesContainAStoryAReplyAndItsPayoffWithoutSaving() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let beforeJourney = try Data(contentsOf: fixture.journeyURL)
        let beforeCare = try Data(contentsOf: fixture.careURL)
        let examples = Snapshots.mailExamples(catalog: localizationCatalog, now: fixture.clock.date, petName: "Ginkgo")
        #expect(examples.letters.count == 4)
        #expect(examples.letters[1].selectedReplyId != nil)
        #expect(examples.letters[2].fulfilledReplyId == examples.letters[1].selectedReplyId)
        #expect(!examples.letters[2].leadTexts.isEmpty && !examples.letters[2].replyOptions.isEmpty)
        #expect(try Data(contentsOf: fixture.journeyURL) == beforeJourney)
        #expect(try Data(contentsOf: fixture.careURL) == beforeCare)
    }

    @Test func placeUsesOnlyTheSelectedLanguageAndPersistsOneSuccessfulOpeningRead() async throws {
        let probe = MailEnrichmentProbe(succeeds: true)
        let fixture = try MailFixture(days: 1, enrichment: probe) { journey, _ in
            journey.letters[1].enrichmentDone = true
            journey.letters[1].place["zh-Hans"] = Letter.Place(title: "中文标题", summary: "中文介绍", url: "https://zh.wikipedia.org/wiki/Example")
        }
        defer { fixture.remove() }
        let model = fixture.model()
        let letter = try #require(model.letters.first { $0.id == 1 })
        #expect(LetterComposer.place(for: letter, l10n: model.l10n) == nil)
        await model.enrichPlace(letterId: letter.id)
        await model.enrichPlace(letterId: letter.id)
        let queries = await probe.queries
        #expect(queries.count == 1)
        let query = try #require(queries.first)
        #expect(query.language == .en && query.includePlace && !query.includePhoto && !query.includeWeather)
        #expect(query.city == localizationCatalog.city(letter.subjectCityId))
        #expect(Set(Mirror(reflecting: query).children.compactMap(\.label)) == ["city", "coordinate", "language", "includeWeather", "includePhoto", "includePlace"])
        let saved = try fixture.disk().0.letters[1]
        #expect(saved.place["en"] != nil && saved.place["zh-Hans"] == letter.place["zh-Hans"])
        #expect(saved.enrichmentDone)
        model.languagePreference = .zhHans
        await model.enrichPlace(letterId: letter.id)
        #expect(await probe.queries.count == 1)
        #expect(LetterComposer.place(for: saved, l10n: model.l10n) == saved.place["zh-Hans"])
    }

    @Test func openingABaseCityLetterRequestsItsWikidataPlace() async throws {
        let city = try #require(localizationCatalog.active.first { $0.level == "basic" && $0.wikipedia.isEmpty })
        let probe = MailEnrichmentProbe(succeeds: true)
        let fixture = try MailFixture(days: 1, enrichment: probe) { journey, _ in
            journey.letters[1].cityId = city.id
            journey.letters[1].arrivals = [city.id]
            journey.letters[1].transitTargetId = nil
            journey.letters[1].enrichmentDone = true
        }
        defer { fixture.remove() }
        let model = fixture.model()
        await model.enrichPlace(letterId: 1)
        let query = try #require(await probe.queries.first)
        #expect(query.city.id == city.id)
        #expect(query.city.wikipedia.isEmpty)
        #expect(query.city.wikidata == city.wikidata)
        #expect(query.includePlace && !query.includeWeather && !query.includePhoto)
        #expect(model.state?.letters[1].place["en"] != nil)
    }

    @Test func concurrentOpeningReadsAreDeduplicated() async throws {
        let probe = MailEnrichmentProbe(succeeds: true, delay: true)
        let fixture = try MailFixture(days: 1, enrichment: probe)
        defer { fixture.remove() }
        let model = fixture.model()
        let first = Task { await model.enrichPlace(letterId: 1) }
        let second = Task { await model.enrichPlace(letterId: 1) }
        await first.value
        await second.value
        #expect(await probe.queries.count == 1)
    }

    @Test func failedPlaceReadsAreSilentAndCappedPerLetterAndLanguage() async throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let model = fixture.model()
        for _ in 0..<5 { await model.enrichPlace(letterId: 1) }
        #expect(await fixture.enrichment.queries.count == 3)
        model.languagePreference = .zhHans
        for _ in 0..<5 { await model.enrichPlace(letterId: 1) }
        #expect(await fixture.enrichment.queries.count == 6)
        #expect(model.lastError == nil && model.state?.letters[1].place.isEmpty == true)
        #expect(model.state?.letters[1].enrichmentDone == false)
        // Weather retries cannot bypass the exhausted introduction budget by requesting a photo.
        for _ in 0..<5 { await model.enrichLatest() }
        let queries = await fixture.enrichment.queries
        #expect(queries.filter { $0.includePlace || $0.includePhoto }.count == 6)
        #expect(model.state?.letters[1].enrichmentDone == true)
    }

    @Test func scansOnlyProactivelyEnrichTheNewestLetter() async throws {
        let fixture = try MailFixture(days: 3)
        defer { fixture.remove() }
        fixture.clock.advance()
        fixture.clock.advance()
        let model = fixture.model()
        await model.scan()
        #expect(await fixture.enrichment.queries.count == 1)
        let query = try #require(await fixture.enrichment.queries.first)
        let newest = try #require(model.state?.letters.max { $0.id < $1.id })
        #expect(query.city.id == newest.subjectCityId && query.includeWeather && query.includePhoto)
        #expect(model.state?.letters[1].place.isEmpty == true)
    }

    @Test func lockedOnboardingAndSnapshotModelsNeverRequestEnrichment() async throws {
        let fixture = try MailFixture(days: 1)
        defer { fixture.remove() }
        let snapshot = fixture.model(isSnapshot: true)
        await snapshot.enrichLatest()
        await snapshot.enrichPlace(letterId: 1)
        try Data("broken".utf8).write(to: fixture.careURL)
        let locked = fixture.model()
        #expect(locked.isLocked)
        await locked.enrichLatest()
        await locked.enrichPlace(letterId: 1)
        let empty = fixture.directory.appendingPathComponent("empty")
        let onboarding = AppModel(defaults: MailDefaults(), directory: empty, catalog: localizationCatalog, themes: testThemes,
                                  enrichmentReader: { await fixture.enrichment.fetch($0) }, runtimeEnabled: false)
        #expect(onboarding.onboarding != nil)
        await onboarding.enrichLatest()
        await onboarding.enrichPlace(letterId: 0)
        #expect(await fixture.enrichment.queries.isEmpty)
    }
}
