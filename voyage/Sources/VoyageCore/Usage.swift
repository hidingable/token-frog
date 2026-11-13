import Foundation

/// All token kinds count toward mileage. Return travel will use its own rate.
public let outboundTokensPerKm = 1_000_000
public let returnTokensPerKm = 100_000
let legacyTokensPerKm = 10_000

public struct DayUsage: Equatable, Sendable {
    public var date: String
    public var fuel: Int
    public var byClient: [String: Int]
    /// All tokens observed by the scanner, including cache reads and reasoning; the mileage basis.
    public var observedTokens: Int
    public var usedToolIDs: [String]

    public init(date: String, fuel: Int = 0, byClient: [String: Int] = [:], observedTokens: Int? = nil, usedToolIDs: [String]? = nil) {
        self.date = date
        self.fuel = fuel
        self.byClient = byClient
        self.observedTokens = observedTokens ?? fuel
        self.usedToolIDs = usedToolIDs ?? byClient.filter { $0.value > 0 }.keys.sorted()
    }
}

/// One tokscale row: a tool and model on one day.
public struct UsageRow: Codable, Equatable, Sendable {
    public var client: String
    public var model: String
    public var tokens: UsageTotals

    public init(client: String, model: String, tokens: UsageTotals) {
        self.client = client
        self.model = model
        self.tokens = tokens
    }
}

public struct UsageTotals: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var reasoning = 0
    public var cost = 0.0
    public var messages = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.cost = cost
        self.messages = messages
    }

    /// Same definition as tokscale's own total, including cache reads and reasoning.
    public var total: Int { input + output + cacheRead + cacheWrite + reasoning }
    /// Legacy uncached subtotal, retained for tool shares and usage events.
    public var fuel: Int { input + output + cacheWrite }
    /// Share of prompt tokens served from cache, counting cache writes as misses like Token Monitor; nil without input.
    public var cacheHitPercent: Double? {
        let all = input + cacheRead + cacheWrite
        return all > 0 ? Double(cacheRead) / Double(all) * 100 : nil
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite, reasoning: lhs.reasoning + rhs.reasoning,
            cost: lhs.cost + rhs.cost, messages: lhs.messages + rhs.messages
        )
    }
}

public struct DayDetail: Codable, Equatable, Sendable {
    public var date: String
    public var rows: [UsageRow]
    /// Session time summed across parallel sessions, so a day can exceed 24 hours. tokscale does not split it per tool.
    public var activeMs: Int

    public init(date: String, rows: [UsageRow], activeMs: Int = 0) {
        self.date = date
        self.rows = rows
        self.activeMs = activeMs
    }

    public var usage: DayUsage {
        var byClient: [String: Int] = [:]
        for row in rows where row.tokens.fuel > 0 {
            byClient[row.client, default: 0] += row.tokens.fuel
        }
        return DayUsage(date: date, fuel: byClient.values.reduce(0, +), byClient: byClient,
                        observedTokens: rows.reduce(0) { $0 + $1.tokens.total },
                        usedToolIDs: Set(rows.filter { $0.tokens.total > 0 || $0.tokens.messages > 0 || $0.tokens.cost > 0 }.map(\.client)).sorted())
    }
}

/// Display-only totals for a date range. Never feeds the journey.
public struct UsageLedger: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var name: String
        public var tokens: UsageTotals
        public var id: String { name }
    }

    public var totals = UsageTotals()
    public var activeDays = 0
    public var byClient: [Entry] = []
    public var byModel: [Entry] = []

    public init(days: [DayDetail]) {
        var clients: [String: UsageTotals] = [:]
        var models: [String: UsageTotals] = [:]
        for day in days {
            let rows = day.rows.filter { $0.tokens.total > 0 || $0.tokens.cost > 0 || $0.tokens.messages > 0 }
            if !rows.isEmpty { activeDays += 1 }
            for row in rows {
                totals = totals + row.tokens
                clients[row.client] = (clients[row.client] ?? UsageTotals()) + row.tokens
                models[row.model] = (models[row.model] ?? UsageTotals()) + row.tokens
            }
        }
        byClient = Self.ranked(clients)
        byModel = Self.ranked(models)
    }

    private static func ranked(_ groups: [String: UsageTotals]) -> [Entry] {
        groups.map { Entry(name: $0.key, tokens: $0.value) }.sorted {
            $0.tokens.total == $1.tokens.total ? $0.name < $1.name : $0.tokens.total > $1.tokens.total
        }
    }
}

public enum TokscaleGraph {
    public static let unknownModel = "\u{0}voyage.unknownModel"

    private struct Graph: Decodable {
        let contributions: [Contribution]
    }

    private struct Contribution: Decodable {
        let date: String
        let clients: [ClientRow]
        let activeTimeMs: Int?
    }

    private struct ClientRow: Decodable {
        let client: String
        let modelId: String?
        let tokens: Tokens
        let cost: Double?
        let messages: Int?
    }

    private struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let reasoning: Int?
    }

    public static func parseDetails(_ data: Data) throws -> [DayDetail] {
        let graph = try JSONDecoder().decode(Graph.self, from: data)
        return graph.contributions.map { day in
            DayDetail(date: day.date, rows: day.clients.map { row in
                UsageRow(
                    client: row.client,
                    model: row.modelId ?? unknownModel,
                    tokens: UsageTotals(
                        input: row.tokens.input ?? 0, output: row.tokens.output ?? 0, cacheRead: row.tokens.cacheRead ?? 0,
                        cacheWrite: row.tokens.cacheWrite ?? 0, reasoning: row.tokens.reasoning ?? 0,
                        cost: row.cost ?? 0, messages: row.messages ?? 0
                    )
                )
            }, activeMs: day.activeTimeMs ?? 0)
        }
    }

    /// Fuel is uncached input + output + cache writes. Cache reads and reasoning are deliberately excluded.
    public static func parse(_ data: Data) throws -> [DayUsage] {
        try parseDetails(data).map(\.usage)
    }
}

public enum DayKey {
    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month: Int
        if calendar.identifier == .hebrew {
            // ICU numbers Hebrew months by their position in this year; Calendar.month always reserves Adar I.
            let first = calendar.date(from: DateComponents(year: parts.year, month: 1, day: 1))!
            month = calendar.dateComponents([.month], from: first, to: date).month! + 1
        } else {
            month = parts.month!
        }
        return padded(parts.year!, width: 4) + "-" + padded(month, width: 2) + "-" + padded(parts.day!, width: 2)
    }

    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        var values = [0, 0, 0]
        for index in bytes.indices where index != 4 && index != 7 {
            let byte = bytes[index]
            guard (48...57).contains(byte) else { return nil }
            let component = index < 4 ? 0 : (index < 7 ? 1 : 2)
            values[component] = values[component] * 10 + Int(byte - 48)
        }
        guard values[0] > 0, (1...13).contains(values[1]), (1...31).contains(values[2]) else { return nil }
        let month: Int
        if calendar.identifier == .hebrew {
            guard let first = calendar.date(from: DateComponents(year: values[0], month: 1, day: 1)),
                  let monthStart = calendar.date(byAdding: .month, value: values[1] - 1, to: first),
                  calendar.component(.year, from: monthStart) == values[0] else { return nil }
            month = calendar.component(.month, from: monthStart)
        } else {
            month = values[1]
        }
        guard let date = calendar.date(from: DateComponents(year: values[0], month: month, day: values[2])) else { return nil }
        // Calendar normalizes impossible dates (and whole days skipped by a time zone).
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == values[0], parts.month == month, parts.day == values[2] else { return nil }
        return date
    }

    /// Consecutive local days, including 23/25-hour DST days and a date-line change that skips a whole day.
    public static func ordinal(from date: Date, calendar: Calendar = .current) -> Int {
        Int((calendar.startOfDay(for: date).timeIntervalSince(epoch(calendar)) / 86_400).rounded())
    }

    public static func ordinal(from key: String, calendar: Calendar = .current) -> Int? {
        date(from: key, calendar: calendar).map { ordinal(from: $0, calendar: calendar) }
    }

    public static func date(forOrdinal ordinal: Int, calendar: Calendar = .current) -> Date {
        // A noon probe stays inside the local day when its midnight shifts at a DST transition.
        calendar.startOfDay(for: epoch(calendar).addingTimeInterval(Double(ordinal) * 86_400 + 43_200))
    }

    public static func string(forOrdinal ordinal: Int, calendar: Calendar = .current) -> String {
        string(from: date(forOrdinal: ordinal, calendar: calendar), calendar: calendar)
    }

    private static func epoch(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    public static func next(_ key: String, calendar: Calendar = .current) -> String {
        guard let date = date(from: key, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: date) else {
            preconditionFailure("Invalid day key \(key)")
        }
        return string(from: next, calendar: calendar)
    }
}

public enum Format {
    public static func tokens(_ value: Int, language: Language) -> String {
        switch language {
        case .zhHans:
            if value >= 100_000_000 { return String(format: "%.1f \u{4EBF}", Double(value) / 100_000_000) }
            if value >= 10_000 { return "\(grouped(Int((Double(value) / 10_000).rounded()))) \u{4E07}" }
        case .en:
            if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
            if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
            if value >= 10_000 { return "\(Int((Double(value) / 1_000).rounded()))K" }
        }
        return grouped(value)
    }

    public static func km(_ value: Double) -> String {
        "\(grouped(Int(value.rounded()))) km"
    }

    public static func cost(_ value: Double) -> String {
        if value >= 1000 { return "$\(grouped(Int(value.rounded())))" }
        return String(format: "$%.2f", value)
    }

    public static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "-"
    }

    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

public enum Vehicle {
    private static let names: [String: String] = [
        "claude": "Claude", "codex": "Codex", "gemini": "Gemini", "cursor": "Cursor", "opencode": "OpenCode",
        "copilot": "Copilot", "hermes": "Hermes", "kimi": "Kimi", "pi": "Pi", "qwen": "Qwen",
        "antigravity": "Antigravity", "antigravity-extension": "Antigravity", "antigravity-cli": "Antigravity",
        "workbuddy": "WorkBuddy", "codebuddy": "CodeBuddy", "openclaw": "OpenClaw", "droid": "Droid",
        "goose": "Goose", "zed": "Zed", "cline": "Cline", "amp": "Amp",
    ]

    public static func toolName(_ client: String) -> String {
        names[normalizeClientID(client)] ?? client.capitalized
    }
}
