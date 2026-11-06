import Foundation
import SwiftUI
import VoyageCore

struct L10n: Sendable {
    typealias Lookup = @Sendable (Language, String) -> String?
    let language: Language
    private let lookup: Lookup
    var locale: Locale { Locale(identifier: language.rawValue) }

    init(language: Language, lookup: @escaping Lookup = L10n.bundleLookup) {
        self.language = language
        self.lookup = lookup
    }

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let order = [language, .en, .zhHans]
        let template = order.lazy.compactMap { lookup($0, key) }.first { !$0.isEmpty } ?? key
        return arguments.isEmpty ? template : String(format: template, locale: locale, arguments: arguments)
    }

    func cityName(_ city: City) -> String {
        [language.rawValue, "en", "zh-Hans"].lazy.compactMap { city.names[$0] }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? self("city.unknown")
    }

    func countryName(_ names: [String: String]?) -> String {
        [language.rawValue, "en", "zh-Hans"].lazy.compactMap { names?[$0] }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? self("country.unknown")
    }

    static func bundleLookup(_ language: Language, _ key: String) -> String? {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let missing = "\u{0}missing.translation"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing || value.isEmpty ? nil : value
    }

    // Every key selected at runtime is explicit, so catalog tests can verify the whole table.
    static let tabKeys: [MainTab: String] = [.journey: "nav.journey", .mail: "nav.mail", .passport: "nav.passport", .dashboard: "nav.dashboard", .quota: "nav.quota"]
    static let periodKeys: [DashboardPeriod: String] = [.today: "period.today", .week: "period.week", .month: "period.month", .quarter: "period.quarter", .year: "period.year", .all: "period.all"]
    static let metricKeys: [DashboardMetric: String] = [.total: "metric.total", .fuel: "metric.fuel", .cost: "metric.cost", .messages: "metric.messages"]
    static let quotaKeys = ["Weekly": "quota.weekly", "Daily": "quota.daily", "Monthly": "quota.monthly", "Session": "quota.session", "Chat": "quota.chat", "Completions": "quota.completions", "Premium": "quota.premium"]
    static let languageKeys: [LanguagePreference: String] = [.system: "language.system", .zhHans: "language.zhHans", .en: "language.en"]
    static let countKeys = ["tokens": ["tokens.one", "tokens.other"], "days": ["days.one", "days.other"], "hours": ["hours.one", "hours.other"], "minutes": ["minutes.one", "minutes.other"]]
    static var dynamicKeys: [String] {
        Array(tabKeys.values) + Array(periodKeys.values) + Array(metricKeys.values) + Array(quotaKeys.values) + Array(languageKeys.values) + countKeys.values.flatMap { $0 } + LetterComposer.quirkKeys.values.flatMap { $0 }
    }

    func tab(_ tab: MainTab) -> String { self(Self.tabKeys[tab]!) }
    func period(_ period: DashboardPeriod) -> String { self(Self.periodKeys[period]!) }
    func metric(_ metric: DashboardMetric) -> String { self(Self.metricKeys[metric]!) }
    func quotaMetric(_ label: String) -> String { Self.quotaKeys[label].map { self($0) } ?? label }
    func modelName(_ name: String) -> String { name == TokscaleGraph.unknownModel ? self("usage.unknownModel") : name }
    func series(_ name: String) -> String { name == UsageDashboard.otherSeries ? self("usage.other") : Vehicle.toolName(name) }
    func vehicle(_ client: String) -> String { self("vehicle.name", Vehicle.toolName(client)) }
    private func counted(_ kind: String, _ value: Int, display: String? = nil) -> String {
        self(Self.countKeys[kind]![value == 1 ? 0 : 1], display ?? Format.grouped(value))
    }
    func tokens(_ value: Int) -> String { counted("tokens", value, display: Format.tokens(value, language: language)) }
    func days(_ value: Int) -> String { counted("days", value) }
    func hours(_ value: Int) -> String { counted("hours", value) }
    func minutes(_ value: Int) -> String { counted("minutes", value) }
    func decimal(_ value: Double, places: Int) -> String { String(format: "%.*f", locale: locale, places, value) }

    func reset(_ reset: QuotaReport.ResetDescription) -> String {
        switch reset {
        case .soon: self("reset.soon")
        case .minutes(let value): self("reset.minutes", language == .zhHans ? Format.grouped(value) : minutes(value))
        case .hours(let value): self("reset.hours", language == .zhHans ? Format.grouped(value) : hours(value))
        case .daysHours(let days, let hours): self("reset.daysHours", language == .zhHans ? Format.grouped(days) : self.days(days), language == .zhHans ? Format.grouped(hours) : self.hours(hours))
        case .date(let key): self("reset.date", day(key, full: true))
        case .raw(let value): value
        }
    }

    func day(_ key: String, full: Bool = false) -> String {
        guard let date = DayKey.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = locale
        if full { formatter.dateStyle = .medium } else { formatter.setLocalizedDateFormatFromTemplate("MMMd") }
        return formatter.string(from: date)
    }
    func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    func hour(_ hour: Int) -> String {
        time(Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour))!)
    }
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter
    }
    var weekdays: [String] {
        let symbols = dateFormatter.veryShortStandaloneWeekdaySymbols!
        return Array(symbols.dropFirst()) + [symbols[0]]
    }
    func weekday(_ mondayIndex: Int) -> String { dateFormatter.shortWeekdaySymbols[(mondayIndex + 1) % 7] }
    func month(_ month: Int) -> String { dateFormatter.shortStandaloneMonthSymbols[month - 1] }
    func duration(_ ms: Int) -> String {
        let minutes = ms / 60_000
        return minutes < 60 ? self("format.durationMinutes", Format.grouped(minutes)) : self("format.durationHours", Format.grouped(minutes / 60))
    }

    func error(_ error: any Error) -> String {
        if let error = error as? AppError {
            switch error {
            case .save(let cause): return self("error.save", self.error(cause))
            case .restore(let cause): return self("error.restore", self.error(cause))
            case .restart(let cause): return self("error.restart", self.error(cause))
            case .backups(let cause): return self("error.backups", self.error(cause))
            }
        }
        if let error = error as? UsageError {
            switch error {
            case .missingBinary: return self("error.missingBinary")
            case .failed(let status): return self("error.exitStatus", status)
            case .timedOut: return self("error.timedOut")
            }
        }
        if let error = error as? SaveStoreError {
            switch error {
            case .locked: return self("error.saveLocked")
            case .invalidVersion: return self("error.invalidVersion")
            case .tooNew(let version): return self("error.saveTooNew", version)
            case .missingMigration(let version): return self("error.missingMigration", version, version + 1)
            case .invalidJSON: return self("error.invalidJSON")
            case .restartNotAllowed: return self("error.restartNotAllowed")
            }
        }
        return error.localizedDescription
    }
}

enum AppError: Error {
    case save(any Error), restore(any Error), restart(any Error), backups(any Error)
}

private struct L10nKey: EnvironmentKey {
    static let defaultValue = L10n(language: Language.resolve(systemLanguages: Locale.preferredLanguages))
}

extension EnvironmentValues {
    var l10n: L10n {
        get { self[L10nKey.self] }
        set { self[L10nKey.self] = newValue }
    }
}

/// Observes the preference at each hosting root, including inactive panels and recovery screens.
struct LocalizedRoot<Content: View>: View {
    let model: AppModel
    let content: Content
    var body: some View {
        content.environment(\.l10n, model.l10n).environment(\.locale, model.l10n.locale)
    }
}

extension View {
    func localized(using model: AppModel) -> some View { LocalizedRoot(model: model, content: self) }
}
