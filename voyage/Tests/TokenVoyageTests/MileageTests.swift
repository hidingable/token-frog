import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class MileageDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

private actor MileageReader {
    let history: [DayDetail]
    var failFirst: Bool
    var today: DayDetail
    var ranges: [(String?, String)] = []

    init(history: [DayDetail], today: DayDetail, failFirst: Bool) {
        self.history = history
        self.today = today
        self.failFirst = failFirst
    }

    func read(since: String?, until: String) throws -> [DayDetail] {
        ranges.append((since, until))
        if failFirst { failFirst = false; throw UsageError.missingBinary }
        return (history + [today]).filter { $0.date >= (since ?? "") && $0.date <= until }
    }

    func addTokens() { today.rows[0].tokens.cacheRead += outboundTokensPerKm }
}

@Suite @MainActor struct MileageTests {
    @Test(arguments: [false, true])
    func upgradeBackfillsFourteenActiveDaysWithoutReplayingMileageOrRetryingUnreadDays(failFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-mileage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let today = DayKey.string(from: now)
        let keys = (1...20).map { DayKey.string(from: calendar.date(byAdding: .day, value: -2 * $0, to: now)!) }
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: keys.last!, now: now, catalog: localizationCatalog)
        journey.openDate = today
        journey.weeklyMailEligibleFrom = today
        journey.totalFuel = 3_000_000
        for key in keys + [today] {
            var record = DayRecord()
            record.fuel = 100
            record.tokens = nil
            journey.days[key] = record
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)) as? [String: Any])
        json["version"] = 6
        json["route"] = [journey.homeCityId] + journey.route
        for key in ["homeCityId", "homeCoordinate", "phase", "phaseSince", "travelFund", "tripCount"] {
            json.removeValue(forKey: key)
        }
        json.removeValue(forKey: "totalKm")
        json["legCost"] = journey.legCost / 100
        json["legFuel"] = journey.legCost / 300
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("journey.json"))
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
        func detail(_ key: String) -> DayDetail {
            DayDetail(date: key, rows: [.init(client: "codex", model: "test", tokens: .init(input: 100, cacheRead: 399_999_900))])
        }
        // One missing historical day stays unknown, rather than becoming a zero or a fuel estimate.
        let reader = MileageReader(history: keys.filter { $0 != keys[3] }.map(detail), today: detail(today), failFirst: failFirst)
        let model = AppModel(defaults: MileageDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                             now: { now }, usageReader: { since, until in try await reader.read(since: since, until: until) },
                             enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        let original = try #require(model.state)
        await model.scan()
        if failFirst { await model.scan() }
        let state = try #require(model.state)
        #expect(state.totalKm == 300 && state.legFuel == original.legFuel)
        #expect(state.letters == original.letters && state.route == original.route)
        #expect(state.days[keys[13]]?.tokens == 400_000_000)
        #expect(state.days[keys[14]]?.tokens == nil && state.days[keys[3]]?.tokens == nil)
        #expect(state.recentDailyKm(before: today) == 400)
        #expect(model.todayTokens == 400_000_000 && model.todayKm == 400)
        let firstRanges = await reader.ranges
        #expect(firstRanges.allSatisfy { $0.0 == keys[13] && $0.1 == today })
        await reader.addTokens()
        await model.scan()
        #expect(model.state?.totalKm == 301)
        #expect(model.state?.legFuel == original.legFuel + outboundTokensPerKm)
        let ranges = await reader.ranges
        #expect(ranges.last?.0 == today)
        let saved = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: directory.appendingPathComponent("journey.json")))
        #expect(saved == model.state)
    }
}
