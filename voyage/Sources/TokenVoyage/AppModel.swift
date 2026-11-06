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
    private(set) var ritualLetterID: Int?
    private(set) var deferredReplyLetterID: Int?
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
    private let usageReader: @Sendable (String?, String) async throws -> [DayDetail]
    private let enrichmentReader: Enricher.Fetch
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
    private struct PlaceKey: Hashable {
        let letterId: Int
        let language: Language
    }
    private var placeAttempts: [PlaceKey: Int] = [:]
    private var enrichingPlaces: Set<PlaceKey> = []
    private var enrichingLetters: Set<Int> = []
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
         usageReader: @escaping @Sendable (String?, String) async throws -> [DayDetail] = UsageSource.fetch,
         enrichmentReader: @escaping Enricher.Fetch = { await Enricher.fetch($0) },
         runtimeEnabled: Bool = true) {
        self.isSnapshot = isSnapshot
        clock = now
        self.now = now()
        self.onboardingSeed = onboardingSeed
        self.onboardingReader = onboardingReader
        self.quotaReader = quotaReader
        self.usageReader = usageReader
        self.enrichmentReader = enrichmentReader
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
        processLetters()
    }

    var today: DayRecord { state.flatMap { $0.days[$0.openDate] } ?? DayRecord() }
    var todayFuel: Int { today.fuel }
    var unread: Int { state?.unreadCount(now: now) ?? 0 }
    var letters: [Letter] { state?.deliveredLetters(now: now) ?? [] }
    var filteredLetters: [Letter] { letters.filter(mailFilter.includes) }

    func navigate(to tab: MainTab) {
        ritualLetterID = nil
        self.tab = tab
        showingSettings = false
    }

    func openPostOffice() { navigate(to: .home) }

    func activateHomeAction() {
        if let letter = unreadInReadingOrder.first {
            navigate(to: .home)
            openRitualLetter(letter)
        } else {
            navigate(to: .journey)
        }
    }

    private var unreadInReadingOrder: [Letter] {
        letters.filter { !$0.read }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.deliverAt != $1.deliverAt { return $0.deliverAt < $1.deliverAt }
            return $0.id < $1.id
        }
    }

    var ritualLetter: Letter? { letters.first { $0.id == ritualLetterID } }
    var ritualRemainingCount: Int { unreadInReadingOrder.count }

    private func openRitualLetter(_ letter: Letter) {
        ritualLetterID = letter.id
        openLetter(letter)
    }

    func advanceRitual() {
        guard ritualLetterID != nil, !isLocked else { return }
        if let next = unreadInReadingOrder.first { openRitualLetter(next) }
        else { openPostOffice() }
    }

    func collectAllRitualLetters() {
        guard ritualLetterID != nil, !isLocked else { return }
        for letter in unreadInReadingOrder { markRead(letter) }
        openPostOffice()
    }

    @discardableResult
    func setTodayItem(_ item: String?) -> Bool {
        guard !isLocked, onboarding == nil, var care else { return false }
        if let item, !care.bag.owned.contains(item) { return false }
        care.bag.todayItem = item
        self.care = care
        persist()
        return true
    }

    func carriedCount(_ item: String) -> Int {
        state?.letters.filter { $0.carriedItem == item }.count ?? 0
    }

    @discardableResult
    func setSouvenirShelved(_ id: String, shelved: Bool) -> Bool {
        guard !isLocked, onboarding == nil, var care,
              let index = care.souvenirs.firstIndex(where: { $0.id == id }) else { return false }
        care.souvenirs[index].shelved = shelved
        self.care = care
        persist()
        return true
    }

    @discardableResult
    func openCollectionLetter(_ id: Int) -> Bool {
        guard let letter = letters.first(where: { $0.id == id }) else { return false }
        openFollowUp(letter)
        return true
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

    func withSnapshotCare(_ update: (inout CareState) -> Void, render: () -> Void) {
        precondition(isSnapshot)
        let original = care
        defer { care = original }
        if var care {
            update(&care)
            self.care = care
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
        let date = clock()
        let todayKey = DayKey.string(from: date)
        var since = min(state.openDate, todayKey)
        let needsHistory = historyDate != todayKey
        if needsHistory, let start = Calendar.current.date(byAdding: .day, value: -6, to: date) {
            since = min(since, DayKey.string(from: start))
        }
        do {
            let details = try await usageReader(since, todayKey)
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
            processLetters(persistChanges: false)
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
        guard !isLocked, onboarding == nil,
              let saved = state?.letters.first(where: { $0.id == letter.id }), !saved.read else { return }
        state?.markRead(letter.id)
        if var care {
            CareEngine.markCompanion(date: DayKey.string(from: clock()), care: &care)
            self.care = care
        }
        persist()
    }

    func openLetter(_ letter: Letter) {
        deferredReplyLetterID = nil
        markRead(letter)
    }

    func deferReply(to letterId: Int) { deferredReplyLetterID = letterId }

    @discardableResult
    func reply(to letterId: Int, option replyId: String) -> Bool {
        guard !isLocked, onboarding == nil, var state, var care,
              state.letters.contains(where: { $0.id == letterId && $0.deliverAt <= clock() }),
              CareEngine.reply(letterId: letterId, replyId: replyId, date: DayKey.string(from: clock()), journey: &state, care: &care)
        else { return false }
        self.state = state
        self.care = care
        persist()
        return true
    }

    func followUp(for letter: Letter) -> Letter? {
        guard let replyId = letter.selectedReplyId else { return nil }
        return letters.filter { $0.id > letter.id && $0.fulfilledReplyId == replyId }.min { $0.id < $1.id }
    }

    func openFollowUp(_ letter: Letter) {
        mailFilter = .all
        selectedLetterID = letter.id
        navigate(to: .mail)
    }

    /// Saved story snapshots are authoritative; replay repairs the care half of an interrupted write.
    private func processLetters(persistChanges: Bool = true) {
        guard !isLocked, onboarding == nil, var state, var care, let catalog else { return }
        let previousState = state
        let previousCare = care
        CareEngine.process(journey: &state, care: &care, stories: catalog.stories, catalog: catalog, wishTags: [])
        guard state != previousState || care != previousCare else { return }
        self.state = state
        self.care = care
        if persistChanges { persist() }
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

    /// Scans proactively enrich only the newest letter, including its current-language place.
    func enrichLatest() async {
        guard let letter = state?.letters.max(by: { $0.id < $1.id }) else { return }
        await enrich(letterId: letter.id, weatherAndPhoto: true)
    }

    /// Opening older mail fetches only the missing introduction in the selected language.
    func enrichPlace(letterId: Int) async {
        guard letters.contains(where: { $0.id == letterId }) else { return }
        await enrich(letterId: letterId, weatherAndPhoto: false)
    }

    private func enrich(letterId: Int, weatherAndPhoto: Bool) async {
        guard !isLocked, onboarding == nil, !isSnapshot, let state, let catalog,
              let letter = state.letters.first(where: { $0.id == letterId }),
              let city = catalog.find(letter.subjectCityId), !city.isPlaceholder else { return }
        let generation = backgroundGeneration
        let language = l10n.language
        let key = PlaceKey(letterId: letter.id, language: language)
        let attempts = enrichAttempts[letter.id, default: 0]
        let includeWeatherAndPhoto = weatherAndPhoto && !letter.enrichmentDone && attempts < 3
            && !enrichingLetters.contains(letter.id)
        let includePlace = letter.place[language.rawValue] == nil && city.wikipedia[language.rawValue]?.isEmpty == false
            && placeAttempts[key, default: 0] < 3 && !enrichingPlaces.contains(key)
        let includePhoto = includeWeatherAndPhoto && placeAttempts[key, default: 0] < 3
            && !enrichingPlaces.contains(key)
        guard includeWeatherAndPhoto || includePlace else { return }
        // The summary request is shared with photo enrichment. Do not duplicate it while a place read is in flight.
        guard !includeWeatherAndPhoto || !enrichingPlaces.contains(key) else { return }
        if includeWeatherAndPhoto {
            enrichAttempts[letter.id] = attempts + 1
            enrichingLetters.insert(letter.id)
        }
        if includePlace || includePhoto {
            placeAttempts[key, default: 0] += 1
            enrichingPlaces.insert(key)
        }
        defer {
            if includeWeatherAndPhoto { enrichingLetters.remove(letter.id) }
            if includePlace || includePhoto { enrichingPlaces.remove(key) }
        }
        let coordinate = letter.transitTargetId == nil ? catalog.city(letter.cityId).coordinate : state.position
        let result = await enrichmentReader(Enricher.Query(
            city: city, coordinate: coordinate, language: language,
            includeWeather: includeWeatherAndPhoto, includePhoto: includePhoto, includePlace: includePlace
        ))
        guard !isLocked, generation == backgroundGeneration, var updatedState = self.state,
              let index = updatedState.letters.firstIndex(where: { $0.id == letter.id && $0.subjectCityId == letter.subjectCityId }) else { return }
        if includeWeatherAndPhoto {
            let photoFile = result.photoData.flatMap { savePhoto($0, letterId: letter.id) }
            updatedState.letters[index].weatherCode = result.weatherCode ?? updatedState.letters[index].weatherCode
            updatedState.letters[index].temperatureC = result.temperatureC ?? updatedState.letters[index].temperatureC
            updatedState.letters[index].photoFile = photoFile ?? updatedState.letters[index].photoFile
            let updated = updatedState.letters[index]
            updatedState.letters[index].enrichmentDone = (updated.weatherCode != nil && updated.photoFile != nil) || attempts >= 2
        }
        if includePlace, let place = result.place[language.rawValue] {
            updatedState.letters[index].place[language.rawValue] = place
        }
        guard updatedState != self.state else { return }
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
            if let care {
                if case .loaded(let saved) = store.care, saved == care { return }
                try store.save(care)
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
        processLetters()
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
