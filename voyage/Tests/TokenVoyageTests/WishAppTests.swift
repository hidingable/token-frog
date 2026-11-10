import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class WishDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

private actor WishProbe {
    private(set) var calls = 0
    func parse(_ text: String, _ language: Language, _ tags: [String]) -> [String] {
        calls += 1
        #expect(text == "**Quiet moments**" && language == .en && tags.contains("coast"))
        return ["coast", "not-a-tag"]
    }
}

@MainActor private final class WishClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor private struct WishAppFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-wish-app-\(UUID())")
    var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))! }

    func save(_ journey: JourneyState, _ care: CareState) throws {
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey); try store.save(care)
    }
    func model(catalog: CityCatalog = localizationCatalog, clock: (() -> Date)? = nil, wishModel: WishContent.Model? = nil,
               usageReader: @escaping @Sendable (String?, String) async throws -> [DayDetail] = { _, _ in [] }) -> AppModel {
        AppModel(languageOverride: .en, defaults: WishDefaults(), directory: directory, catalog: catalog, themes: testThemes,
                 now: clock ?? { now }, usageReader: usageReader, hoursReader: { _, _ in [] }, enrichmentReader: { _ in Enrichment() },
                 wishModel: wishModel, runtimeEnabled: false)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func wishReturnJourney(seed: UInt32, catalog: CityCatalog, now: Date) -> JourneyState {
    let key = DayKey.string(from: now)
    var journey = JourneyState(seed: seed, startCityId: "shanghai", date: key, now: now.addingTimeInterval(-6 * 3600), catalog: catalog)
    let city = catalog.city(journey.targetCityId)
    journey.route = [city.id]
    journey.currentCityId = city.id
    journey.targetCityId = journey.homeCityId
    journey.targetCountryCode = catalog.city(journey.homeCityId).countryCode
    journey.phase = .returning
    journey.phaseSince = now
    journey.legFrom = city.coordinate
    journey.legTo = journey.homeCoordinate
    journey.legCost = max(returnTokensPerKm, Int(city.coordinate.distanceKm(to: journey.homeCoordinate) * Double(returnTokensPerKm)))
    var day = DayRecord()
    day.arrivals = [city.id]
    journey.days[key] = day
    return journey
}

@Suite @MainActor struct WishAppTests {
    @Test func writingSavesOriginalAndValidatedTagsAndReloadNeverParsesAgain() async throws {
        let fixture = WishAppFixture()
        defer { fixture.cleanUp() }
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-02", catalog: localizationCatalog)
        let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        try fixture.save(journey, care)
        let probe = WishProbe()
        let model = fixture.model(wishModel: { await probe.parse($0, $1, $2) })
        let target = model.state?.targetCityId
        #expect(await model.setWish("**Quiet moments**"))
        #expect(model.care?.wish == "**Quiet moments**")
        #expect(model.care?.wishResolution?.tags == ["coast"])
        #expect(model.care?.wishResolution?.parsedAt == fixture.now)
        #expect(model.state?.targetCityId == target)
        #expect(await model.setWish("**Quiet moments**"))
        #expect(await probe.calls == 1)
        let reloaded = fixture.model(wishModel: { _, _, _ in Issue.record("Reload must not parse"); return [] })
        reloaded.languagePreference = .zhHans
        reloaded.tick()
        await reloaded.scan()
        #expect(reloaded.care?.wish == "**Quiet moments**" && reloaded.care?.wishResolution == model.care?.wishResolution)
        #expect(!reloaded.isSavingWish)
        let saved = reloaded.care
        #expect(!(await reloaded.setWish(String(repeating: "字", count: 41))))
        #expect(reloaded.care == saved)
        #expect(await reloaded.setWish(""))
        #expect(fixture.model().care?.wish == nil && fixture.model().care?.wishResolution == nil)
    }

    @Test func appScanPassesSavedTagsIntoBothDestinationAndStorySelection() async throws {
        let fixture = WishAppFixture()
        defer { fixture.cleanUp() }
        // Keep story priorities explicit so only the saved wish can choose the coastal story.
        let content = fixture.directory.appendingPathComponent("test-content")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content"), to: content)
        let storyDir = content.appendingPathComponent("stories")
        for file in try FileManager.default.contentsOfDirectory(at: storyDir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let stories = ["arrival", "transit"].flatMap { kind in
            [false, true].map { wished in
                Story(id: "test.\(kind).\(wished)", version: 1, kind: kind, cityId: nil, factIds: [],
                      tags: wished ? ["coast"] : [], requires: .init(), fulfills: [],
                      text: ["zh-Hans": "旅途平安。", "en": "All well on the road."], replies: [], rewards: .init())
            }
        }
        try JSONEncoder().encode(stories).write(to: storyDir.appendingPathComponent("test.json"))
        let catalog = try CityCatalog.load(directory: content)
        let seed = try #require((UInt32(0)..<100).first { seed in
            let initial = wishReturnJourney(seed: seed, catalog: catalog, now: fixture.now)
            var a = initial, b = initial
            a.sync(today: DayUsage(date: a.openDate, fuel: a.legCost), now: fixture.now, catalog: catalog, wishTags: ["coast"])
            b.sync(today: DayUsage(date: b.openDate, fuel: b.legCost), now: fixture.now, catalog: catalog)
            return a.targetCityId != b.targetCityId
        })
        let journey = wishReturnJourney(seed: seed, catalog: catalog, now: fixture.now)
        let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        try fixture.save(journey, care)
        var current = fixture.now
        let fuel = journey.legCost
        let reader: @Sendable (String?, String) async throws -> [DayDetail] = { _, _ in
            [DayDetail(date: "2026-11-02", rows: [.init(client: "codex", model: "test", tokens: .init(input: fuel))])]
        }
        let model = fixture.model(catalog: catalog, clock: { current }, wishModel: { _, _, _ in ["coast"] }, usageReader: reader)
        #expect(await model.setWish("Quiet moments"))
        var expected = journey
        expected.sync(today: DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel]), now: fixture.now, catalog: catalog, wishTags: ["coast"])
        await model.scan()
        #expect(model.state?.targetCityId == expected.targetCityId)
        #expect(model.state?.route == expected.route)
        current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
        await model.scan()
        let letter = try #require(model.state?.letters.last { $0.kind == .daily })
        #expect(letter.storyId == "test.arrival.true")
        #expect(letter.wishExplanationAt == nil)
    }

    @Test func whitespaceOnlyInputSavesNoWish() async throws {
        let fixture = WishAppFixture()
        defer { fixture.cleanUp() }
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-02", catalog: localizationCatalog)
        try fixture.save(journey, CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
        let model = fixture.model()
        #expect(await model.setWish("  \n "))
        #expect(model.care?.wish == nil && model.care?.wishResolution == nil)
    }

    @Test func mondayClearsAndPersistsEvenIfUsageReadFails() async throws {
        let fixture = WishAppFixture()
        defer { fixture.cleanUp() }
        var current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 59))!
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-08", catalog: localizationCatalog)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        WishEngine.write("sea", tags: ["coast"], at: current, care: &care)
        try fixture.save(journey, care)
        let model = fixture.model(clock: { current }, usageReader: { _, _ in throw UsageError.missingBinary })
        current = current.addingTimeInterval(60)
        model.tick()
        await model.scan()
        #expect(model.care?.wish == nil && model.care?.wishResolution == nil)
        #expect(model.care?.habits == care.habits && model.care?.pity == care.pity && model.care?.weekly == care.weekly)
        #expect(fixture.model(clock: { current }).care?.wish == nil)
    }

    @Test func aModelReplyAfterMondayDoesNotCarrySundaysWishIntoTheNewWeek() async throws {
        let fixture = WishAppFixture()
        defer { fixture.cleanUp() }
        let sunday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 59, second: 59))!
        let clock = WishClock(sunday)
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-08", catalog: localizationCatalog)
        let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        try fixture.save(journey, care)
        let model = fixture.model(clock: { clock.date }, wishModel: { _, _, _ in
            await MainActor.run { clock.date = sunday.addingTimeInterval(2) }
            return ["coast"]
        })
        #expect(await model.setWish("sea"))
        #expect(model.care?.wish == nil && model.care?.wishResolution == nil)
        #expect(fixture.model(clock: { clock.date }).care?.wish == nil)
    }

    @Test func wishCopyAndSnapshotFixturesCoverBothLanguagesWithoutTranslatingOriginals() throws {
        let fixture = WishAppFixture()
        let model = AppModel(isSnapshot: true, directory: fixture.directory, catalog: localizationCatalog, themes: testThemes)
        let example = Snapshots.wishMailExamples(catalog: localizationCatalog, now: fixture.now, petName: "Pip")
        for language in Language.allCases {
            let l10n = L10n(language: language)
            #expect(l10n("snapshot.wishWritten").count == WishEngine.characterLimit)
            for key in ["title", "optional", "empty", "write", "edit", "clear", "save", "saving", "cancel", "count", "hint", "privacy", "placeholder"] {
                let value = l10n("wish." + key)
                #expect(value != "wish." + key)
                if language == .en { #expect(!containsHan(value)) }
            }
            let letter = try #require(example.journey.letters.last)
            #expect(letter.texts?[language.rawValue]?.hasSuffix(localizationCatalog.wishes.unmatched[language.rawValue]!) == true)
        }
        #expect(example.care.wish == "blorble blorble")
        #expect(model.care?.wish == nil)
    }
}
