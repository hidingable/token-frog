import Foundation
import Observation
import os
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private func dashboardCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func dashboardInput() throws -> DashboardInput {
    let data = try DashboardSyntheticData(count: 400, now: DayKey.date(from: "2026-11-06", calendar: dashboardCalendar())!, calendar: dashboardCalendar())
    return DashboardInput(days: data.days, hours: data.hours)
}

private func dashboardRequest(version: Int = 1, today: String = "2026-11-06", start: String? = "2026-10-08",
                              filter: DashboardFilter = .init(), metric: DashboardMetric = .total) -> DashboardRequest {
    DashboardRequest(version: version, today: today, start: start, end: today, filter: filter, metric: metric,
                     seriesLimit: 3, calendar: dashboardCalendar())
}

@Test func dashboardCacheReusesBoardsAcrossMetricsAndAnnualHeatAcrossRanges() async throws {
    let cache = DashboardCache()
    let input = try dashboardInput()
    let first = dashboardRequest()
    _ = await cache.result(input: input, request: first)
    #expect(await cache.boardComputations == 2) // range and all-time (also the annual board)
    #expect(await cache.presentationComputations == 1)
    for _ in 0..<3 { _ = await cache.result(input: input, request: first) }
    #expect(await cache.boardComputations == 2)
    #expect(await cache.presentationComputations == 1)
    _ = await cache.result(input: input, request: dashboardRequest(metric: .cost))
    #expect(await cache.boardComputations == 2)
    #expect(await cache.heatComputations == 2)
    _ = await cache.result(input: input, request: dashboardRequest(start: "2026-11-01"))
    #expect(await cache.boardComputations == 3)
    #expect(await cache.heatComputations == 2)
    _ = await cache.result(input: input, request: first)
    #expect(await cache.presentationComputations == 3)
    _ = await cache.result(input: input, request: dashboardRequest(filter: .init(client: "codex")))
    #expect(await cache.boardComputations == 5)
    _ = await cache.result(input: input, request: dashboardRequest(filter: .init(client: "codex"), metric: .messages))
    #expect(await cache.boardComputations == 5)
}

@Test func dashboardCacheInvalidatesOnVersionAndToday() async throws {
    let cache = DashboardCache()
    let input = try dashboardInput()
    _ = await cache.result(input: input, request: dashboardRequest())
    _ = await cache.result(input: input, request: dashboardRequest(version: 2))
    #expect(await cache.boardComputations == 4)
    _ = await cache.result(input: input, request: dashboardRequest(version: 2, today: "2026-11-07"))
    #expect(await cache.boardComputations == 6)
    #expect(await cache.heatComputations == 3)
}

@Test func dashboardCacheKeepsEightMostRecentlyUsedPresentations() async throws {
    let cache = DashboardCache()
    let input = try dashboardInput()
    let requests = (1...9).map { dashboardRequest(start: String(format: "2026-10-%02d", $0)) }
    for request in requests.prefix(8) { _ = await cache.result(input: input, request: request) }
    _ = await cache.result(input: input, request: requests[0]) // refresh the oldest
    _ = await cache.result(input: input, request: requests[8])
    #expect(await cache.presentationComputations == 9)
    _ = await cache.result(input: input, request: requests[0])
    #expect(await cache.presentationComputations == 9)
    _ = await cache.result(input: input, request: requests[1])
    #expect(await cache.presentationComputations == 10)
}

@Test func cachedDashboardExactlyMatchesDirectCalculations() async throws {
    let input = try dashboardInput()
    let cache = DashboardCache()
    for start: String? in [nil, "2026-11-06", "2026-10-31", "2026-10-08", "2026-08-09", "2025-11-07"] {
        for filter in [DashboardFilter(), DashboardFilter(client: "codex"), DashboardFilter(model: "claude-model-2"), DashboardFilter(client: "absent")] {
            for metric in DashboardMetric.allCases {
                let request = dashboardRequest(start: start, filter: filter, metric: metric)
                let result = await cache.result(input: input, request: request)
                let direct = UsageDashboard(days: input.days, start: start, end: request.end, filter: filter, calendar: request.calendar)
                let year = UsageDashboard(days: input.days, start: nil, end: request.today, filter: filter, calendar: request.calendar)
                let everything = UsageDashboard(days: input.days, start: nil, end: request.today, calendar: request.calendar)
                let tools = Array(everything.ledger.byClient.prefix(request.seriesLimit).map(\.name))
                let hours = filter.isEmpty ? HourUsage.profile(input.hours, start: direct.start, end: direct.end, metric: metric) : []
                #expect(result.stats == DashboardStats(direct))
                #expect(result.board.start == direct.start)
                #expect(result.board.end == direct.end)
                #expect(result.board.ledger == direct.ledger)
                #expect(result.board.previous == direct.previous)
                #expect(result.yearBoard.ledger == year.ledger)
                #expect(result.everything.ledger == everything.ledger)
                #expect(DashboardStats(result.yearBoard) == DashboardStats(year))
                #expect(DashboardStats(result.everything) == DashboardStats(everything))
                #expect(result.tools == tools)
                #expect(result.trend == DashboardTrend(board: direct, hours: hours, metric: metric, tools: tools))
                #expect(result.heat == DashboardHeat(cells: year.heatCells(metric: metric)))
                #expect(result.hours == hours)
                #expect(result.weekdays == direct.weekdayProfile(metric))
            }
        }
    }
}

private actor DashboardGate {
    private var waiting: [DashboardMetric: CheckedContinuation<Void, Never>] = [:]
    private var observers: [DashboardMetric: CheckedContinuation<Void, Never>] = [:]
    func block(_ metric: DashboardMetric) async {
        await withCheckedContinuation { continuation in
            waiting[metric] = continuation
            observers.removeValue(forKey: metric)?.resume()
        }
    }
    func started(_ metric: DashboardMetric) async {
        if waiting[metric] != nil { return }
        await withCheckedContinuation { observers[metric] = $0 }
    }
    func release(_ metric: DashboardMetric) { waiting.removeValue(forKey: metric)?.resume() }
}

@Suite @MainActor struct DashboardStoreTests {
    @Test func staleBackgroundResultsCannotReplaceTheLatestRequestAndOldContentStaysVisible() async throws {
        let gate = DashboardGate()
        let cache = DashboardCache()
        let input = try dashboardInput()
        let store = DashboardStore(today: "2026-11-06", compute: { input, request in
            if request.metric != .total { await gate.block(request.metric) }
            return await cache.result(input: input, request: request)
        })
        store.update(days: input.days, hours: input.hours)
        let initial = store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar())
        await store.select(initial)
        var selection = DashboardSelection()
        selection.metric = .fuel
        let older = store.request(selection: selection, seriesLimit: 3, calendar: dashboardCalendar())
        let oldTask = Task { await store.select(older) }
        await gate.started(.fuel)
        selection.metric = .cost
        let newest = store.request(selection: selection, seriesLimit: 3, calendar: dashboardCalendar())
        let newTask = Task { await store.select(newest) }
        await gate.started(.cost)
        #expect(store.result?.request == initial)
        await gate.release(.cost)
        await newTask.value
        #expect(store.result?.request == newest)
        await gate.release(.fuel)
        await oldTask.value
        #expect(store.result?.request == newest)
    }

    @Test func dataChangesInvalidateInFlightWorkAndIdenticalDataDoesNotChangeVersion() async throws {
        let gate = DashboardGate()
        let cache = DashboardCache()
        let input = try dashboardInput()
        let store = DashboardStore(today: "2026-11-06", compute: { input, request in
            await gate.block(request.metric)
            return await cache.result(input: input, request: request)
        })
        store.update(days: input.days, hours: input.hours)
        let version = store.version
        store.update(days: input.days, hours: input.hours)
        #expect(store.version == version)
        let request = store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar())
        let task = Task { await store.select(request) }
        await gate.started(.total)
        store.update(days: input.days + [DayDetail(date: "2026-11-07", rows: [])], hours: input.hours)
        #expect(store.version == version + 1)
        await gate.release(.total)
        await task.value
        #expect(store.result == nil)
        store.update(days: input.days, hours: [])
        #expect(store.version == version + 2)
    }

    @Test func midnightInvalidatesInFlightWork() async throws {
        let gate = DashboardGate()
        let cache = DashboardCache()
        let input = try dashboardInput()
        let store = DashboardStore(today: "2026-11-06", compute: { input, request in
            await gate.block(request.metric)
            return await cache.result(input: input, request: request)
        })
        store.update(days: input.days, hours: input.hours)
        let request = store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar())
        let task = Task { await store.select(request) }
        await gate.started(.total)
        store.updateToday("2026-11-07")
        await gate.release(.total)
        await task.value
        #expect(store.result == nil)
    }

    @Test func thirtySecondClockTicksDoNotInvalidateDashboardUntilMidnight() throws {
        var clock = DayKey.date(from: "2026-11-06", calendar: dashboardCalendar())!.addingTimeInterval(12 * 3600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-clock-\(UUID().uuidString)")
        let model = AppModel(isSnapshot: true, defaults: DashboardDefaults(), directory: directory,
                             catalog: localizationCatalog, themes: testThemes, now: { clock }, runtimeEnabled: false)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.dashboardStore.today
            _ = model.dashboardStore.version
            _ = model.dashboardStore.result
        } onChange: {
            changed.withLock { $0 = true }
        }
        let today = model.dashboardStore.today
        clock = clock.addingTimeInterval(30)
        model.tick()
        #expect(!changed.withLock { $0 })
        #expect(model.dashboardStore.today == today)
        clock = clock.addingTimeInterval(24 * 3600)
        model.tick()
        #expect(changed.withLock { $0 })
        #expect(model.dashboardStore.today != today)
    }

    @Test func todayAndLanguageOnlyInvalidateTheirOwnDependencies() async throws {
        let cache = DashboardCache()
        let input = try dashboardInput()
        let store = DashboardStore(today: "2026-11-06", compute: { input, request in await cache.result(input: input, request: request) })
        store.update(days: input.days, hours: input.hours)
        let request = store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar())
        await store.select(request)
        let stats = try #require(store.result?.stats)
        for language in Language.allCases {
            let l10n = L10n(language: language)
            #expect(!l10n.day("2026-11-06").isEmpty)
            await store.select(request)
            #expect(store.result?.stats == stats)
        }
        #expect(L10n(language: .en).day("2026-11-06") != L10n(language: .zhHans).day("2026-11-06"))
        #expect(await cache.presentationComputations == 1)
        store.updateToday("2026-11-06")
        #expect(store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar()) == request)
        store.updateToday("2026-11-07")
        await store.select(store.request(selection: .init(), seriesLimit: 3, calendar: dashboardCalendar()))
        #expect(await cache.presentationComputations == 2)
        #expect(store.result?.request.today == "2026-11-07")
    }
}

@Test func heatGridCoordinatesMatchDatesAtEveryBoundary() throws {
    let input = try dashboardInput()
    let board = UsageDashboard(days: input.days, start: nil, end: "2026-11-06", calendar: dashboardCalendar())
    let cells = board.heatCells(metric: .total)
    let pitch: CGFloat = 13
    for cell in cells {
        let origin = CGPoint(x: 20 + CGFloat(cell.week) * pitch, y: 16 + CGFloat(cell.weekday) * pitch)
        #expect(HeatGridGeometry.cell(at: origin, pitch: pitch, cells: cells) == cell)
        #expect(HeatGridGeometry.cell(at: CGPoint(x: origin.x + pitch - 0.01, y: origin.y + pitch - 0.01), pitch: pitch, cells: cells) == cell)
    }
    for point in [CGPoint(x: 19.99, y: 16), CGPoint(x: 20, y: 15.99), CGPoint(x: 20, y: 16 + 7 * pitch),
                  CGPoint(x: 20 + 53 * pitch, y: 16), CGPoint(x: CGFloat.infinity, y: 16), CGPoint(x: 20, y: CGFloat.nan)] {
        #expect(HeatGridGeometry.cell(at: point, pitch: pitch, cells: cells) == nil)
    }
    let last = try #require(cells.last)
    #expect(HeatGridGeometry.cell(at: CGPoint(x: 20 + CGFloat(last.week) * pitch, y: 16 + CGFloat(last.weekday + 1) * pitch), pitch: pitch, cells: cells) == nil)
    #expect(HeatGridGeometry.cell(at: CGPoint(x: 20, y: 16), pitch: pitch, cells: []) == nil)
    #expect(HeatGridGeometry.cell(at: CGPoint(x: 20, y: 16), pitch: 0, cells: cells) == nil)
}

private final class DashboardDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}
