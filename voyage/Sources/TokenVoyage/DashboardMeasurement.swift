import AppKit
import Observation
import SwiftUI
import VoyageCore

struct DashboardMeasurementOptions {
    let directory: URL
    let syntheticDays: Int?

    static func parse(arguments: [String], dataDirectory: String?) throws -> Self? {
        guard arguments.contains("--measure-dashboard") else { return nil }
        guard !arguments.contains("--snapshot") else {
            throw DashboardMeasurementError.invalidArguments("Use --measure-dashboard separately from --snapshot.")
        }
        guard let dataDirectory, !dataDirectory.isEmpty else {
            throw DashboardMeasurementError.invalidArguments("--measure-dashboard requires TOKEN_VOYAGE_DATA_DIR (no saves are read or written).")
        }
        var days: Int?
        if let index = arguments.firstIndex(of: "--synthetic-days") {
            guard arguments.count > index + 1, let value = Int(arguments[index + 1]), value > 0 else {
                throw DashboardMeasurementError.invalidArguments("--synthetic-days requires a positive integer.")
            }
            days = value
        }
        return Self(directory: URL(fileURLWithPath: dataDirectory), syntheticDays: days)
    }
}

enum DashboardMeasurementError: Error, CustomStringConvertible {
    case invalidArguments(String), unavailable(String)

    var description: String {
        switch self {
        case .invalidArguments(let message), .unavailable(let message): message
        }
    }
}

/// Deterministic daily rows and matching hourly totals, all held in memory.
struct DashboardSyntheticData: Sendable {
    let days: [DayDetail]
    let hours: [HourUsage]

    init(count: Int, now: Date, calendar: Calendar = .current) throws {
        guard count > 0 else { throw DashboardMeasurementError.invalidArguments("Synthetic day count must be positive.") }
        var days: [DayDetail] = []
        var hours: [HourUsage] = []
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else {
                throw DashboardMeasurementError.invalidArguments("Synthetic date range is out of bounds.")
            }
            let key = DayKey.string(from: date, calendar: calendar)
            let rows = ["codex", "claude", "gemini"].enumerated().flatMap { tool, client in
                (1...3).map { model in
                    let scale = (offset % 17 + 1) * (tool + 1) * model
                    return UsageRow(client: client, model: "\(client)-model-\(model)", tokens: UsageTotals(
                        input: scale * 240, output: scale * 120, cacheRead: scale * 480,
                        cacheWrite: scale * 24, reasoning: scale * 24,
                        cost: Double(scale) * 0.024, messages: scale * 24
                    ))
                }
            }
            days.append(DayDetail(date: key, rows: rows, activeMs: (offset % 8 + 1) * 3_600_000))
            // The real loader reads only today's and the last 30 days' hourly data.
            if offset < 30 {
                let total = rows.reduce(UsageTotals()) { $0 + $1.tokens }
                hours += (0..<24).map { hour in
                    HourUsage(date: key, hour: hour, tokens: UsageTotals(
                        input: total.input / 24, output: total.output / 24,
                        cacheRead: total.cacheRead / 24, cacheWrite: total.cacheWrite / 24,
                        reasoning: total.reasoning / 24, cost: total.cost / 24, messages: total.messages / 24
                    ))
                }
            }
        }
        self.days = days.reversed()
        self.hours = hours.reversed()
    }
}

@MainActor
@Observable
private final class MeasuredDashboardSelection {
    var value = DashboardSelection()
}

/// An ordinary MainView window; never starts the app's persistent runtime.
@MainActor
enum DashboardMeasurement {
    static func makeModel(options: DashboardMeasurementOptions, now: Date = Date(),
                          contentDirectory: URL? = nil, defaults: UserDefaults = .standard) throws -> AppModel {
        let bundledContent = Bundle.main.resourceURL!.appendingPathComponent("Content")
        let content = contentDirectory ?? (FileManager.default.fileExists(atPath: bundledContent.path)
            ? bundledContent : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Content"))
        if let count = options.syntheticDays {
            let data = try DashboardSyntheticData(count: count, now: now)
            return AppModel(isSnapshot: true, defaults: defaults, directory: options.directory, contentDirectory: content,
                            now: { now }, usageReader: { since, until in
                                data.days.filter { $0.date <= until && (since == nil || $0.date >= since!) }
                            }, hoursReader: { since, until in
                                data.hours.filter { $0.date >= since && $0.date <= until }
                            }, runtimeEnabled: false)
        }
        return AppModel(isSnapshot: true, defaults: defaults, directory: options.directory, contentDirectory: content,
                        now: { now }, runtimeEnabled: false)
    }

    static func run(model: AppModel) async throws {
        // Match the snapshot path and wait for both daily and hourly reads before creating the view.
        await model.scan()
        await model.loadDashboard()
        guard !model.isLocked, model.dashboardDays != nil, model.lastError == nil else {
            throw DashboardMeasurementError.unavailable("Dashboard data could not be loaded; no measurements were recorded.")
        }
        model.navigate(to: .data)
        model.dataTab = .dashboard
        let selection = MeasuredDashboardSelection()
        let tools = Array(Set(model.dashboardDays!.flatMap { $0.rows.map(\.client) })).sorted()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Dashboard measurement"
        window.applyTheme(model.theme)
        window.center()

        DashboardMeasurementCounters.reset()
        let firstStart = DispatchTime.now().uptimeNanoseconds
        let host = NSHostingView(rootView: MainView(model: model, measuredDashboard: Binding(
            get: { selection.value }, set: { selection.value = $0 }
        )).localized(using: model))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let frames = DashboardMeasurementFrames(hostingView: host) {
            model.dashboardStore.result?.request == model.dashboardStore.request(selection: selection.value, seriesLimit: model.theme.series.count)
        }
        defer { window.close() }
        func draw(_ name: String) async throws -> Bool {
            let outcome = try await frames.drawFrame()
            guard outcome == .drawn else {
                report(name, .init(), extra: " status=\(outcome.rawValue)")
                return false
            }
            return true
        }
        var first = DashboardMeasurementCounters.Sample()
        if try await draw("first_display") { first.add(milliseconds: elapsed(since: firstStart)) }
        report("first_display", first)

        let sampleOrder = DashboardPeriod.allCases.map { "range.\($0.rawValue)" }
            + DashboardMetric.allCases.map { "metric.\($0.rawValue)" }
            + ["filter.tool", "filter.clear", "detail.tools", "detail.models", "scroll"]
        var samples: [String: DashboardMeasurementCounters.Sample] = [:]
        func measure(_ name: String, action: () -> Void) async throws {
            let start = DispatchTime.now().uptimeNanoseconds
            action()
            if try await draw(name) { samples[name, default: .init()].add(milliseconds: elapsed(since: start)) }
        }

        // Alternate periods so every sample changes the selection, including all five month samples.
        for _ in 0..<5 {
            for period in DashboardPeriod.allCases {
                try await measure("range.\(period.rawValue)") {
                    selection.value.period = period
                    selection.value.day = nil
                }
            }
        }
        for metric in DashboardMetric.allCases {
            // Total is already selected initially; prime a different metric outside its sample.
            if selection.value.metric == metric {
                selection.value.metric = .messages
                _ = try await draw("metric.prime")
            }
            try await measure("metric.\(metric.rawValue)") { selection.value.metric = metric }
        }
        for tool in tools {
            try await measure("filter.tool") { selection.value.client = tool }
        }
        if !tools.isEmpty {
            try await measure("filter.clear") { selection.value.client = nil }
        }
        // Exercise both detail modes, starting from the opposite state so neither is a no-op.
        selection.value.showModels = true
        _ = try await draw("detail.prime")
        try await measure("detail.tools") { selection.value.showModels = false }
        try await measure("detail.models") { selection.value.showModels = true }

        if let scroll = scrollView(in: host), let document = scroll.documentView {
            let low = document.bounds.minY
            let high = max(low, document.bounds.maxY - scroll.contentView.bounds.height)
            let top = document.isFlipped ? low : high
            let bottom = document.isFlipped ? high : low
            func scrollTo(_ y: CGFloat) {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            scrollTo(top)
            _ = try await draw("scroll.prime")
            for step in 1...60 {
                try await measure("scroll") { scrollTo(top + (bottom - top) * CGFloat(step) / 60) }
            }
        } else {
            report("scroll", .init(), extra: " status=unavailable")
        }

        for name in sampleOrder { report(name, samples[name] ?? .init()) }

        // No measurement-driven drawing during idle; observe only the actual SwiftUI bodies.
        let bodiesBefore = DashboardMeasurementCounters.snapshot()[.body]?.count ?? 0
        let idleStart = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(for: .seconds(10))
        let bodiesAfter = DashboardMeasurementCounters.snapshot()[.body]?.count ?? 0
        var idle = DashboardMeasurementCounters.Sample()
        idle.add(milliseconds: elapsed(since: idleStart))
        report("idle", idle, extra: " body_evaluations=\(bodiesAfter - bodiesBefore)")
        for event in DashboardMeasurementCounters.Event.allCases {
            report("counter.\(event.rawValue)", DashboardMeasurementCounters.snapshot()[event] ?? .init())
        }
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func line(_ name: String, _ sample: DashboardMeasurementCounters.Sample, extra: String = "") -> String {
        String(format: "MEASURE %@ count=%d avg_ms=%.3f max_ms=%.3f total_ms=%.3f%@",
               locale: Locale(identifier: "en_US_POSIX"), name, sample.count,
               sample.averageMilliseconds, sample.maxMilliseconds, sample.totalMilliseconds, extra)
    }

    private static func report(_ name: String, _ sample: DashboardMeasurementCounters.Sample, extra: String = "") {
        FileHandle.standardOutput.write(Data((line(name, sample, extra: extra) + "\n").utf8))
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}

/// Draws offscreen after SwiftUI settles, without waiting for a screen refresh.
@MainActor
final class DashboardMeasurementFrames {
    enum Outcome: String { case drawn, timeout, unavailable }

    private let hostingView: NSView
    private let contentReady: () -> Bool

    init(hostingView: NSView, contentReady: @escaping () -> Bool = { true }) {
        self.hostingView = hostingView
        self.contentReady = contentReady
    }

    func drawFrame(timeout: Duration = .seconds(2)) async throws -> Outcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var previousBodies = DashboardMeasurementCounters.snapshot()[.body]?.count ?? 0
        var stablePasses = 0
        repeat {
            // The store publishes on MainActor. A nested RunLoop cannot let that queued work resume.
            try await Task.sleep(for: .milliseconds(1))
            let neededLayout = needsLayout(in: hostingView)
            hostingView.layoutSubtreeIfNeeded()
            let bodies = DashboardMeasurementCounters.snapshot()[.body]?.count ?? 0
            if contentReady() && !neededLayout && !needsLayout(in: hostingView) && bodies == previousBodies {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            previousBodies = bodies
        } while stablePasses < 2 && ContinuousClock.now < deadline

        guard stablePasses >= 2, ContinuousClock.now <= deadline else { return .timeout }
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return .unavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return .drawn
    }

    private func needsLayout(in view: NSView) -> Bool {
        view.needsLayout || view.needsUpdateConstraints || view.subviews.contains { needsLayout(in: $0) }
    }
}
