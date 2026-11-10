import AppKit
import Foundation
import Observation
import VoyageCore

@MainActor
@Observable
final class AppModel {
    private(set) var state: JourneyState?
    let catalog: CityCatalog?
    let themes: ThemeCatalog?
    private(set) var systemScheme: ThemeScheme
    private let appearanceOverride: ThemeScheme?
    @ObservationIgnored var onAppearanceChange: (() -> Void)?
    var appearancePreference: AppearancePreference {
        didSet {
            if !isSnapshot { defaults.set(appearancePreference.rawValue, forKey: "appearance") }
            onAppearanceChange?()
        }
    }
    var theme: AppTheme {
        let scheme = appearanceOverride ?? (appearancePreference == .dark ? .dark : appearancePreference == .light ? .light : systemScheme)
        guard let themes else { return AppTheme(recoveryScheme: scheme) }
        return AppTheme(appearanceOverride.map { themes.standard($0) } ?? appearancePreference.resolve(system: systemScheme, catalog: themes))
    }
    func systemAppearanceChanged(to scheme: ThemeScheme) {
        guard systemScheme != scheme else { return }
        systemScheme = scheme
        if appearancePreference == .system { onAppearanceChange?() }
    }
    private let contentFailed: Bool
    private(set) var now = Date() {
        didSet { dashboardStore.updateToday(DayKey.string(from: now)) }
    }
    private(set) var lastScan: Date?
    private(set) var lastError: (any Error)?
    private var usageFailed = false
    private(set) var isMoving = false
    /// Display-only daily km for the trend bars. Days before the journey started never add mileage.
    private(set) var history: [String: Double] = [:]
    /// Display-only usage detail, kept apart from the journey.
    private(set) var todayTotals: UsageTotals?
    private(set) var dashboardDays: [DayDetail]? {
        didSet { updateDashboardInput() }
    }
    let dashboardStore = DashboardStore()
    let quotaRuntime: QuotaRuntime
    var quotas: [QuotaReading] { QuotaSource.allCases.flatMap { quotaRuntime.account($0).displayedReadings } }
    var quotasLoadedAt: Date? { quotas.map(\.readAt).min() }
    private(set) var isLocked: Bool
    private(set) var recoveryIssues: [SaveRecoveryIssue] = []
    private(set) var recoveryError: AppError?
    private(set) var care: CareState?
    private(set) var isSavingWish = false
    private var wishSaveGeneration = 0
    private let wishModel: WishContent.Model?
    private let wishTimeout: Duration
    private(set) var onboarding: OnboardingFlow?
    var tab: MainTab = .home
    private(set) var homePage: HomePage = .room
    private var displayedPetMoment: Stage?
    private(set) var presentedBoxID: String?
    private(set) var boxResult: BoxResult?
    private(set) var mainWindowPresented = false
    private(set) var floatingReaction = false
    private(set) var floatingJump = false
    private let floatingReactionDuration: Duration
    private var reactionIndex = 0
    private var reactionTask: Task<Void, Never>?
    var mailFilter: MailFilter = .all
    var collectionTab: CollectionTab = .passport
    var dataTab: DataTab = .dashboard
    var selectedLetterID: Int?
    private(set) var ritualLetterID: Int?
    private(set) var deferredReplyLetterID: Int?
    var showingSettings = false
    var showingAccounts = false
    var archiveError: (any Error)?
    let loginItem: LoginItemSetting
    let notifications: LetterNotificationService
    @ObservationIgnored var onNotificationOpen: (() -> Void)?
    var morningNotificationsEnabled: Bool {
        didSet { if !isSnapshot { defaults.set(morningNotificationsEnabled, forKey: "morningNotifications") } }
    }
    var deliveryTime: DeliveryTime {
        didSet { if !isSnapshot { defaults.set(deliveryTime.rawValue, forKey: "deliveryTime") } }
    }
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
    var petName: String { care?.petName ?? state.map { catalog?.pets.find($0.pet)?.names["zh-Hans"] ?? $0.pet.rawValue } ?? "" }

    private let dataDirectory: URL
    private let store: SaveStore
    private let isSnapshot: Bool
    var isSnapshotMode: Bool { isSnapshot }
    private let clock: () -> Date
    private let onboardingSeed: UInt32
    private let onboardingReader: OnboardingFlow.UsageReader
    private let usageReader: @Sendable (String?, String) async throws -> [DayDetail]
    private let hoursReader: @Sendable (String, String) async throws -> [HourUsage]
    private let enrichmentReader: Enricher.Fetch
    /// Persistence tests can finish onboarding without installing OS observers or starting scans.
    private let runtimeEnabled: Bool
    private let watcherRoots: @Sendable () -> [String]
    private var watcher: FileWatcher?
    private var timers: [Timer] = []
    private var wakeObserver: NSObjectProtocol?
    private var nightWorkObserver = NightWorkObserver()
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
    private var monthHours: [HourUsage] = [] {
        didSet { updateDashboardInput() }
    }
    private var todayHours: [HourUsage] = [] {
        didSet { updateDashboardInput() }
    }

    private static let minScanInterval: TimeInterval = 60
    private static let fallbackScanInterval: TimeInterval = 300
    private static let dashboardMaxAge: TimeInterval = 300
    /// A 30-day hourly read costs about a minute of CPU; a single day costs seconds.
    private static let monthHoursMaxAge: TimeInterval = 3600

    init(isSnapshot: Bool = false, languageOverride: Language? = nil, appearanceOverride: ThemeScheme? = nil, systemScheme: ThemeScheme? = nil, defaults: UserDefaults = .standard, directory: URL? = nil, catalog: CityCatalog? = nil, contentDirectory: URL? = nil, themes: ThemeCatalog? = nil,
         now: @escaping () -> Date = Date.init, onboardingSeed: UInt32 = UInt32.random(in: 0...UInt32.max),
         onboardingReader: @escaping OnboardingFlow.UsageReader = OnboardingFlow.readLocalUsage,
         quotaReader: @escaping @Sendable () async throws -> [ProviderQuota] = UsageSource.fetchQuotas,
         credentialReader: @escaping LocalCredentials.Reader = { try await LocalCredentials().read($0) },
         quotaTransport: any QuotaTransport = ProviderQuotaTransport(),
         quotaNow: @escaping @Sendable () -> Date = Date.init,
         quotaTimeout: Duration = .seconds(20),
         usageReader: @escaping @Sendable (String?, String) async throws -> [DayDetail] = UsageSource.fetch,
         hoursReader: @escaping @Sendable (String, String) async throws -> [HourUsage] = UsageSource.fetchHours,
         enrichmentReader: @escaping Enricher.Fetch = { await Enricher.fetch($0) },
         wishModel: WishContent.Model? = { try await LocalWishModel.selectTags(text: $0, language: $1, allowedTags: $2) },
         wishTimeout: Duration = .seconds(3),
         runtimeEnabled: Bool = true, watcherRoots: @escaping @Sendable () -> [String] = FileWatcher.existingRoots,
         notificationCenter: (any LetterNotificationCenter)? = nil,
         loginItemManager: (any LoginItemManaging)? = nil,
         floatingReactionDuration: Duration = .seconds(3)) {
        self.isSnapshot = isSnapshot
        clock = now
        self.now = now()
        self.onboardingSeed = onboardingSeed
        self.onboardingReader = onboardingReader
        quotaRuntime = QuotaRuntime(defaults: defaults, disabled: isSnapshot, credentials: credentialReader,
                                    transport: quotaTransport, otherReader: quotaReader, now: quotaNow, timeout: quotaTimeout)
        self.usageReader = usageReader
        self.hoursReader = hoursReader
        self.enrichmentReader = enrichmentReader
        self.wishModel = wishModel
        self.wishTimeout = wishTimeout
        self.runtimeEnabled = runtimeEnabled
        self.watcherRoots = watcherRoots
        self.floatingReactionDuration = floatingReactionDuration
        self.languageOverride = languageOverride
        self.defaults = defaults
        morningNotificationsEnabled = defaults.object(forKey: "morningNotifications") as? Bool ?? true
        deliveryTime = defaults.string(forKey: "deliveryTime").flatMap(DeliveryTime.init(rawValue:)) ?? .standard
        notifications = LetterNotificationService(defaults: defaults, center: notificationCenter ?? SystemLetterNotificationCenter(enabled: !isSnapshot && runtimeEnabled))
        loginItem = LoginItemSetting(manager: loginItemManager ?? (!isSnapshot && runtimeEnabled ? SystemLoginItem() : nil))
        self.appearanceOverride = isSnapshot ? appearanceOverride : nil
        self.systemScheme = systemScheme ?? ThemeScheme(appearance: NSApp?.effectiveAppearance)
        let savedAppearance = AppearancePreference(rawValue: defaults.string(forKey: "appearance") ?? "system")
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
        let contentRoot = contentDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("Content")
        let loadedThemes = themes ?? (try? ThemeCatalog.load(directory: contentRoot.appendingPathComponent("themes")))
        self.themes = loadedThemes
        if case .theme(let id) = savedAppearance, loadedThemes?.find(id) == nil { appearancePreference = .system }
        else { appearancePreference = savedAppearance }
        let loadedCatalog = catalog ?? (try? CityCatalog.load(directory: contentRoot))
        self.catalog = loadedCatalog
        contentFailed = loadedThemes == nil || (loadedCatalog.map { $0.active.count < 2 } ?? true)
        store = SaveStore(directory: dataDirectory, pets: loadedCatalog?.pets, items: loadedCatalog?.items, journeyMigrations: loadedCatalog.map { .journey(catalog: $0) } ?? SaveMigrations(currentVersion: JourneyState.currentVersion))
        isLocked = true
        dashboardStore.updateToday(DayKey.string(from: self.now))
        guard !contentFailed, let loadedCatalog else {
            recoveryIssues = [SaveRecoveryIssue(file: .journey, problem: .content)]
            return
        }
        if isSnapshot {
            let examples = Snapshots.homeExamples(catalog: loadedCatalog, now: self.now, petName: l10n.defaultPetName(loadedCatalog.pets.defaultID, catalog: loadedCatalog.pets))
            state = examples.journey
            care = examples.care
            isLocked = false
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
        notifications.onOpenLetter = { [weak self] id in
            self?.openNotificationLetter(id)
            self?.onNotificationOpen?()
        }
    }

    var petForm: PetForm { PetForm.current(companionDays: care?.companionDays.count ?? 0) }
    var canArrangeRoom: Bool { care.map(RoomDecor.isUnlocked) ?? false }
    /// Cards wait for the room: mail rituals, weekly boxes and other pages keep their own state.
    var petMoment: Stage? {
        guard mainWindowPresented, !isLocked, onboarding == nil, tab == .home, homePage == .room,
              ritualLetterID == nil, presentedBoxID == nil, !showingSettings, !showingAccounts,
              let care else { return nil }
        return displayedPetMoment ?? PetMilestones.pending(in: care)
    }

    func petMomentDidDisplay(_ stage: Stage) {
        guard !isSnapshot, petMoment == stage, var care else { return }
        displayedPetMoment = stage
        PetMilestones.acknowledge(stage, care: &care)
        self.care = care
        persist()
    }

    func dismissPetMoment() {
        guard let stage = petMoment, var care else { return }
        PetMilestones.acknowledge(stage, care: &care)
        self.care = care
        displayedPetMoment = nil
        persist()
    }

    func showRoomArrangement() {
        guard canArrangeRoom, !isLocked else { return }
        navigate(to: .home)
        homePage = .arrangement
    }

    @discardableResult
    func placeSouvenir(_ id: String?, in slot: RoomSlot) -> Bool {
        guard !isLocked, onboarding == nil, var care, let catalog,
              RoomDecor.place(id, in: slot, care: &care, library: catalog.items) else { return false }
        self.care = care
        persist()
        return true
    }

    var today: DayRecord { state.flatMap { $0.days[$0.openDate] } ?? DayRecord() }
    var nightcapNote: UsageEventNote? { state?.nightcapNote(at: now) }
    var nightcapText: String? { nightcapNote?.texts[l10n.language.rawValue] }
    var roadClueText: String? {
        let key = DayKey.string(from: now)
        return LetterComposer.localized(state?.days[key]?.roadClueDecision?.clue?.texts, l10n: l10n)
    }
    var todayTokens: Int { today.tokens ?? 0 }
    var todayKm: Double { Double(todayTokens) / Double(outboundTokensPerKm) }
    var unread: Int { state?.unreadCount(now: now) ?? 0 }
    var letters: [Letter] { state?.deliveredLetters(now: now) ?? [] }
    var filteredLetters: [Letter] { letters.filter(mailFilter.includes) }

    var usageDisplayState: UsageDisplayState {
        if usageFailed || lastError is UsageError { return .failed }
        if todayTotals == nil && dashboardDays == nil && history.isEmpty && lastScan == nil { return .loading }
        let hasUsage = (state?.totalKm ?? 0) > 0 || history.values.contains { $0 > 0 }
            || (todayTotals?.total ?? 0) > 0 || dashboardDays?.contains { $0.rows.contains { $0.tokens.total > 0 } } == true
        return hasUsage ? .ready : .noUsage
    }

    func openNotificationLetter(_ id: Int?) {
        now = clock()
        mailFilter = .all
        selectedLetterID = id.flatMap { target in letters.first { $0.id == target }?.id }
        navigate(to: .mail)
    }

    func checkNotifications() async {
        guard !isSnapshot, !isLocked, onboarding == nil, let state, let catalog else { return }
        await notifications.evaluate(state: state, now: clock(), l10n: l10n, petName: petName,
                                     catalog: catalog, morningEnabled: morningNotificationsEnabled)
    }

    func navigate(to tab: MainTab) {
        displayedPetMoment = nil
        ritualLetterID = nil
        homePage = .room
        presentedBoxID = nil
        boxResult = nil
        self.tab = tab
        showingSettings = false
        showingAccounts = false
        postOfficeDidDisplay()
    }

    func openPostOffice() { navigate(to: .home) }

    @discardableResult
    func setWish(_ rawText: String) async -> Bool {
        // Blank input means no wish, not an unmatched wish that the next letter apologises for.
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSnapshot, !isLocked, onboarding == nil, let catalog,
              text.count <= WishEngine.characterLimit else { return false }
        refreshWishWeek()
        wishSaveGeneration += 1
        guard text != (care?.wish ?? "") || (!text.isEmpty && care?.wishResolution == nil) else {
            isSavingWish = false
            return true
        }
        let request = wishSaveGeneration
        let generation = backgroundGeneration
        let writtenAt = clock()
        isSavingWish = true
        defer { if request == wishSaveGeneration { isSavingWish = false } }
        let tags = await catalog.wishes.resolve(text, language: l10n.language, model: wishModel, timeout: wishTimeout)
        guard !Task.isCancelled, request == wishSaveGeneration, generation == backgroundGeneration,
              !isLocked, var care else { return false }
        WishEngine.write(text, tags: tags, at: writtenAt, care: &care)
        WishEngine.refreshWeek(at: clock(), care: &care)
        self.care = care
        persist()
        return true
    }

    private func refreshWishWeek() {
        guard !isSnapshot, !isLocked, var care,
              WishEngine.refreshWeek(at: clock(), care: &care) else { return }
        self.care = care
        persist()
    }

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
    var ritualFinishTitle: String {
        ritualRemainingCount > 0 ? l10n("ritual.nextLetter", ritualRemainingCount) : l10n("ritual.putAway")
    }

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
              care.souvenirs.contains(where: { $0.id == id }),
              CareEngine.setShelved(id: id, shelved: shelved, care: &care) else { return false }
        self.care = care
        persist()
        return true
    }

    @discardableResult
    func openFloorParcel(_ id: String) -> Bool {
        guard !isLocked, onboarding == nil, var state, let care,
              HomeFloor.openParcel(id, journey: &state, care: care) else { return false }
        self.state = state
        persist()
        return true
    }

    var petBubble: PetBubble? { care.flatMap { PetBubble.current(letters: letters, care: $0) } }

    func activateBubble(_ bubble: PetBubble) {
        switch bubble {
        case .mail: activateHomeAction()
        case .reply(let id): openCollectionLetter(id)
        case .bag: openCollection(.bag)
        }
    }

    func openCollection(_ collection: CollectionTab) {
        collectionTab = collection
        navigate(to: .collection)
    }

    func showProfile() {
        navigate(to: .home)
        homePage = .profile
    }

    /// Only main-window presentation events record an open for postcard settlement and reunions.
    func setMainWindowPresented(_ presented: Bool) {
        mainWindowPresented = presented
        if !presented { displayedPetMoment = nil }
        if presented {
            processCompanionMail()
            postOfficeDidDisplay()
        }
    }

    func postOfficeDidDisplay(surface: CompanionSurface = .main) {
        guard surface == .main, mainWindowPresented, tab == .home, homePage == .room,
              !showingSettings, ritualLetterID == nil else { return }
        processCompanionMail()
    }

    private func processCompanionMail() {
        refreshWishWeek()
        guard !isSnapshot, !isLocked, onboarding == nil, var state, var care, let catalog else { return }
        now = clock()
        let previousState = state
        let previousCare = care
        CareEngine.open(at: now, journey: &state, care: &care, catalog: catalog)
        guard state != previousState || care != previousCare else { return }
        self.state = state
        self.care = care
        persist()
    }

    var pendingBoxCount: Int { care?.weekly.boxes.count ?? 0 }
    var boxStampCount: Int { presentedBoxID?.hasSuffix("#6") == true ? 6 : 4 }
    var boxFinishTitle: String { l10n(pendingBoxCount > 0 ? "box.next" : "box.keep") }

    func showBoxes() {
        guard pendingBoxCount > 0 else { return }
        navigate(to: .home)
        homePage = .box
        presentedBoxID = care?.weekly.boxes.first
    }

    @discardableResult
    func openPresentedBox() -> BoxResult? {
        guard !isLocked, onboarding == nil, boxResult == nil, let id = presentedBoxID,
              let state, var care, let catalog,
              let result = CareEngine.openBox(id: id, care: &care, library: catalog.items,
                                             date: DayKey.string(from: clock()), journey: state) else { return nil }
        self.care = care
        boxResult = result
        persist()
        return result
    }

    func finishBox() {
        guard boxResult != nil else { return }
        if let next = care?.weekly.boxes.first {
            presentedBoxID = next
            boxResult = nil
        } else {
            openPostOffice()
        }
    }

    var floatingWords: String {
        if let state, let learned = CareEngine.recentLearned(journey: state, limit: 1).first,
           let text = LetterComposer.localized(learned.learnedTexts, l10n: l10n) { return text }
        return l10n(L10n.floatingKeys[reactionIndex % L10n.floatingKeys.count])
    }

    func reactToFloatingClick() {
        reactionTask?.cancel()
        reactionIndex += 1
        floatingReaction = true
        floatingJump = true
        let start = ContinuousClock.now
        let duration = floatingReactionDuration
        reactionTask = Task { [weak self] in
            try? await Task.sleep(until: start.advanced(by: min(.milliseconds(180), duration)), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.floatingJump = false
            try? await Task.sleep(until: start.advanced(by: duration), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.floatingReaction = false
        }
    }

    func endFloatingReaction() {
        reactionTask?.cancel()
        reactionTask = nil
        floatingReaction = false
        floatingJump = false
    }

    @discardableResult
    func openCollectionLetter(_ id: Int?) -> Bool {
        guard let id, let letter = letters.first(where: { $0.id == id }) else { return false }
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
        catalog?.cities(language: l10n.language) ?? []
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

    var recentDays: [(date: String, km: Double)] {
        guard let state else { return [] }
        var keys = [state.openDate]
        let calendar = Calendar.current
        var cursor = DayKey.date(from: state.openDate) ?? now
        for _ in 0..<6 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            keys.append(DayKey.string(from: cursor))
        }
        return keys.reversed().map { key in (key, max(state.days[key]?.km ?? 0, history[key] ?? 0)) }
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
            let watcher = FileWatcher(roots: watcherRoots()) { [weak self] in self?.scheduleScan() }
            watcher.start()
            self.watcher = watcher
        }

        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.fallbackScanInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScan() }
            },
            Timer.scheduledTimer(withTimeInterval: QuotaRuntime.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.quotaTimerFired() }
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
                    self?.nightWorkObserver = NightWorkObserver()
                    self?.scheduleScan()
                    self?.quotaDidWake()
                }
            }
        }
        scheduleScan()
        quotaRuntime.trigger()
    }

    func tick() {
        guard !isLocked else { return }
        now = clock()
        refreshWishWeek()
        // Finalize previous days before advancing their saved timeline to the current clock.
        if !isScanning, onboarding == nil, var state, let catalog,
           state.openDate == DayKey.string(from: now) {
            let previous = state
            let record = state.days[state.openDate] ?? DayRecord()
            state.sync(today: DayUsage(date: state.openDate, fuel: record.fuel, byClient: record.byClient,
                                       observedTokens: record.tokens ?? 0), now: now, catalog: catalog,
                       wishTags: care.map(WishEngine.tags) ?? [],
                       revisitCities: care.map { RevisitStories.unlockedCities(care: $0, library: catalog.stories) } ?? [],
                       deliveryTime: deliveryTime)
            // Timers advance the clock without observing another tokscale high-water mark.
            state.days[state.openDate]?.lastObservedAt = previous.days[state.openDate]?.lastObservedAt
            if state != previous {
                self.state = state
                processLetters(persistChanges: false)
                if state.totalKm > previous.totalKm {
                    isMoving = true
                    lastMovement = now
                }
                persist()
            }
        }
        if let lastMovement, now.timeIntervalSince(lastMovement) > 300 { isMoving = false }
        Task { await checkNotifications() }
    }

    /// The pending preview can call this without another usage scan.
    var canDepartNow: Bool { !isLocked && !isScanning && onboarding == nil && state?.phase == .pending }

    func departNow() {
        guard canDepartNow, var state, let catalog else { return }
        now = clock()
        refreshWishWeek()
        let before = state.totalKm
        state.departNow(now: now, catalog: catalog, wishTags: care.map(WishEngine.tags) ?? [],
                        revisitCities: care.map { RevisitStories.unlockedCities(care: $0, library: catalog.stories) } ?? [])
        self.state = state
        processLetters(persistChanges: false)
        if state.totalKm > before {
            isMoving = true
            lastMovement = now
        }
        persist()
    }

    /// Coalesces change events and keeps at least `minScanInterval` between scans.
    func scheduleScan(immediately: Bool = false) {
        guard !isSnapshot, !isLocked, onboarding == nil, scheduledScan == nil else { return }
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
        refreshWishWeek()
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
        if historyDate == nil {
            let recent = state.days.filter { $0.key < todayKey && ($0.value.tokens ?? $0.value.fuel) > 0 }
                .sorted { $0.key > $1.key }.prefix(14)
            if recent.contains(where: { $0.value.tokens == nil }) || (recent.isEmpty && state.days.values.contains { $0.tokens == nil }) {
                since = min(since, recent.count < 14 ? state.startDate : recent.last!.key)
            }
        }
        do {
            let details = try await usageReader(isSnapshot ? nil : since, todayKey)
            guard !isLocked, generation == backgroundGeneration, var state = self.state else { return }
            let days = details.map(\.usage)
            state.backfillTokens(days)
            let todayDetail = details.first { $0.date == todayKey }
            todayTotals = UsageLedger(days: todayDetail.map { [$0] } ?? []).totals
            if isSnapshot {
                dashboardDays = details
            } else if let todayDetail, var known = dashboardDays {
                known.removeAll { $0.date == todayKey }
                known.append(todayDetail)
                dashboardDays = known
            }
            let today = days.first { $0.date == todayKey } ?? DayUsage(date: todayKey)
            let finalized = days.filter { $0.date < todayKey && $0.date >= state.openDate }
            var hourly: [String: [HourUsage]] = [:]
            let hourlyStart = Calendar.current.date(byAdding: .day, value: -29, to: date).map { DayKey.string(from: $0) } ?? todayKey
            // Each graph/hourly subprocess owns the scan slot in turn; a failed hourly read
            // deliberately leaves this day absent so the engine uses its 23:59 fallback.
            for final in finalized.sorted(by: { $0.date < $1.date }) where final.date >= hourlyStart {
                guard final.observedTokens > (state.days[final.date]?.tokens ?? 0) else { continue }
                if let rows = try? await hoursReader(final.date, final.date) { hourly[final.date] = rows }
                guard !isLocked, generation == backgroundGeneration else { return }
            }
            if needsHistory {
                history = Dictionary(days.map { ($0.date, Double($0.observedTokens) / Double(outboundTokensPerKm)) }, uniquingKeysWith: { _, latest in latest })
                historyDate = todayKey
            }
            // Hourly reads suspend on the main actor; preserve any letter reads/open records made meanwhile.
            guard let latestState = self.state else { return }
            state = latestState
            state.backfillTokens(days)
            let before = state.totalKm
            refreshWishWeek()
            let revisitCities = care.map { RevisitStories.unlockedCities(care: $0, library: catalog.stories) } ?? []
            state.sync(today: today, finalized: finalized, hourly: hourly, now: date, catalog: catalog, wishTags: care.map(WishEngine.tags) ?? [],
                       revisitCities: revisitCities, deliveryTime: deliveryTime)
            nightWorkObserver.observe(today, at: clock(), journey: &state, content: catalog.usageEvents)
            self.state = state
            processLetters(persistChanges: false, weeklyMail: true)
            if state.totalKm > before {
                isMoving = true
                lastMovement = date
            }
            lastError = nil
            usageFailed = false
            lastScan = date
            now = date
            persist()
            await checkNotifications()
            if !isSnapshot { await enrichLatest() }
        } catch {
            guard !isLocked, generation == backgroundGeneration else { return }
            lastScan = date
            lastError = error
            usageFailed = true
        }
    }

    var dashboardHours: [HourUsage] {
        let today = todayHours.first?.date
        return monthHours.filter { $0.date != today } + todayHours
    }

    private func updateDashboardInput() {
        dashboardStore.update(days: dashboardDays, hours: dashboardHours)
    }

    /// Reads the whole history only while the dashboard is showing, sharing the scan's serial slot.
    func loadDashboard() async {
        guard !isLocked, onboarding == nil else { return }
        let generation = backgroundGeneration
        let now = clock()
        let isStale = dashboardLoadedAt.map { now.timeIntervalSince($0) >= Self.dashboardMaxAge } ?? true
        let monthStale = monthHoursLoadedAt.map { now.timeIntervalSince($0) >= Self.monthHoursMaxAge } ?? true
        guard isStale || monthStale, !isScanning else { return }
        isScanning = true
        let until = DayKey.string(from: now)
        do {
            if isStale {
                let days = try await usageReader(nil, until)
                guard !isLocked, generation == backgroundGeneration else { isScanning = false; return }
                dashboardDays = days
                let hours = try await hoursReader(until, until)
                guard !isLocked, generation == backgroundGeneration else { isScanning = false; return }
                todayHours = hours
                dashboardLoadedAt = now
            }
            lastError = nil
            usageFailed = false
        } catch {
            guard !isLocked, generation == backgroundGeneration else { isScanning = false; return }
            lastError = error
            usageFailed = true
        }
        // Released between reads so a scan waiting on the graph can run before the slow hourly read.
        isScanning = false
        guard !isLocked, generation == backgroundGeneration, monthStale,
              let start = Calendar.current.date(byAdding: .day, value: -29, to: now) else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let hours = try await hoursReader(DayKey.string(from: start), until)
            guard !isLocked, generation == backgroundGeneration else { return }
            monthHours = hours
            monthHoursLoadedAt = now
        } catch {
            guard !isLocked, generation == backgroundGeneration else { return }
            lastError = error
            usageFailed = true
        }
    }

    func quotaTimerFired() {
        guard !isLocked, onboarding == nil, !isSnapshot else { return }
        quotaRuntime.trigger()
    }

    func quotaDidWake() { quotaTimerFired() }

    func linkQuota(_ source: QuotaSource) async {
        guard !isLocked, onboarding == nil, !isSnapshot else { return }
        await quotaRuntime.link(source)
    }

    func loadQuotas(force: Bool = false) async {
        guard !isLocked, onboarding == nil, !isSnapshot else { return }
        await quotaRuntime.refresh()
    }

    func markRead(_ letter: Letter) {
        guard !isLocked, onboarding == nil,
              let saved = state?.letters.first(where: { $0.id == letter.id }), saved.deliverAt <= clock() else { return }
        let previousCare = care
        state?.markRead(letter.id)
        if !isSnapshot, var care {
            CareEngine.markCompanion(date: DayKey.string(from: clock()), care: &care)
            self.care = care
        }
        if !saved.read || care != previousCare { persist() }
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
    private func processLetters(persistChanges: Bool = true, weeklyMail: Bool = false) {
        guard !isLocked, onboarding == nil, var state, var care, let catalog else { return }
        let previousState = state
        let previousCare = care
        state.enableWeeklyMail(on: DayKey.string(from: clock()))
        state.enableRoadClues(on: DayKey.string(from: clock()))
        state.enableUsageEvents(on: DayKey.string(from: clock()))
        WishEngine.refreshWeek(at: clock(), care: &care)
        let wishTags = WishEngine.tags(in: care)
        CareEngine.process(journey: &state, care: &care, stories: catalog.stories, catalog: catalog, wishTags: wishTags)
        if weeklyMail {
            CareEngine.writeWeeklyMail(journey: &state, catalog: catalog, deliveryTime: deliveryTime)
        }
        guard state != previousState || care != previousCare else { return }
        self.state = state
        self.care = care
        if persistChanges { persist() }
    }

    /// Only available on the first day, when nothing has been settled and today can simply be replayed.
    func setStart(_ cityId: String) {
        guard canChangeStart, var replacement = state, let catalog, catalog.find(cityId)?.status == "active", cityId != replacement.homeCityId else { return }
        replacement.setStart(cityId, now: clock(), catalog: catalog)
        self.state = replacement
        enrichAttempts = [:]
        persist()
        Task { await enrichLatest() }
    }

    func photoURL(_ letter: Letter) -> URL? {
        guard let name = letter.photoFile, name.wholeMatch(of: /letter-[0-9]+\.png/) != nil else { return nil }
        return dataDirectory.appendingPathComponent("photos").appendingPathComponent(name)
    }

    /// Scans proactively enrich only the newest letter, including its current-language place.
    func enrichLatest() async {
        guard let letter = state?.letters.filter({ $0.kind != .weekly }).max(by: { $0.id < $1.id }) else { return }
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
              ![.postcard, .reunion, .weekly].contains(letter.kind),
              let city = catalog.find(letter.subjectCityId), !city.isPlaceholder else { return }
        let generation = backgroundGeneration
        let language = l10n.language
        let key = PlaceKey(letterId: letter.id, language: language)
        let attempts = enrichAttempts[letter.id, default: 0]
        let includeWeatherAndPhoto = weatherAndPhoto && !letter.enrichmentDone && attempts < 3
            && !enrichingLetters.contains(letter.id)
        let includePlace = letter.place[language.rawValue] == nil
            && (city.wikipedia[language.rawValue]?.isEmpty == false || city.wikidata != nil)
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
        guard !isLocked, let png = Enricher.pixelate(data, palette: theme.definition!.photoPalette) else { return nil }
        let directory = dataDirectory.appendingPathComponent("photos")
        let name = "letter-\(letterId).png"
        do {
            try PrivateStorage.createDirectory(at: directory)
            try PrivateStorage.write(png, to: directory.appendingPathComponent(name))
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
        guard !isLocked, !isSnapshot, var saves = onboarding?.saves(now: clock(), l10n: l10n) else { return }
        MemoryBook.backfill(journey: saves.journey, care: &saves.care)
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
        // Discard results from reads started against the previous journey.
        backgroundGeneration += 1
        displayedPetMoment = nil
        nightWorkObserver = NightWorkObserver()
        dashboardDays = nil
        dashboardLoadedAt = nil
        monthHoursLoadedAt = nil
        monthHours = []
        todayHours = []
        todayTotals = nil
        history = [:]
        historyDate = nil
        lastScan = nil
        usageFailed = false
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
        placeAttempts = [:]
        selectedLetterID = nil
        ritualLetterID = nil
        deferredReplyLetterID = nil
        lastError = nil
        processLetters()
        start()
        onLockChange?()
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }

    func exportSave(to url: URL) {
        do { try store.exportArchive(to: url, appVersion: Self.appVersion); archiveError = nil }
        catch { archiveError = error }
    }

    func validateImport(at url: URL) throws -> ValidatedSaveArchive { try store.validateArchive(at: url) }

    func reportImportError(_ error: any Error) {
        archiveError = error
        recoveryError = .restore(error)
    }

    @discardableResult
    func importSave(_ candidate: ValidatedSaveArchive) -> Bool {
        do {
            try store.importArchive(candidate)
            archiveError = nil
            resumeAfterRecovery()
            return true
        } catch {
            archiveError = error
            recoveryError = .restore(error)
            refreshSaveStatus()
            return false
        }
    }

    func openDataFolder() {
        do {
            try PrivateStorage.createDirectory(at: dataDirectory)
            NSWorkspace.shared.open(dataDirectory)
        } catch { archiveError = error }
    }

    /// In-memory states for snapshot rendering only; no system APIs or saves are touched.
    func withSnapshotTime(_ date: Date, render: () -> Void) {
        precondition(isSnapshot)
        let previous = now
        defer { now = previous }
        now = date
        render()
    }

    func withSnapshotUsage(_ value: UsageDisplayState, render: () -> Void) {
        precondition(isSnapshot)
        let previous = (state, lastScan, lastError, history, todayTotals, dashboardDays, usageFailed)
        defer { (state, lastScan, lastError, history, todayTotals, dashboardDays, usageFailed) = previous }
        usageFailed = value == .failed
        if value == .failed { lastError = UsageError.missingBinary }
        else {
            if let catalog {
                state = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: catalog)
            }
            lastScan = now
            lastError = nil
            history = [:]
            todayTotals = nil
            dashboardDays = []
        }
        render()
    }

    private static func newJourney(in store: SaveStore, catalog: CityCatalog, now: Date) -> JourneyState {
        let pet: PetID
        if case .loaded(let care) = store.care {
            pet = care.species
        } else {
            pet = catalog.pets.defaultID
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
            quotaRuntime.stop()
            timers.forEach { $0.invalidate() }
            timers = []
            scheduledScan?.cancel()
            scheduledScan = nil
            hasStarted = false
        }
        if wasLocked != isLocked, isLocked { onLockChange?() }
    }
}
