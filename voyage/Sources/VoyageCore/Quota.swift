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

    /// The tightest window among the tools used today. Quotas of tools you are not using stay out of the notch.
    public static func tightest(_ quotas: [ProviderQuota], usedClients: some Collection<String>) -> (provider: String, metric: ProviderQuota.Metric)? {
        let used = Set(usedClients.map { $0.lowercased() })
        return quotas
            .filter { used.contains($0.provider.lowercased()) }
            .flatMap { quota in quota.metrics.map { (provider: quota.provider, metric: $0) } }
            .min { $0.metric.remainingPercent < $1.metric.remainingPercent }
    }

    public static func metricName(_ label: String) -> String {
        [
            "Weekly": "每周", "Daily": "每日", "Monthly": "每月", "Session": "当前会话",
            "Chat": "聊天", "Completions": "补全", "Premium": "高级请求",
        ][label] ?? label
    }

    /// `resets_at` is either a full timestamp or a plain date, depending on the provider.
    public static func resetDescription(_ value: String, now: Date, calendar: Calendar = .current) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = ISO8601DateFormatter().date(from: value) ?? fractional.date(from: value) {
            let minutes = Int(date.timeIntervalSince(now) / 60)
            if minutes <= 0 { return "即将重置" }
            if minutes < 60 { return "\(minutes) 分钟后重置" }
            if minutes < 1440 { return "\(minutes / 60) 小时后重置" }
            return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时后重置"
        }
        return DayKey.date(from: value, calendar: calendar) == nil ? value : "\(value) 重置"
    }
}
