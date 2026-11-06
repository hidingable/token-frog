import AppKit
import Foundation
import Observation
import VoyageCore

@MainActor
@Observable
final class AppModel {
    private(set) var state: JourneyState
    private(set) var now = Date()
    private(set) var lastScan: Date?
    private(set) var lastError: (any Error)?
    private(set) var isMoving = false
    /// Display-only daily fuel for the trend bars. Days before the journey started never add mileage.
    private(set) var history: [String: Int] = [:]
    /// Display-only usage detail, kept apart from the journey.
    private(set) var todayTotals: UsageTotals?
    private(set) var dashboardDays: [DayDetail]?
    private(set) var quotas: [ProviderQuota] = []
    private(set) var quotasLoadedAt: Date?
    private(set) var quotaError: (any Error)?
    private(set) var isLocked: Bool
    private(set) var recoveryIssues: [SaveRecoveryIssue] = []
    private(set) var recoveryError: AppError?
    private(set) var care: CareState?
    @ObservationIgnored var onLockChange: (() -> Void)?
    @ObservationIgnored var onLanguageChange: (() -> Void)?
    var languagePreference: LanguagePreference {
        didSet {
            if !isSnapshot { defaults.set(languagePreference.rawValue, forKey: "language") }
            onLanguageChange?()
        }
    }
    private let defaults: UserDefaults
    private let languageOverride: Language?
    var l10n: L10n { L10n(language: languageOverride ?? languagePreference.resolve(systemLanguages: Locale.preferredLanguages)) }
    var petName: String { care?.petName ?? state.pet.displayName }

    private let dataDirectory: URL
    private let store: SaveStore
    private let isSnapshot: Bool
    private var watcher: FileWatcher?
    private var timers: [Timer] = []
    private var wakeObserver: NSObjectProtocol?
    private var hasStarted = false
    private var backgroundGeneration = 0
    private var isScanning = false
    private var scheduledScan: Task<Void, Never>?
    private var lastMovement: Date?
    private var enrichAttempts: [Int: Int] = [:]
    private var isEnriching = false
    private var historyDate: String?
    private var dashboardLoadedAt: Date?
    private var monthHoursLoadedAt: Date?
    private var monthHours: [HourUsage] = []
    private var todayHours: [HourUsage] = []
    private var isLoadingQuotas = false

    private static let minScanInterval: TimeInterval = 60
    private static let fallbackScanInterval: TimeInterval = 300
    private static let dashboardMaxAge: TimeInterval = 300
    /// A 30-day hourly read costs about a minute of CPU; a single day costs seconds.
    private static let monthHoursMaxAge: TimeInterval = 3600
    /// Quotas hit provider APIs, so they refresh on a fixed clock and never because tokens were used.
    private static let quotaInterval: TimeInterval = 600

    init(isSnapshot: Bool = false, languageOverride: Language? = nil, defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.isSnapshot = isSnapshot
        self.languageOverride = languageOverride
        self.defaults = defaults
        languagePreference = defaults.string(forKey: "language").flatMap(LanguagePreference.init(rawValue:)) ?? .system
        if let directory {
            dataDirectory = directory
        } else if let override = ProcessInfo.processInfo.environment["TOKEN_VOYAGE_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TokenVoyage")
        }
        store = SaveStore(directory: dataDirectory)
        store.load()
        isLocked = store.isLocked
        if case .loaded(let saved) = store.journey {
            state = saved
        } else {
            state = Self.newJourney(in: store)
        }
        refreshSaveStatus()
    }

    var today: DayRecord { state.days[state.openDate] ?? DayRecord() }
    var todayFuel: Int { today.fuel }
    var unread: Int { state.unreadCount(now: now) }
    var letters: [Letter] { state.deliveredLetters(now: now) }
    var canChangeStart: Bool { state.startDate == state.openDate }

    var todayVehicles: [VehicleShare] {
        let usage = today.byClient
        let total = max(usage.values.reduce(0, +), 1)
        let ranked = usage.sorted { first, second in
            first.value == second.value ? first.key < second.key : first.value > second.value
        }
        let shares = ranked.prefix(3).map { entry in
            VehicleShare(client: entry.key, percent: Int((Double(entry.value) / Double(total) * 100).rounded()))
        }
        return shares.filter { $0.percent > 0 }
    }

    var recentDays: [(date: String, fuel: Int)] {
        var keys = [state.openDate]
        let calendar = Calendar.current
        var cursor = DayKey.date(from: state.openDate) ?? now
        for _ in 0..<6 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            keys.append(DayKey.string(from: cursor))
        }
        return keys.reversed().map { key in (key, max(state.fuel(on: key), history[key] ?? 0)) }
    }

    func start() {
        guard !isLocked, !hasStarted, !isSnapshot else { return }
        persist()
        guard !isLocked else { return }
        hasStarted = true
        if watcher == nil {
            let watcher = FileWatcher { [weak self] in self?.scheduleScan() }
            watcher.start()
            self.watcher = watcher
        }

        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.fallbackScanInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScan() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.quotaInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshQuotasInBackground() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
        ]
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleScan()
                    self?.refreshQuotasInBackground()
                }
            }
        }
        scheduleScan()
        refreshQuotasInBackground()
    }

    private func tick() {
        guard !isLocked else { return }
        now = Date()
        if let lastMovement, now.timeIntervalSince(lastMovement) > 300 { isMoving = false }
    }

    /// Coalesces change events and keeps at least `minScanInterval` between scans.
    func scheduleScan(immediately: Bool = false) {
        guard !isLocked, scheduledScan == nil else { return }
        let elapsed = lastScan.map { Date().timeIntervalSince($0) } ?? .infinity
        let wait = immediately ? 0 : max(0, Self.minScanInterval - elapsed)
        scheduledScan = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.scheduledScan = nil
            await self.scan()
        }
    }

    func scan() async {
        guard !isLocked, !isScanning else { return }
        let generation = backgroundGeneration
        isScanning = true
        defer { isScanning = false }
        let date = Date()
        let todayKey = DayKey.string(from: date)
        var since = min(state.openDate, todayKey)
        let needsHistory = historyDate != todayKey
        if needsHistory, let start = Calendar.current.date(byAdding: .day, value: -6, to: date) {
            since = min(since, DayKey.string(from: start))
        }
        do {
            let details = try await UsageSource.fetch(since: since, until: todayKey)
            guard !isLocked, generation == backgroundGeneration else { return }
            let days = details.map(\.usage)
            let todayDetail = details.first { $0.date == todayKey }
            todayTotals = UsageLedger(days: todayDetail.map { [$0] } ?? []).totals
            if let todayDetail, var known = dashboardDays {
                known.removeAll { $0.date == todayKey }
                known.append(todayDetail)
                dashboardDays = known
            }
            let today = days.first { $0.date == todayKey } ?? DayUsage(date: todayKey)
            let finalized = days.filter { $0.date < todayKey && $0.date >= state.openDate }
            if needsHistory {
                history = Dictionary(days.map { ($0.date, $0.fuel) }, uniquingKeysWith: { _, latest in latest })
                historyDate = todayKey
            }
            let before = state.totalFuel
            state.sync(today: today, finalized: finalized)
            if state.totalFuel > before {
                isMoving = true
                lastMovement = date
            }
            lastError = nil
            lastScan = date
            now = date
            persist()
            if !isSnapshot { await enrichLatest() }
        } catch {
            lastScan = date
            lastError = error
        }
    }

    var dashboardHours: [HourUsage] {
        let today = todayHours.first?.date
        return monthHours.filter { $0.date != today } + todayHours
    }

    /// Reads the whole history only while the dashboard is showing, sharing the scan's serial slot.
    func loadDashboard() async {
        guard !isLocked else { return }
        let generation = backgroundGeneration
        let now = Date()
        let isStale = dashboardLoadedAt.map { now.timeIntervalSince($0) >= Self.dashboardMaxAge } ?? true
        let monthStale = monthHoursLoadedAt.map { now.timeIntervalSince($0) >= Self.monthHoursMaxAge } ?? true
        guard isStale || monthStale, !isScanning else { return }
        isScanning = true
        let until = DayKey.string(from: now)
        do {
            if isStale {
                let days = try await UsageSource.fetch(since: nil, until: until)
                guard !isLocked, generation == backgroundGeneration else { isScanning = false; return }
                dashboardDays = days
                let hours = try await UsageSource.fetchHours(since: until, until: until)
                guard !isLocked, generation == backgroundGeneration else { isScanning = false; return }
                todayHours = hours
                dashboardLoadedAt = now
            }
            lastError = nil
        } catch {
            lastError = error
        }
        // Released between reads so a scan waiting on the graph can run before the slow hourly read.
        isScanning = false
        guard !isLocked, generation == backgroundGeneration, monthStale,
              let start = Calendar.current.date(byAdding: .day, value: -29, to: now) else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let hours = try await UsageSource.fetchHours(since: DayKey.string(from: start), until: until)
            guard !isLocked, generation == backgroundGeneration else { return }
            monthHours = hours
            monthHoursLoadedAt = now
        } catch {
            lastError = error
        }
    }

    var tightestQuota: (provider: String, metric: ProviderQuota.Metric)? {
        QuotaReport.tightest(quotas, usedClients: today.byClient.keys)
    }

    private func refreshQuotasInBackground() {
        guard !isLocked, !isSnapshot else { return }
        Task { await loadQuotas() }
    }

    /// Keeps the last good reading when a refresh fails, and says so.
    func loadQuotas(force: Bool = false) async {
        guard !isLocked, !isSnapshot else { return }
        let generation = backgroundGeneration
        if !force, let loaded = quotasLoadedAt, Date().timeIntervalSince(loaded) < Self.quotaInterval - 30 { return }
        guard !isLoadingQuotas else { return }
        isLoadingQuotas = true
        defer { isLoadingQuotas = false }
        do {
            let fetched = try await UsageSource.fetchQuotas()
            guard !isLocked, generation == backgroundGeneration else { return }
            quotas = fetched
            quotasLoadedAt = Date()
            quotaError = nil
        } catch {
            quotaError = error
        }
    }

    func choose(_ cityId: String?) {
        state.choose(next: cityId)
        persist()
    }

    func markRead(_ letter: Letter) {
        guard !letter.read else { return }
        state.markRead(letter.id)
        persist()
    }

    func setPet(_ pet: PetKind) {
        state.pet = pet
        persist()
    }

    /// Only available on the first day, when nothing has been settled and today can simply be replayed.
    func setStart(_ cityId: String) {
        guard canChangeStart, cityId != state.route[0] else { return }
        var replacement = JourneyState(seed: state.seed, startCityId: cityId, pet: state.pet, date: state.openDate)
        replacement.sync(today: DayUsage(date: state.openDate, fuel: todayFuel, byClient: today.byClient))
        state = replacement
        enrichAttempts = [:]
        persist()
        Task { await enrichLatest() }
    }

    func photoURL(_ letter: Letter) -> URL? {
        letter.photoFile.map { dataDirectory.appendingPathComponent("photos").appendingPathComponent($0) }
    }

    /// Only the newest letter goes to the network; a long catch-up does not send a burst of requests.
    func enrichLatest() async {
        guard !isLocked, !isSnapshot, !isEnriching,
              let letter = state.letters.max(by: { $0.id < $1.id }), !letter.enrichmentDone else { return }
        let generation = backgroundGeneration
        let attempts = enrichAttempts[letter.id, default: 0]
        guard attempts < 3, let city = City.find(letter.subjectCityId) else { return }
        isEnriching = true
        defer { isEnriching = false }
        enrichAttempts[letter.id] = attempts + 1

        let coordinate = letter.transitTargetId == nil ? City.named(letter.cityId).coordinate : state.position
        let result = await Enricher.fetch(city: city, coordinate: coordinate)
        guard !isLocked, generation == backgroundGeneration else { return }
        let photoFile = result.photoData.flatMap { savePhoto($0, letterId: letter.id) }
        guard let index = state.letters.firstIndex(where: { $0.id == letter.id }) else { return }
        state.letters[index].weather = result.weather ?? state.letters[index].weather
        state.letters[index].placeTitle = result.placeTitle ?? state.letters[index].placeTitle
        state.letters[index].placeSummary = result.placeSummary ?? state.letters[index].placeSummary
        state.letters[index].placeURL = result.placeURL ?? state.letters[index].placeURL
        state.letters[index].photoFile = photoFile ?? state.letters[index].photoFile
        let updated = state.letters[index]
        state.letters[index].enrichmentDone = (updated.weather != nil && updated.placeSummary != nil) || attempts >= 2
        persist()
    }

    private func savePhoto(_ data: Data, letterId: Int) -> String? {
        guard !isLocked, let png = Enricher.pixelate(data) else { return nil }
        let directory = dataDirectory.appendingPathComponent("photos")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "letter-\(letterId).png"
        do {
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func persist() {
        guard !isLocked else { return }
        do {
            try store.save(state)
            if case .missing = store.care {
                let care = CareState.legacy(from: state)
                try store.save(care)
                self.care = care
            }
        } catch {
            lastError = AppError.save(error)
            refreshSaveStatus()
        }
    }

    func retrySaves() {
        store.load()
        resumeAfterRecovery()
    }

    func restoreSave(_ backup: SaveBackup) {
        do {
            try store.restore(backup: backup)
            resumeAfterRecovery()
        } catch {
            recoveryError = .restore(error)
            refreshSaveStatus()
        }
    }

    func restartSave(_ file: SaveFile) {
        do {
            try store.restart(file)
            resumeAfterRecovery()
        } catch {
            recoveryError = .restart(error)
            refreshSaveStatus()
        }
    }

    private func resumeAfterRecovery() {
        recoveryError = nil
        refreshSaveStatus()
        guard !isLocked else { return }
        if case .loaded(let saved) = store.journey {
            state = saved
        } else {
            state = Self.newJourney(in: store)
        }
        enrichAttempts = [:]
        lastError = nil
        start()
        onLockChange?()
    }

    private static func newJourney(in store: SaveStore) -> JourneyState {
        let pet: PetKind
        if case .loaded(let care) = store.care {
            pet = care.species
        } else {
            pet = .pigeon
        }
        return JourneyState(
            seed: UInt32.random(in: 0...UInt32.max), startCityId: "shanghai", pet: pet,
            date: DayKey.string(from: Date())
        )
    }

    private func refreshSaveStatus() {
        if case .loaded(let saved) = store.care { care = saved } else { care = nil }
        let wasLocked = isLocked
        isLocked = store.isLocked
        if isLocked, !wasLocked { backgroundGeneration += 1 }
        var issues: [SaveRecoveryIssue] = []
        func appendIssue<State>(_ result: SaveLoadResult<State>, file: SaveFile) {
            let problem: SaveRecoveryIssue.Problem
            switch result {
            case .missing, .loaded: return
            case .corrupted(let backup): problem = .corrupted(backupPath: backup.path)
            case .tooNew(let version): problem = .tooNew(version: version)
            case .unreadable(let reason): problem = .unreadable(reason: reason)
            }
            var backups: [SaveBackup] = []
            if case .corrupted = result {
                do { backups = try store.restorableBackups(for: file) }
                catch { recoveryError = .backups(error) }
            }
            issues.append(SaveRecoveryIssue(file: file, problem: problem, backups: backups))
        }
        appendIssue(store.journey, file: .journey)
        appendIssue(store.care, file: .care)
        recoveryIssues = issues
        if isLocked {
            timers.forEach { $0.invalidate() }
            timers = []
            scheduledScan?.cancel()
            scheduledScan = nil
            hasStarted = false
        }
        if wasLocked != isLocked, isLocked { onLockChange?() }
    }
}
