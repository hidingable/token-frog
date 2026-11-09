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
        let measurementStart = DashboardMeasurementCounters.start()
        defer { DashboardMeasurementCounters.record(.l10n, since: measurementStart) }
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

    func itemName(_ item: Item) -> String { LetterComposer.localized(item.names, l10n: self) ?? item.id }
    func itemDescription(_ item: Item) -> String { LetterComposer.localized(item.descriptions, l10n: self) ?? "" }

    static func bundleLookup(_ language: Language, _ key: String) -> String? {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let missing = "\u{0}missing.translation"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing || value.isEmpty ? nil : value
    }

    // Every key selected at runtime is explicit, so catalog tests can verify the whole table.
    static let tabKeys: [MainTab: String] = [.home: "nav.postOffice", .journey: "nav.journey", .mail: "nav.mail", .collection: "nav.collection", .data: "nav.data"]
    static let mailFilterKeys: [MailFilter: String] = [.all: "mail.all", .travel: "mail.travel", .postcards: "mail.postcards", .weekly: "mail.weekly"]
    static let mailEmptyKeys: [MailFilter: String] = [.all: "mail.empty", .travel: "mail.travelEmpty", .postcards: "mail.postcardsEmpty", .weekly: "mail.weeklyEmpty"]
    static let collectionTabKeys: [CollectionTab: String] = [.passport: "nav.passport", .bag: "collection.bag", .souvenirs: "collection.souvenirs", .menus: "collection.menus", .memories: "collection.memories"]
    static let dataTabKeys: [DataTab: String] = [.dashboard: "nav.dashboard", .quota: "nav.quota"]
    static let periodKeys: [DashboardPeriod: String] = [.today: "period.today", .week: "period.week", .month: "period.month", .quarter: "period.quarter", .year: "period.year", .all: "period.all"]
    static let metricKeys: [DashboardMetric: String] = [.total: "metric.total", .fuel: "metric.fuel", .cost: "metric.cost", .messages: "metric.messages"]
    static let quotaKeys = ["Weekly": "quota.weekly", "Daily": "quota.daily", "Monthly": "quota.monthly", "Session": "quota.session", "Chat": "quota.chat", "Completions": "quota.completions", "Premium": "quota.premium"]
    static let appearanceKeys: [AppearancePreference: String] = [.system: "appearance.system", .dark: "appearance.dark", .light: "appearance.light"]
    static let languageKeys: [LanguagePreference: String] = [.system: "language.system", .zhHans: "language.zhHans", .en: "language.en"]
    static let countKeys = ["tokens": ["tokens.one", "tokens.other"], "days": ["days.one", "days.other"], "hours": ["hours.one", "hours.other"], "minutes": ["minutes.one", "minutes.other"]]
    static let onboardingTitleKeys: [OnboardingFlow.Step: String] = [.eggs: "onboarding.eggs", .home: "onboarding.home", .hatch: "onboarding.hatch", .logbook: "onboarding.logbook", .depart: "onboarding.depart"]
    static let stageKeys: [Stage: String] = [.egg: "stage.egg", .hatchling: "stage.hatchling", .juvenile: "stage.juvenile", .teen: "stage.teen", .traveler: "stage.traveler", .veteran: "stage.veteran", .legend: "stage.legend"]
    static let habitKeys: [Habit: String] = [.talkative: "habit.talkative", .observant: "habit.observant"]
    static let habitDescriptionKeys: [Habit: [String]] = [
        .talkative: ["habit.talkative.0", "habit.talkative.1", "habit.talkative.2", "habit.talkative.3"],
        .observant: ["habit.observant.0", "habit.observant.1", "habit.observant.2", "habit.observant.3"],
    ]
    static let floatingKeys = ["floating.line.0", "floating.line.1", "floating.line.2"]
    static let wishActionKeys = ["wish.write", "wish.edit", "wish.save", "wish.saving"]
    static let settingsKeys = ["settings.login", "settings.loginFailed", "settings.loginApproval", "settings.loginUnavailable", "settings.notifications", "settings.morningMail", "settings.newCountry", "settings.deliveryTime", "settings.deliveryHint", "settings.openSystemSettings", "settings.authorizationNotRequested", "settings.authorizationGranted", "settings.authorizationDenied", "settings.authorizationUnavailable", "settings.data", "settings.export", "settings.import", "settings.exportHint", "settings.openDataFolder", "settings.about", "settings.version", "settings.licenses", "settings.naturalEarth", "settings.privacy", "usage.noRecords", "usage.recoverableFailure", "settings.language", "settings.interfaceAndLetters", "settings.appearance", "settings.display", "settings.notch", "settings.floating", "settings.home", "accounts.title", "accounts.manage", "onboarding.homeHint"]
    static var dynamicKeys: [String] {
        Array(tabKeys.values) + Array(mailFilterKeys.values) + Array(mailEmptyKeys.values) + Array(collectionTabKeys.values) + Array(dataTabKeys.values) + Array(periodKeys.values) + Array(metricKeys.values) + Array(quotaKeys.values) + Array(languageKeys.values) + Array(appearanceKeys.values) + countKeys.values.flatMap { $0 } + Array(onboardingTitleKeys.values) + Enricher.weatherKeys + Array(stageKeys.values) + Array(habitKeys.values) + habitDescriptionKeys.values.flatMap { $0 } + floatingKeys + wishActionKeys + settingsKeys + ["habit.both", "home.bubble.mail", "home.bubble.reply", "home.bubble.bag", "box.next", "box.keep", "box.open"]
    }

    func defaultPetName(_ pet: PetID, catalog: PetCatalog) -> String {
        catalog.find(pet).flatMap { LetterComposer.localized($0.names, l10n: self) } ?? pet.rawValue
    }
    func eggName(_ pet: PetID, catalog: PetCatalog) -> String {
        catalog.find(pet).flatMap { LetterComposer.localized($0.eggNames, l10n: self) } ?? pet.rawValue
    }

    @MainActor func onboardingTitle(_ flow: OnboardingFlow) -> String {
        if flow.step == .logbook, flow.logbook == nil { return self("onboarding.welcome") }
        return self(Self.onboardingTitleKeys[flow.step]!)
    }

    func tab(_ tab: MainTab) -> String { self(Self.tabKeys[tab]!) }
    func mailFilter(_ filter: MailFilter) -> String { self(Self.mailFilterKeys[filter]!) }
    func collectionTab(_ tab: CollectionTab) -> String { self(Self.collectionTabKeys[tab]!) }
    func dataTab(_ tab: DataTab) -> String { self(Self.dataTabKeys[tab]!) }
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
        return L10nDateFormatters.shared.withFormatter(language: language, format: full ? .dayFull : .day) {
            $0.string(from: date)
        }
    }
    func time(_ date: Date) -> String {
        L10nDateFormatters.shared.withFormatter(language: language, format: .time) { $0.string(from: date) }
    }
    func hour(_ hour: Int) -> String {
        time(Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour))!)
    }
    var weekdays: [String] {
        L10nDateFormatters.shared.withFormatter(language: language, format: .symbols) {
            let symbols = $0.veryShortStandaloneWeekdaySymbols!
            return Array(symbols.dropFirst()) + [symbols[0]]
        }
    }
    func weekday(_ mondayIndex: Int) -> String {
        L10nDateFormatters.shared.withFormatter(language: language, format: .symbols) { $0.shortWeekdaySymbols[(mondayIndex + 1) % 7] }
    }
    func month(_ month: Int) -> String {
        L10nDateFormatters.shared.withFormatter(language: language, format: .symbols) { $0.shortStandaloneMonthSymbols[month - 1] }
    }
    func duration(_ ms: Int) -> String {
        let minutes = ms / 60_000
        return minutes < 60 ? self("format.durationMinutes", Format.grouped(minutes)) : self("format.durationHours", Format.grouped(minutes / 60))
    }

    func error(_ error: any Error) -> String {
        if error is SaveArchiveError { return archiveError(error) }
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

/// A formatter stays behind the lock for its entire use, including lazy ICU initialization.
final class L10nDateFormatters: @unchecked Sendable {
    enum Format: Hashable { case day, dayFull, time, symbols }
    private struct Key: Hashable {
        let language: String
        let format: Format
        let timeZone: TimeZone
    }

    static let shared = L10nDateFormatters()
    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return formatters.count
    }

    func withFormatter<Value>(language: Language, format: Format, _ body: (DateFormatter) -> Value) -> Value {
        let timeZone = TimeZone.current
        let key = Key(language: language.rawValue, format: format, timeZone: timeZone)
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            DashboardMeasurementCounters.record(.dateFormatter)
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: language.rawValue)
            formatter.timeZone = timeZone
            switch format {
            case .day: formatter.setLocalizedDateFormatFromTemplate("MMMd")
            case .dayFull: formatter.dateStyle = .medium
            case .time: formatter.timeStyle = .short
            case .symbols: break
            }
            formatters[key] = formatter
        }
        return body(formatter)
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
            .environment(\.theme, model.theme)
            .environment(\.petCatalog, model.catalog?.pets)
            .preferredColorScheme(model.theme.scheme == .dark ? .dark : .light)
    }
}

extension View {
    func localized(using model: AppModel) -> some View { LocalizedRoot(model: model, content: self) }
}
