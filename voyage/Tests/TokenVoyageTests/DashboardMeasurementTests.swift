import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private final class MeasurementDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes = 0
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) { writes += 1 }
}

@MainActor @Observable private final class MeasurementColor {
    var isRed = false
}

private struct MeasurementColorView: View {
    let color: MeasurementColor
    var body: some View {
        Rectangle().fill(Color(red: color.isRed ? 1 : 0, green: 0, blue: color.isRed ? 0 : 1))
    }
}

@MainActor private final class MeasurementHostingView: NSHostingView<MeasurementColorView> {
    var bitmap: NSBitmapImageRep?
    var keepLayoutPending = false

    override var needsLayout: Bool {
        get { keepLayoutPending || super.needsLayout }
        set { super.needsLayout = newValue }
    }

    override func cacheDisplay(in rect: NSRect, to bitmap: NSBitmapImageRep) {
        super.cacheDisplay(in: rect, to: bitmap)
        self.bitmap = bitmap
    }
}

@MainActor private final class MeasurementPassClock {
    private(set) var instant = ContinuousClock.now
    private(set) var passes = 0

    func waitForNextPass() async {
        await Task.yield()
        passes += 1
        instant = instant.advanced(by: .milliseconds(1))
    }
}

@Suite(.serialized) @MainActor struct DashboardMeasurementTests {
    @Test func anUnstableViewTimesOutAndTheNextFrameStillDraws() async throws {
        let host = MeasurementHostingView(rootView: MeasurementColorView(color: MeasurementColor()))
        host.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let clock = MeasurementPassClock()
        let frames = DashboardMeasurementFrames(hostingView: host, now: { clock.instant },
                                                waitForNextPass: { await clock.waitForNextPass() })
        host.keepLayoutPending = true
        #expect(try await frames.drawFrame(timeout: .milliseconds(3)) == .timeout)
        #expect(clock.passes == 3)
        #expect(host.bitmap == nil)

        host.keepLayoutPending = false
        #expect(try await frames.drawFrame() == .drawn)
        #expect(host.bitmap != nil)
    }

    @Test func frameWaitLetsPendingMainActorWorkFinishBeforeDrawing() async throws {
        let color = MeasurementColor()
        let host = MeasurementHostingView(rootView: MeasurementColorView(color: color))
        host.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let update = Task { @MainActor in color.isRed = true }
        let frames = DashboardMeasurementFrames(hostingView: host) { color.isRed }

        #expect(try await frames.drawFrame() == .drawn)
        #expect(color.isRed)
        await update.value
    }

    @Test func argumentsRequireIsolationAndAPositiveSyntheticDayCount() throws {
        let mode = ["app", "--measure-dashboard"]
        #expect(try DashboardMeasurementOptions.parse(arguments: ["app"], dataDirectory: nil) == nil)
        for directory in [nil, ""] as [String?] {
            #expect(throws: DashboardMeasurementError.self) {
                try DashboardMeasurementOptions.parse(arguments: mode, dataDirectory: directory)
            }
        }
        let options = try #require(try DashboardMeasurementOptions.parse(arguments: mode, dataDirectory: "/unused"))
        #expect(options.directory.path == "/unused")
        #expect(options.syntheticDays == nil)
        let synthetic = try #require(try DashboardMeasurementOptions.parse(arguments: mode + ["--synthetic-days", "730"], dataDirectory: "/unused"))
        #expect(synthetic.syntheticDays == 730)
        for suffix in [["--synthetic-days"], ["--synthetic-days", "0"], ["--synthetic-days", "-1"],
                       ["--synthetic-days", "1.5"], ["--synthetic-days", "--snapshot"], ["--snapshot", "out"]] {
            #expect(throws: DashboardMeasurementError.self) {
                try DashboardMeasurementOptions.parse(arguments: mode + suffix, dataDirectory: "/unused")
            }
        }
    }

    @Test func syntheticHistoryCoversEveryDayAndNineToolModelPairsWithMatchingHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        let data = try DashboardSyntheticData(count: 370, now: now, calendar: calendar)
        #expect(data.days.count == 370)
        #expect(data.days.last?.date == "2026-11-06")
        #expect(Set(data.days.map(\.date)).count == 370)
        #expect(data.days.map(\.date) == data.days.map(\.date).sorted())
        for day in data.days {
            #expect(day.rows.count == 9)
            let tools = Dictionary(grouping: day.rows, by: \.client)
            #expect(Set(tools.keys) == ["codex", "claude", "gemini"])
            #expect(tools.values.allSatisfy { Set($0.map(\.model)).count == 3 })
            #expect(day.rows.allSatisfy { $0.tokens.total > 0 && $0.tokens.cost > 0 && $0.tokens.messages > 0 })
        }
        #expect(data.hours.count == 30 * 24)
        for day in data.days.suffix(30) {
            let hours = data.hours.filter { $0.date == day.date }
            #expect(Set(hours.map(\.hour)) == Set(0..<24))
            let daily = day.rows.reduce(UsageTotals()) { $0 + $1.tokens }
            let hourly = hours.reduce(UsageTotals()) { $0 + $1.tokens }
            #expect(daily.total == hourly.total)
            #expect(daily.messages == hourly.messages)
            #expect(abs(daily.cost - hourly.cost) < 0.000_001)
        }
    }

    @Test func measurementModelLoadsSyntheticDataWithoutReadingOrWritingSavesOrSettings() async throws {
        let directory = LocalizationTestFiles.root.appendingPathComponent(".build/measurement-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("journey.json")
        let bytes = Data("This is a synthetic sentinel, not a valid save.".utf8)
        try bytes.write(to: sentinel)
        let defaults = MeasurementDefaults()
        let now = Date()
        let model = try DashboardMeasurement.makeModel(
            options: .init(directory: directory, syntheticDays: 35), now: now,
            contentDirectory: LocalizationTestFiles.root.appendingPathComponent("Content"), defaults: defaults
        )
        #expect(model.isSnapshotMode && !model.isLocked)
        model.start()
        await model.scan()
        await model.loadDashboard()
        await model.loadQuotas(force: true)
        let expected = try DashboardSyntheticData(count: 35, now: now)
        #expect(model.dashboardDays == expected.days)
        #expect(model.dashboardHours.count == 30 * 24)
        #expect(model.lastError == nil)
        #expect(model.quotas.isEmpty)
        #expect(model.lastScan == now)
        #expect(model.todayTotals == UsageLedger(days: [expected.days.last!]).totals)
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["journey.json"])
        #expect(defaults.writes == 0)
    }

    @Test func resultLinesHaveStableFieldsAndPOSIXDecimals() {
        var sample = DashboardMeasurementCounters.Sample()
        sample.add(milliseconds: 2)
        sample.add(milliseconds: 6)
        #expect(DashboardMeasurement.line("range.month", sample) == "MEASURE range.month count=2 avg_ms=4.000 max_ms=6.000 total_ms=8.000")
        #expect(DashboardMeasurement.line("idle", .init(), extra: " body_evaluations=0") == "MEASURE idle count=0 avg_ms=0.000 max_ms=0.000 total_ms=0.000 body_evaluations=0")
    }

    @Test func countersRemainDormantInTheNormalTestProcess() {
        #expect(!DashboardMeasurementCounters.enabled)
        #expect(DashboardMeasurementCounters.start() == nil)
        DashboardMeasurementCounters.record(.l10n)
        DashboardMeasurementCounters.record(.dateFormatter)
        #expect(DashboardMeasurementCounters.snapshot().isEmpty)
    }
}
