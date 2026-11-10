import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class JourneyDetailsDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@MainActor private final class RoadClueNotifications: LetterNotificationCenter {
    var onResponse: (@MainActor (Int?) -> Void)?
    var sent: [LetterNotification] = []
    var requests = 0
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { requests += 1; return true }
    func send(_ notification: LetterNotification) async throws { sent.append(notification) }
}

@Suite @MainActor struct JourneyDetailsTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))! }

    @Test(arguments: [Language.zhHans, .en])
    func journeyStatusNamesTheRightEndpointsAndRemainingDistanceForEachPhase(language: Language) {
        let catalog = localizationCatalog, l10n = L10n(language: language)
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: catalog)
        journey.targetCityId = "jingdezhen"
        journey.legTo = catalog.city("jingdezhen").coordinate
        journey.legCost = 440 * outboundTokensPerKm
        journey.legFuel = 360 * outboundTokensPerKm
        let cases: [(JourneyState.Phase, String, String)] = language == .zhHans ? [
            (.home, "在家 · 上海", "下一站 景德镇 · 离家 440 km"),
            (.pending, "待发 · 上海 → 景德镇", "离家 440 km · 28 分后出发"),
            (.outbound, "去程 · 上海 → 景德镇", "还差 80 km"),
            (.staying, "停留 · 景德镇", "还停 2 时 17 分"),
            (.returning, "回程 · 景德镇 → 上海", "还差 80 km"),
        ] : [
            (.home, "At home · Shanghai", "Next: Jingdezhen · 440 km from home"),
            (.pending, "Pending · Shanghai → Jingdezhen", "440 km from home · Leaves in 28 min"),
            (.outbound, "Outbound · Shanghai → Jingdezhen", "80 km to go"),
            (.staying, "Staying · Jingdezhen", "Staying 2 h 17 min more"),
            (.returning, "Returning · Jingdezhen → Shanghai", "80 km to go"),
        ]
        for (phase, title, detail) in cases {
            journey.phase = phase
            journey.phaseSince = now.addingTimeInterval(phase == .staying ? -(3 * 3600 + 43 * 60) : -120)
            journey.currentCityId = phase == .staying || phase == .returning ? "jingdezhen" : "shanghai"
            if phase == .returning {
                journey.targetCityId = journey.homeCityId
                journey.legFrom = catalog.city("jingdezhen").coordinate
                journey.legTo = journey.homeCoordinate
                journey.legCost = 440 * returnTokensPerKm
                journey.legFuel = 360 * returnTokensPerKm
            }
            let display = JourneyStatusDisplay(journey: journey, now: now, catalog: catalog, l10n: l10n)
            #expect(display.title == title && display.detail == detail)
            #expect((display.progress != nil) == (phase == .outbound || phase == .returning))
        }
    }

    @Test(arguments: [JourneyState.Phase.pending, .staying])
    func journeyCountdownRoundsUpAndStopsAtZero(phase: JourneyState.Phase) {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: localizationCatalog)
        journey.phase = phase
        let duration = phase == .pending ? 30 * 60 : 6 * 3600
        journey.phaseSince = now.addingTimeInterval(-Double(duration) + 1)
        let one = JourneyStatusDisplay(journey: journey, now: now, catalog: localizationCatalog, l10n: L10n(language: .en))
        #expect(one.detail.hasSuffix(phase == .pending ? "Leaves in 1 min" : "0 h 1 min more"))
        let zero = JourneyStatusDisplay(journey: journey, now: now.addingTimeInterval(2), catalog: localizationCatalog, l10n: L10n(language: .en))
        #expect(zero.detail.hasSuffix(phase == .pending ? "Leaves in 0 min" : "0 h 0 min more"))
    }

    @Test(arguments: [Language.zhHans, .en])
    func snapshotExamplesCoverFootprintsEmptyStatesAndBilingualClues(language: Language) throws {
        let l10n = L10n(language: language)
        let example = Snapshots.journeyExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let result = Footprints(journey: example.journey, care: example.care, catalog: localizationCatalog, now: now)
        #expect(result.mostVisited.cityId == "quanzhou" && result.mostVisited.count == 2)
        #expect(result.farthest != nil && result.mostMemorable != nil)
        let clue = try #require(example.journey.days[DayKey.string(from: now)]?.roadClueDecision?.clue)
        let text = try #require(LetterComposer.localized(clue.texts, l10n: l10n))
        #expect(!text.isEmpty && !text.contains("{"))
        if language == .en { #expect(!containsHan(text)) }
        let empty = Snapshots.journeyExamples(catalog: localizationCatalog, now: now, petName: "Pip", empty: true)
        let emptyResult = Footprints(journey: empty.journey, care: empty.care, catalog: localizationCatalog, now: now)
        #expect(emptyResult.mostVisited.cityId == "shanghai" && emptyResult.mostVisited.count == 0)
        #expect(emptyResult.farthest == nil && emptyResult.mostMemorable == nil)
        #expect(empty.journey.days.isEmpty)
        for key in ["footprints.title", "footprints.farthestEmpty", "footprints.memorableEmpty", "journey.roadClueEmpty"] {
            #expect(l10n(key) != key)
            if language == .en { #expect(!containsHan(l10n(key))) }
        }
        let missing = localizationCatalog.city("unavailable-city")
        #expect(l10n.cityName(missing) == l10n("city.unknown"))
    }

    @Test func scanPersistsOneObservationWithoutMailNotificationsOrCareAndRestoresItAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("road-clue-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let example = Snapshots.journeyExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        let date = DayKey.string(from: now)
        let journey = JourneyState(seed: example.journey.seed, startCityId: "shanghai", date: date, now: now, catalog: localizationCatalog)
        let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: date)
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load(); try store.save(journey); try store.save(care)
        let center = RoadClueNotifications()
        func model(_ fuel: Int) -> AppModel {
            AppModel(languageOverride: .en, defaults: JourneyDetailsDefaults(), directory: directory, catalog: localizationCatalog,
                     themes: testThemes, now: { now }, usageReader: { _, _ in
                         [DayDetail(date: date, rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: fuel))])]
                     }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false, notificationCenter: center)
        }
        let app = model(1)
        let careBefore = app.care
        let lettersBefore = app.state?.letters
        await app.scan()
        let clue = try #require(app.state?.days[date]?.roadClueDecision?.clue)
        #expect(app.roadClueText == clue.texts["en"])
        for _ in 0..<3 { await app.scan() }
        #expect(app.state?.days[date]?.roadClueDecision?.clue == clue)
        #expect(app.state?.letters == lettersBefore && app.care == careBefore)
        #expect(center.sent.isEmpty && center.requests == 0 && app.unread == 0)
        let restarted = model(2)
        #expect(restarted.roadClueText == clue.texts["en"])
        await restarted.scan()
        #expect(restarted.state?.days[date]?.roadClueDecision?.clue == clue)
        #expect(restarted.care == careBefore && restarted.state?.letters == lettersBefore)
        store.load()
        guard case .loaded(let saved) = store.journey else { Issue.record("Saved journey must load"); return }
        #expect(saved.days[date]?.roadClueDecision?.clue == clue)
    }

    @Test func upgradeActivationIsPersistedBeforeCatchUpAndYesterdayIsNotShownAsTodaysClue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("road-clue-old-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = DayKey.string(from: now)
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: now, catalog: localizationCatalog)
        journey.roadCluesEligibleFrom = nil
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load(); try store.save(journey)
        try store.save(CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
        let app = AppModel(defaults: JourneyDetailsDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                           now: { now }, usageReader: { _, _ in
                               [DayDetail(date: "2026-11-01", rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: 100))])]
                           }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        store.load()
        guard case .loaded(let activated) = store.journey else { Issue.record("Activation must persist"); return }
        #expect(activated.roadCluesEligibleFrom == date)
        await app.scan()
        #expect(app.state?.days.values.allSatisfy { $0.roadClueDecision == nil } == true)
        #expect(app.roadClueText == nil)
    }
}
