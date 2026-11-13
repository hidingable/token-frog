import Foundation
import VoyageCore

/// Disposable display input, deliberately separate from SaveStore and its archive.
struct DashboardDiskSnapshot: Codable, Sendable {
    var version = 1
    let days: [DayDetail]
    let monthHours: [HourUsage]
    let todayHours: [HourUsage]
    let updatedAt: Date
    let historyReadAt: Date?
    let todayHoursReadAt: Date?
    let monthHoursReadAt: Date?
}

final class DashboardDiskCache: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "voyage.dashboard-cache", qos: .utility)

    init(directory: URL) { url = directory.appendingPathComponent("dashboard-cache.json") }

    /// Only used during startup, before any readers or background writes can begin.
    func load() -> DashboardDiskSnapshot? {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let value = try JSONDecoder().decode(DashboardDiskSnapshot.self, from: Data(contentsOf: url))
                guard value.version == 1,
                      value.days.allSatisfy({ DayKey.date(from: $0.date) != nil }),
                      (value.monthHours + value.todayHours).allSatisfy({ DayKey.date(from: $0.date) != nil && (0..<24).contains($0.hour) })
                else { throw CocoaError(.coderReadCorrupt) }
                return value
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
    }

    func write(_ value: DashboardDiskSnapshot) {
        queue.async { [url] in
            // Failure leaves the last cache usable; a cache never locks or changes the save.
            try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
            if let data = try? JSONEncoder().encode(value) { try? PrivateStorage.write(data, to: url) }
        }
    }

    func clear() {
        // FIFO with writes, so an older pending write cannot resurrect a reset cache.
        queue.async { [url] in try? FileManager.default.removeItem(at: url) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
