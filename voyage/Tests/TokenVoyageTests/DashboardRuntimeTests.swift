import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class RuntimeDashboardDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@Suite @MainActor struct DashboardRuntimeTests {
    @Test func inputLoadPreparesPresentationWithoutAView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-runtime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(isSnapshot: true, defaults: RuntimeDashboardDefaults(), directory: directory,
                             catalog: localizationCatalog, themes: testThemes,
                             usageReader: { _, until in [DayDetail(date: until, rows: [.init(client: "codex", model: "test", tokens: .init(input: 42))])] },
                             hoursReader: { _, _ in [] }, runtimeEnabled: false)
        await model.loadDashboard()
        #expect(model.dashboardStore.result?.stats.totals.input == 42)
    }
}

@MainActor private final class DashboardClock {
    var date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
}

private actor DashboardReaders {
    var value = 42
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    private var blocked: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    var fail = false

    func configure(value: Int = 42, block: String? = nil, fail: Bool = false) {
        self.value = value; blocked = block; self.fail = fail
    }
    private func enter(_ name: String) async {
        calls.append(name); active += 1; maxActive = max(maxActive, active)
        if blocked == name {
            waiting = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started?.resume(); started = nil
            }
            waiting = false
        }
    }
    func waitUntilBlocked() async {
        if waiting { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { blocked = nil; continuation?.resume(); continuation = nil }
    func graph(_ since: String?, _ until: String) async throws -> [DayDetail] {
        await enter(since == nil ? "history" : "journey")
        defer { active -= 1 }
        if fail { throw UsageError.failed(1) }
        return [DayDetail(date: until, rows: [.init(client: "codex", model: "test", tokens: .init(input: value))])]
    }
    func hours(_ since: String, _ until: String) async -> [HourUsage] {
        await enter(since == until ? "today-hours" : "month-hours")
        defer { active -= 1 }
        return [HourUsage(date: until, hour: 12, tokens: .init(input: value))]
    }
}

@MainActor private struct DashboardFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-runtime-\(UUID())")
    let clock = DashboardClock()
    let readers = DashboardReaders()
    init() throws {
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: clock.date), now: clock.date, catalog: localizationCatalog)
        try store.save(journey)
        try store.save(CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
    }
    func model(snapshot: Bool = false, runtime: Bool = false) -> AppModel {
        AppModel(isSnapshot: snapshot, defaults: RuntimeDashboardDefaults(), directory: directory,
                 catalog: localizationCatalog, themes: testThemes, now: { clock.date },
                 quotaReader: { [] }, usageReader: { try await readers.graph($0, $1) },
                 hoursReader: { await readers.hours($0, $1) }, enrichmentReader: { _ in Enrichment() },
                 hubClient: HubClient(baseURL: nil), runtimeEnabled: runtime, watcherRoots: { [] })
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

extension DashboardRuntimeTests {
    @Test func launchWarmsTheDefaultSelectionAfterJourneyWithoutOpeningDataTab() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(runtime: true)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while model.dashboardStore.result == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.tab == .home)
        #expect(model.dashboardStore.result?.stats.totals.input == 42)
        #expect(await fixture.readers.calls.prefix(2) == ["journey", "history"])
        #expect(await fixture.readers.maxActive == 1)
        // Finish background stages before removing the fixture's directory.
        while model.dashboardDiskCache.load()?.monthHoursReadAt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        await model.dashboardDiskCache.flush()
    }

    @Test func backgroundClockRefreshesHistoryWithoutAnotherJourneyScanOrAnOpenTab() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(runtime: true)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while model.dashboardDiskCache.load()?.monthHoursReadAt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await fixture.readers.calls == ["journey", "history", "today-hours", "month-hours"])
        fixture.clock.date.addTimeInterval(300)
        await fixture.readers.configure(value: 84)
        model.tick()
        while model.dashboardDiskCache.load()?.todayHoursReadAt != fixture.clock.date, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.tab == .home)
        #expect(model.dashboardStore.result?.stats.totals.input == 84)
        #expect(await fixture.readers.calls == ["journey", "history", "today-hours", "month-hours", "history", "today-hours"])
        #expect(await fixture.readers.maxActive == 1)
        await model.dashboardDiskCache.flush()
    }

    @Test func relaunchHasPresentationAndItsTimestampBeforeAnyReaderCall() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model()
        await first.loadDashboard()
        await first.dashboardDiskCache.flush()
        let calls = await fixture.readers.calls
        fixture.clock.date.addTimeInterval(600)
        let restored = fixture.model()
        #expect(restored.dashboardStore.result?.stats.totals.input == 42)
        #expect(restored.dashboardStore.updatedAt == fixture.clock.date.addingTimeInterval(-600))
        #expect(await fixture.readers.calls == calls)
        #expect(restored.dashboardHours == first.dashboardHours)
    }

    @Test(arguments: [false, true]) func corruptAndOtherVersionCachesAreDeleted(otherVersion: Bool) async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let initial = fixture.model()
        await initial.loadDashboard()
        await initial.dashboardDiskCache.flush()
        let url = initial.dashboardDiskCache.url
        if otherVersion {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["version"] = 0
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        } else { try Data("broken cache".utf8).write(to: url) }
        let calls = await fixture.readers.calls
        let restored = fixture.model()
        #expect(restored.dashboardStore.result == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await fixture.readers.calls == calls)
    }

    @Test func refreshRetainsResultUntilReplacementAndPersistsNewInput() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.loadDashboard()
        fixture.clock.date.addTimeInterval(3601)
        await fixture.readers.configure(value: 84, block: "history")
        let refresh = Task { await model.loadDashboard() }
        await fixture.readers.waitUntilBlocked()
        #expect(model.dashboardStore.result?.stats.totals.input == 42)
        #expect(model.dashboardStore.updatedAt == fixture.clock.date.addingTimeInterval(-3601))
        await fixture.readers.release()
        await refresh.value
        #expect(model.dashboardStore.result?.stats.totals.input == 84)
        #expect(model.dashboardStore.updatedAt == fixture.clock.date)
        await model.dashboardDiskCache.flush()
        #expect(model.dashboardDiskCache.load()?.days == model.dashboardDays)
        #expect(fixture.model().dashboardStore.result?.stats.totals.input == 84)
    }

    @Test func failedRefreshKeepsOldResultAndDoesNotChangeJourneyError() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.loadDashboard()
        fixture.clock.date.addTimeInterval(600)
        await fixture.readers.configure(fail: true)
        await model.loadDashboard()
        #expect(model.dashboardStore.result?.stats.totals.input == 42)
        #expect(model.dashboardError != nil && model.lastError == nil)
        await model.dashboardDiskCache.flush()
    }

    @Test func warmupYieldsBetweenReadersToAPendingJourneyAndNeverOverlaps() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        await fixture.readers.configure(block: "history")
        let model = fixture.model()
        let warmup = Task { await model.loadDashboard() }
        await fixture.readers.waitUntilBlocked()
        await model.scan()
        #expect(await fixture.readers.calls == ["history"])
        await fixture.readers.release()
        await warmup.value
        #expect(await fixture.readers.calls == ["history", "journey", "today-hours", "month-hours"])
        #expect(await fixture.readers.maxActive == 1)
        #expect(model.dashboardStore.result?.stats.totals.input == 42)
        await model.dashboardDiskCache.flush()
    }

    @Test func resettingSaveClearsCacheAndCannotBeResurrectedByAnOldRead() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.loadDashboard()
        let store = SaveStore(directory: fixture.directory, pets: localizationCatalog.pets,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        let candidate = try store.validateArchive(store.exportArchive(appVersion: "test"))
        fixture.clock.date.addTimeInterval(600)
        await fixture.readers.configure(value: 84, block: "history")
        let refresh = Task { await model.loadDashboard() }
        await fixture.readers.waitUntilBlocked()
        #expect(await model.importSave(candidate))
        #expect(model.dashboardDays == nil && model.dashboardStore.result == nil)
        await fixture.readers.release()
        await refresh.value
        await model.dashboardDiskCache.flush()
        #expect(!FileManager.default.fileExists(atPath: model.dashboardDiskCache.url.path))
    }

    @Test func runningAppWarmsAgainAfterImportWhileTheOldCacheIsCleared() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(runtime: true)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while model.dashboardDiskCache.load()?.monthHoursReadAt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let store = SaveStore(directory: fixture.directory, pets: localizationCatalog.pets,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        let candidate = try store.validateArchive(store.exportArchive(appVersion: "test"))
        fixture.clock.date.addTimeInterval(600)
        await fixture.readers.configure(value: 84, block: "history")
        #expect(await model.importSave(candidate))
        await fixture.readers.waitUntilBlocked()
        await model.dashboardDiskCache.flush()
        #expect(model.dashboardStore.result == nil)
        #expect(!FileManager.default.fileExists(atPath: model.dashboardDiskCache.url.path))
        await fixture.readers.release()
        while model.dashboardDiskCache.load()?.monthHoursReadAt != fixture.clock.date, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.dashboardStore.result?.stats.totals.input == 84)
        await model.dashboardDiskCache.flush()
    }

    @Test func snapshotNeitherReadsWritesNorClearsExistingCache() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.cleanUp() }
        let real = fixture.model()
        await real.loadDashboard()
        await real.dashboardDiskCache.flush()
        let before = try Data(contentsOf: real.dashboardDiskCache.url)
        let snapshot = fixture.model(snapshot: true)
        #expect(snapshot.dashboardStore.result == nil)
        await snapshot.scan()
        await snapshot.loadDashboard()
        await snapshot.dashboardDiskCache.flush()
        #expect(try Data(contentsOf: real.dashboardDiskCache.url) == before)
    }
}
