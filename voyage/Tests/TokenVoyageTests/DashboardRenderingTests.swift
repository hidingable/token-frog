import AppKit
import Observation
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

@MainActor @Observable private final class DashboardTestSelection {
    var value = DashboardSelection()
}

@MainActor private final class DashboardBodyProbe {
    var evaluations = 0
}

private struct DashboardTestView: View {
    let model: AppModel
    let selection: DashboardTestSelection
    var probe: DashboardBodyProbe?

    var body: some View {
        if let probe {
            // Observe result delivery at the hosting root; delayed publications must settle before idle.
            let _ = model.dashboardStore.result?.request
            let _ = probe.evaluations += 1
        }
        DashboardTab(model: model, selection: Binding(
            get: { selection.value }, set: { selection.value = $0 }
        )).equatable()
    }
}

private final class RenderingDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@Suite @MainActor struct DashboardRenderingTests {
    private func model(directory: URL, isSnapshot: Bool = false) throws -> AppModel {
        let now = try #require(DayKey.date(from: "2026-11-06"))
        if !isSnapshot {
            let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
            store.load()
            let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-06", now: now, catalog: localizationCatalog)
            try store.save(journey)
            try store.save(CareState.legacy(from: journey, pets: localizationCatalog.pets))
        }
        let days = [("2026-10-01", 10), ("2026-11-01", 20), ("2026-11-06", 30)].map { date, input in
            DayDetail(date: date, rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: input))])
        }
        return AppModel(isSnapshot: isSnapshot, defaults: RenderingDefaults(), directory: directory,
                        catalog: localizationCatalog, themes: testThemes, now: { now },
                        usageReader: { since, until in
                            days.filter { $0.date <= until && (since == nil || $0.date >= since!) }
                        }, hoursReader: { _, _ in [] }, runtimeEnabled: false)
    }

    private func window(model: AppModel, selection: DashboardTestSelection, probe: DashboardBodyProbe? = nil) -> NSWindow {
        let host = NSHostingView(rootView: ScrollView {
            DashboardTestView(model: model, selection: selection, probe: probe).padding(12)
        }.localized(using: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func waitForResult(model: AppModel, selection: DashboardSelection) async throws -> DashboardPresentation {
        let expected = model.dashboardStore.request(selection: selection, seriesLimit: model.theme.series.count)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.dashboardStore.result?.request != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let result = try #require(model.dashboardStore.result)
        try #require(result.request == expected)
        return result
    }

    @Test func changingRangeDeliversMatchingContentWithoutTheMeasurementTool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-rendering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory: directory)
        await model.loadDashboard()
        #expect(!model.isSnapshotMode)
        #expect(!model.isLocked && model.lastError == nil)
        let selection = DashboardTestSelection()
        let window = window(model: model, selection: selection)
        defer { window.close() }

        let month = try await waitForResult(model: model, selection: selection.value)
        #expect(month.board.start == "2026-10-08")
        #expect(month.stats.totals.input == 50)

        selection.value.period = .today
        let today = try await waitForResult(model: model, selection: selection.value)
        #expect(today.board.start == "2026-11-06")
        #expect(today.board.end == "2026-11-06")
        #expect(today.stats.calendarDays == 1)
        #expect(today.stats.totals.input == 30)
        #expect(today.board.ledger.activeDays == 1)

        selection.value.period = .all
        let all = try await waitForResult(model: model, selection: selection.value)
        #expect(all.board.start == "2026-10-01")
        #expect(all.stats.totals.input == 60)
        #expect(all.board.ledger.activeDays == 3)
    }

    @Test func aMeasuredDashboardHasNoDeferredBodyEvaluationsDuringTenSecondsOfIdle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory: directory, isSnapshot: true)
        await model.loadDashboard()
        let selection = DashboardTestSelection()
        let probe = DashboardBodyProbe()
        let window = window(model: model, selection: selection, probe: probe)
        defer { window.close() }
        let frames = DashboardMeasurementFrames(hostingView: try #require(window.contentView)) {
            model.dashboardStore.result?.request == model.dashboardStore.request(selection: selection.value, seriesLimit: model.theme.series.count)
        }
        #expect(try await frames.drawFrame() == .drawn)
        selection.value.period = .today
        #expect(try await frames.drawFrame() == .drawn)
        #expect(model.dashboardStore.result?.stats.totals.input == 30)

        let before = probe.evaluations
        #expect(before > 0)
        try await Task.sleep(for: .seconds(10))
        #expect(probe.evaluations == before)
        #expect(model.dashboardStore.result?.stats.totals.input == 30)
    }
}
