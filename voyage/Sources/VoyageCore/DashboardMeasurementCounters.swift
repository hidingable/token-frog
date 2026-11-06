import Dispatch
import Foundation
import os

/// Dormant outside the measurement process: no clock reads or locks on the normal path.
public enum DashboardMeasurementCounters {
    public static let enabled = ProcessInfo.processInfo.arguments.contains("--measure-dashboard")

    public enum Event: String, CaseIterable, Sendable {
        case usageDashboardInit = "UsageDashboard.init"
        case dashboardContent = "DashboardTab.content"
        case body = "dashboard.body"
        case l10n = "L10n.callAsFunction"
        case dateFormatter = "DateFormatter.init"
    }

    public struct Sample: Sendable {
        public private(set) var count = 0
        public private(set) var totalMilliseconds = 0.0
        public private(set) var maxMilliseconds = 0.0
        public var averageMilliseconds: Double { count == 0 ? 0 : totalMilliseconds / Double(count) }

        public init() {}

        public mutating func add(milliseconds: Double) {
            count += 1
            totalMilliseconds += milliseconds
            maxMilliseconds = max(maxMilliseconds, milliseconds)
        }
    }

    private static let samples = OSAllocatedUnfairLock(initialState: [Event: Sample]())

    public static func start() -> UInt64? {
        enabled ? DispatchTime.now().uptimeNanoseconds : nil
    }

    public static func record(_ event: Event, since start: UInt64? = nil) {
        guard enabled else { return }
        let milliseconds = start.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 } ?? 0
        samples.withLock { $0[event, default: Sample()].add(milliseconds: milliseconds) }
    }

    public static func snapshot() -> [Event: Sample] { samples.withLock { $0 } }

    /// Excludes data loading and fixture construction from the dashboard's cumulative counts.
    public static func reset() { samples.withLock { $0.removeAll(keepingCapacity: true) } }
}
