import AppKit
import Foundation
import Observation
import VoyageCore

@MainActor
@Observable
final class AppModel {
    private(set) var state: JourneyState?
    let catalog: CityCatalog?
    private let contentFailed: Bool
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
    private(set) var onboarding: OnboardingFlow?
    var tab: MainTab = .home
    var mailFilter: MailFilter = .all
    var collectionTab: CollectionTab = .passport
    var dataTab: DataTab = .dashboard
    var selectedLetterID: Int?
    var showingSettings = false
    @ObservationIgnored var onLockChange: (() -> Void)?
    @ObservationIgnored var onLanguageChange: (() -> Void)?
    @ObservationIgnored var onDisplayChange: (() -> Void)?
    var notchEnabled: Bool {
        didSet {
            if !isSnapshot { defaults.set(notchEnabled, forKey: "notchEnabled") }
            onDisplayChange?()
        }
    }
    var floatingEnabled: Bool {
        didSet {
            if !isSnapshot { defaults.set(floatingEnabled, forKey: "floatingEnabled") }
            onDisplayChange?()
        }
    }
    var languagePreference: LanguagePreference {
        didSet {
            if !isSnapshot { defaults.set(languagePreference.rawValue, forKey: "language") }
            onLanguageChange?()
        }
    }
    private let defaults: UserDefaults
    private let languageOverride: Language?
    var l10n: L10n { L10n(language: languageOverride ?? languagePreference.resolve(systemLanguages: Locale.preferredLanguages)) }
    var petName: String { care?.petName ?? state?.pet.displayName ?? "" }

    private let dataDirectory: URL
    private let store: SaveStore
    private let isSnapshot: Bool
    private let clock: () -> Date
    private let onboardingSeed: UInt32
    private let onboardingReader: OnboardingFlow.UsageReader
    private let quotaReader: @Sendable () async throws -> [ProviderQuota]
    /// Persistence tests can finish onboarding without installing OS observers or starting scans.
    private let runtimeEnabled: Bool
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

    init(isSnapshot: Bool = false, languageOverride: Language? = nil, defaults: UserDefaults = .standard, directory: URL? = nil, catalog: CityCatalog? = nil, contentDirectory: URL? = nil,
         now: @escaping () -> Date = Date.init, onboardingSeed: UInt32 = UInt32.random(in: 0...UInt32.max),
         onboardingReader: @escaping OnboardingFlow.UsageReader = OnboardingFlow.readLocalUsage,
         quotaReader: @escaping @Sendable () async throws -> [ProviderQuota] = UsageSource.fetchQuotas,
         runtimeEnabled: Bool = true) {
        self.isSnapshot = isSnapshot
        clock = now
        self.now = now()
        self.onboardingSeed = onboardingSeed
        self.onboardingReader = onboardingReader
        self.quotaReader = quotaReader
        self.runtimeEnabled = runtimeEnabled
        self.languageOverride = languageOverride
        self.defaults = defaults
        languagePreference = defaults.string(forKey: "language").flatMap(LanguagePreference.init(rawValue:)) ?? .system
        notchEnabled = defaults.object(forKey: "notchEnabled") as? Bool ?? true
        floatingEnabled = defaults.object(forKey: "floatingEnabled") as? Bool ?? true
        if let directory {
            dataDirectory = directory
        } else if let override = ProcessInfo.processInfo.environment["TOKEN_VOYAGE_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TokenVoyage")
        }
        let loadedCatalog = catalog ?? (try? CityCatalog.load(directory: contentDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("Content")))
        self.catalog = loadedCatalog
        contentFailed = loadedCatalog.map { $0.active.count < 2 } ?? true
        store = SaveStore(directory: dataDirectory, journeyMigrations: loadedCatalog.map { .journey(catalog: $0) } ?? SaveMigrations(currentVersion: JourneyState.currentVersion))
        isLocked = true
        guard !contentFailed, let loadedCatalog else {
            recoveryIssues = [SaveRecoveryIssue(file: .journey, problem: .content)]
            return
        }
        store.load()
        if case .loaded(let saved) = store.journey {
            state = saved
        } else if !store.isLocked {
            if case .missing = store.journey, case .missing = store.care {
                onboarding = OnboardingFlow(catalog: loadedCatalog, seed: onboardingSeed, today: now(), readUsage: onboardingReader)
            } else {
                state = Self.newJourney(in: store, catalog: loadedCatalog, now: now())
            }
        }
        refreshSaveStatus()
    }

    var today: DayRecord { state.flatMap { $0.days[$0.openDate] } ?? DayRecord() }
    var todayFuel: Int { today.fuel }
    var unread: Int { state?.unreadCount(now: now) ?? 0 }
    var letters: [Letter] { state?.deliveredLetters(now: now) ?? [] }
    var filteredLetters: [Letter] { letters.filter(mailFilter.includes) }

    func navigate(to tab: MainTab) {
        self.tab = tab
        showingSettings = false
    }

    func openPostOffice() { navigate(to: .home) }

    func activateHomeAction() {
        if let letter = letters.first(where: { !$0.read }) {
            mailFilter = .all
            selectedLetterID = letter.id
            navigate(to: .mail)
        } else {
            navigate(to: .journey)
        }
    }

    /// Snapshot variants exist only for the duration of a render, never in the save store.
    func withSnapshotState(_ update: (inout JourneyState) -> Void, render: () -> Void) {
        precondition(isSnapshot)
        let original = state
        defer { state = original }
        if var state {
            update(&state)
            self.state = state
        }
        render()
    }

    var canChangeStart: Bool { !isLocked && state.map { $0.startDate == DayKey.string(from: now) } == true }
    var startCities: [City] {
        (catalog?.active ?? []).sorted { l10n.cityName($0).compare(l10n.cityName($1), locale: l10n.locale) == .orderedAscending }
    }

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
        guard let state else { return [] }
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
        guard !isLocked, !isSnapshot else { return }
        if let onboarding {
            onboarding.startReading()
            return
        }
        guard !hasStarted, runtimeEnabled else { return }
        if case .missing = store.journey { persist() }
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
        now = clock()
        if let lastMovement, now.timeIntervalSince(lastMovement) > 300 { isMoving = false }
    }

    /// Coalesces change events and keeps at least `minScanInterval` between scans.
    func scheduleScan(immediately: Bool = false) {
        guard !isLocked, onboarding == nil, scheduledScan == nil else { return }
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
        guard !isLocked, onboarding == nil, !isScanning, let state, let catalog else { return }
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
            guard !isLocked, generation == backgroundGeneration, var state = self.state else { return }
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
            state.sync(today: today, finalized: finalized, catalog: catalog)
            self.state = state
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
        guard !isLocked, onboarding == nil else { return }
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

    private func refreshQuotasInBackground() {
        guard !isLocked, onboarding == nil, !isSnapshot else { return }
        Task { await loadQuotas() }
    }

    /// Keeps the last good reading when a refresh fails, and says so.
    func loadQuotas(force: Bool = false) async {
        guard !isLocked, onboarding == nil, !isSnapshot else { return }
        let generation = backgroundGeneration
        if !force, let loaded = quotasLoadedAt, Date().timeIntervalSince(loaded) < Self.quotaInterval - 30 { return }
        guard !isLoadingQuotas else { return }
        isLoadingQuotas = true
        defer { isLoadingQuotas = false }
        do {
            let fetched = try await quotaReader()
            guard !isLocked, generation == backgroundGeneration else { return }
            quotas = fetched
            quotasLoadedAt = Date()
            quotaError = nil
        } catch {
            quotaError = error
        }
    }

    func markRead(_ letter: Letter) {
        guard !isLocked, !letter.read else { return }
        state?.markRead(letter.id)
        persist()
    }

    /// Only available on the first day, when nothing has been settled and today can simply be replayed.
    func setStart(_ cityId: String) {
        guard canChangeStart, var replacement = state, let catalog, catalog.find(cityId)?.status == "active", cityId != replacement.route[0] else { return }
        replacement.setStart(cityId, catalog: catalog)
        self.state = replacement
        enrichAttempts = [:]
        persist()
        Task { await enrichLatest() }
    }

    func photoURL(_ letter: Letter) -> URL? {
        letter.photoFile.map { dataDirectory.appendingPathComponent("photos").appendingPathComponent($0) }
    }

    /// Only the newest letter goes to the network; a long catch-up does not send a burst of requests.
    func enrichLatest() async {
        guard !isLocked, onboarding == nil, !isSnapshot, !isEnriching, let state, let catalog,
              let letter = state.letters.max(by: { $0.id < $1.id }), !letter.enrichmentDone else { return }
        let generation = backgroundGeneration
        let attempts = enrichAttempts[letter.id, default: 0]
        guard attempts < 3, let city = catalog.find(letter.subjectCityId) else { return }
        isEnriching = true
        defer { isEnriching = false }
        enrichAttempts[letter.id] = attempts + 1

        let coordinate = letter.transitTargetId == nil ? catalog.city(letter.cityId).coordinate : state.position
        let result = await Enricher.fetch(city: city, coordinate: coordinate)
        guard !isLocked, generation == backgroundGeneration, var updatedState = self.state else { return }
        let photoFile = result.photoData.flatMap { savePhoto($0, letterId: letter.id) }
        guard let index = updatedState.letters.firstIndex(where: { $0.id == letter.id }) else { return }
        updatedState.letters[index].weatherCode = result.weatherCode ?? updatedState.letters[index].weatherCode
        updatedState.letters[index].temperatureC = result.temperatureC ?? updatedState.letters[index].temperatureC
        updatedState.letters[index].place.merge(result.place) { _, new in new }
        updatedState.letters[index].photoFile = photoFile ?? updatedState.letters[index].photoFile
        let updated = updatedState.letters[index]
        updatedState.letters[index].enrichmentDone = (updated.weatherCode != nil && !updated.place.isEmpty) || attempts >= 2
        self.state = updatedState
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
        guard !isLocked, onboarding == nil, !isSnapshot, let state else { return }
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
        guard !contentFailed else { return }
        store.load()
        if onboarding?.step == .depart {
            refreshSaveStatus()
            completeOnboarding()
            return
        }
        resumeAfterRecovery()
    }

    func completeOnboarding() {
        guard !isLocked, !isSnapshot, let saves = onboarding?.saves(now: clock()) else { return }
        do {
            try store.save(saves.journey)
            try store.save(saves.care)
            state = saves.journey
            care = saves.care
            onboarding = nil
            lastError = nil
            openPostOffice()
            start()
            onDisplayChange?()
        } catch {
            lastError = AppError.save(error)
            refreshSaveStatus()
        }
    }

    func restoreSave(_ backup: SaveBackup) {
        guard !contentFailed else { return }
        do {
            try store.restore(backup: backup)
            resumeAfterRecovery()
        } catch {
            recoveryError = .restore(error)
            refreshSaveStatus()
        }
    }

    func restartSave(_ file: SaveFile) {
        guard !contentFailed else { return }
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
        guard !isLocked, let catalog else { return }
        if case .loaded(let saved) = store.journey {
            state = saved
            onboarding = nil
        } else {
            if case .missing = store.journey, case .missing = store.care {
                state = nil
                if onboarding == nil {
                    onboarding = OnboardingFlow(catalog: catalog, seed: onboardingSeed, today: clock(), readUsage: onboardingReader)
                }
            } else {
                onboarding = nil
                state = Self.newJourney(in: store, catalog: catalog, now: clock())
            }
        }
        enrichAttempts = [:]
        lastError = nil
        start()
        onLockChange?()
    }

    private static func newJourney(in store: SaveStore, catalog: CityCatalog, now: Date) -> JourneyState {
        let pet: PetKind
        if case .loaded(let care) = store.care {
            pet = care.species
        } else {
            pet = .pigeon
        }
        return JourneyState(
            seed: UInt32.random(in: 0...UInt32.max), startCityId: "shanghai", pet: pet,
            date: DayKey.string(from: now), now: now, catalog: catalog
        )
    }

    private func refreshSaveStatus() {
        guard !contentFailed else { return }
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
