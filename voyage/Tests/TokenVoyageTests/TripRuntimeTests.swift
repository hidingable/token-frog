import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class TripDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@MainActor private final class TripClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor TripUsageReader {
    let days: [DayDetail]
    private(set) var requests: [String] = []
    init(_ days: [DayDetail]) { self.days = days }
    func graph() -> [DayDetail] {
        requests.append("graph")
        return days
    }
    func hours(since: String, until: String) throws -> [HourUsage] {
        #expect(since == until)
        requests.append("hours:" + since)
        if since == "2026-11-07" { throw UsageError.failed(1) }
        return [HourUsage(date: since, hour: 16, tokens: UsageTotals(input: 2))]
    }
}

@Suite @MainActor struct TripRuntimeTests {
    private func save(_ journey: JourneyState, at directory: URL) throws {
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
    }

    private func model(directory: URL, clock: TripClock) -> AppModel {
        AppModel(defaults: TripDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { clock.date }, usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
                 enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    }

    @Test(arguments: [false, true])
    func pendingDepartureRunsWithoutAnotherUsageReadAndPersists(immediate: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-trip-timer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let clock = TripClock(start)
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", now: start, catalog: localizationCatalog)
        journey.phase = .pending
        journey.legFuel = outboundTokensPerKm
        var record = DayRecord()
        record.tokens = outboundTokensPerKm
        record.lastObservedAt = start
        journey.days[journey.openDate] = record
        try save(journey, at: directory)
        let app = model(directory: directory, clock: clock)
        clock.date = start.addingTimeInterval(immediate ? 60 : 30 * 60)
        if immediate { app.departNow() } else { app.tick() }
        #expect(app.state?.phase == .outbound)
        #expect(app.state?.legFuel == outboundTokensPerKm)
        #expect(app.state?.totalKm == 1)
        #expect(app.state?.days["2026-11-10"]?.lastObservedAt == start)
        #expect(model(directory: directory, clock: clock).state == app.state)
    }

    @Test func timerFinishesASavedStayAfterTheApplicationWasClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-trip-stay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let arrived = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 6))!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", now: arrived, catalog: localizationCatalog)
        journey.currentCityId = journey.targetCityId
        journey.route = [journey.targetCityId]
        journey.phase = .staying
        journey.legFuel = journey.legCost
        journey.phaseSince = arrived
        var record = DayRecord()
        record.arrivals = [journey.targetCityId]
        record.lastObservedAt = arrived
        journey.days[journey.openDate] = record
        try save(journey, at: directory)
        let clock = TripClock(arrived.addingTimeInterval(6 * 3600))
        let app = model(directory: directory, clock: clock)
        app.tick()
        #expect(app.state?.phase == .returning)
        #expect(app.state?.phaseSince == clock.date)
        #expect(app.state?.targetCityId == journey.homeCityId)
        #expect(app.state?.tokensPerKm == returnTokensPerKm)
        #expect(model(directory: directory, clock: clock).state == app.state)
    }

    @Test func finalizationReadsOnlyRecentResidualDaysInOrderAndHourlyFailureDoesNotRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-trip-hours-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-10-09",
                                   now: DayKey.date(from: "2026-10-09")!, catalog: localizationCatalog)
        var credited = DayRecord()
        credited.tokens = 100
        credited.lastObservedAt = DayKey.date(from: "2026-11-08")!.addingTimeInterval(12 * 3600)
        journey.days["2026-11-08"] = credited
        var partial = DayRecord()
        partial.tokens = 1
        partial.lastObservedAt = DayKey.date(from: "2026-11-09")!.addingTimeInterval(12 * 3600)
        journey.days["2026-11-09"] = partial
        journey.legFuel = 101
        journey.totalKm = 101 / Double(outboundTokensPerKm)
        try save(journey, at: directory)
        func detail(_ key: String, _ tokens: Int) -> DayDetail {
            DayDetail(date: key, rows: [.init(client: "codex", model: "test", tokens: .init(input: tokens))])
        }
        let reader = TripUsageReader([detail("2026-10-09", 1), detail("2026-11-07", 2),
                                      detail("2026-11-08", 100), detail("2026-11-09", 3)])
        let app = AppModel(defaults: TripDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                           now: { now }, usageReader: { _, _ in await reader.graph() },
                           hoursReader: { since, until in try await reader.hours(since: since, until: until) },
                           enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        await app.scan()
        #expect(await reader.requests == ["graph", "hours:2026-11-07", "hours:2026-11-09"])
        #expect(app.lastError == nil)
        #expect(app.state?.legFuel == 106)
        #expect(abs((app.state?.totalKm ?? 0) - 106 / Double(outboundTokensPerKm)) < 0.000000001)
        await app.scan()
        #expect(await reader.requests == ["graph", "hours:2026-11-07", "hours:2026-11-09", "graph"])
        #expect(app.state?.legFuel == 106)
    }
}
