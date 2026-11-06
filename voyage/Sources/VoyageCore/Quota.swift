import Foundation

/// A provider's subscription quota as reported by `tokscale usage --json`. Account identifiers are not decoded.
public struct ProviderQuota: Equatable, Sendable, Identifiable {
    public struct Metric: Equatable, Sendable, Identifiable {
        public var label: String
        public var remainingPercent: Double
        public var remainingLabel: String?
        public var resetsAt: String?
        public var id: String { label }
    }

    public var provider: String
    public var plan: String?
    public var metrics: [Metric]
    public var resetCredits: Int
    public var id: String { provider }
}

public enum QuotaReport {
    public enum ResetDescription: Equatable, Sendable {
        case soon
        case minutes(Int)
        case hours(Int)
        case daysHours(Int, Int)
        case date(String)
        case raw(String)
    }

    private struct Row: Decodable {
        struct RowMetric: Decodable {
            let label: String
            let remaining_percent: Double
            let remaining_label: String?
            let resets_at: String?
        }
        struct Credits: Decodable {
            let available_count: Int?
        }
        let provider: String
        let plan: String?
        let metrics: [RowMetric]?
        let reset_credits: Credits?
    }

    public static func parse(_ data: Data) throws -> [ProviderQuota] {
        try JSONDecoder().decode([Row].self, from: data).map { row in
            ProviderQuota(
                provider: row.provider,
                plan: row.plan,
                metrics: (row.metrics ?? []).map {
                    ProviderQuota.Metric(label: $0.label, remainingPercent: $0.remaining_percent, remainingLabel: $0.remaining_label, resetsAt: $0.resets_at)
                },
                resetCredits: row.reset_credits?.available_count ?? 0
            )
        }
    }

    /// `resets_at` is either a full timestamp or a plain date, depending on the provider.
    public static func resetDescription(_ value: String, now: Date, calendar: Calendar = .current) -> ResetDescription {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = ISO8601DateFormatter().date(from: value) ?? fractional.date(from: value) {
            let minutes = Int(date.timeIntervalSince(now) / 60)
            if minutes <= 0 { return .soon }
            if minutes < 60 { return .minutes(minutes) }
            if minutes < 1440 { return .hours(minutes / 60) }
            return .daysHours(minutes / 1440, minutes % 1440 / 60)
        }
        return DayKey.date(from: value, calendar: calendar) == nil ? .raw(value) : .date(value)
    }
}
