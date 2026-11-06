import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class SettingsDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private actor RecoveringUsage {
    var calls = 0
    func read() throws -> [DayDetail] {
        calls += 1
        if calls == 1 { throw UsageError.missingBinary }
        return [DayDetail(date: "2026-11-01", rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: 1_000_000))])]
    }
}

private actor SuspendedSettingsUsage {
    private(set) var started = false
    private var continuation: CheckedContinuation<[DayDetail], Never>?
    func read() async -> [DayDetail] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() {
        continuation?.resume(returning: [DayDetail(date: "2026-11-01", rows: [UsageRow(client: "codex", model: "old", tokens: UsageTotals(input: 5_000_000))])])
        continuation = nil
    }
}

@MainActor private final class SettingsNotificationCenter: LetterNotificationCenter {
    var onResponse: (@MainActor (Int?) -> Void)?
    var sent: [LetterNotification] = []
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func send(_ notification: LetterNotification) async throws { sent.append(notification) }
}

@MainActor private final class TestLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var fail = false
    func setEnabled(_ enabled: Bool) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        status = enabled ? .enabled : .disabled
    }
}

@MainActor private final class SettingsClock {
    var now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 8, minute: 59))!
}

@MainActor private struct SettingsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-settings-\(UUID().uuidString)")
    let defaults = SettingsDefaults()
    let clock = SettingsClock()
    let store: SaveStore

    init(withLetter: Bool = false) throws {
        store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: .distantPast, catalog: localizationCatalog)
        if withLetter {
            journey.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01", fuel: 1_000_000)], catalog: localizationCatalog)
        }
        var care = CareState(petName: "Ginkgo", species: journey.pet, hatchedAt: journey.startDate)
        CareEngine.process(journey: &journey, care: &care, stories: localizationCatalog.stories, catalog: localizationCatalog)
        try store.save(journey)
        try store.save(care)
    }

    func model(center: (any LetterNotificationCenter)? = nil,
               reader: @escaping @Sendable (String?, String) async throws -> [DayDetail] = { _, _ in [] }) -> AppModel {
        AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { clock.now }, usageReader: reader, hoursReader: { _, _ in [] },
                 enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false, notificationCenter: center)
    }

    func bytes(_ file: SaveFile) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(file.rawValue)) }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Test func settingsDefaultsPersistDeliveryAndNotificationPreferences() throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    #expect(model.morningNotificationsEnabled)
    #expect(!model.newCountryNotificationsEnabled)
    #expect(model.deliveryTime == .standard)
    model.deliveryTime = try #require(DeliveryTime(rawValue: "08:30"))
    model.morningNotificationsEnabled = false
    model.newCountryNotificationsEnabled = true
    let reloaded = fixture.model()
    #expect(reloaded.deliveryTime.rawValue == "08:30")
    #expect(fixture.defaults.string(forKey: "deliveryTime") == "08:30")
    #expect(!reloaded.morningNotificationsEnabled && reloaded.newCountryNotificationsEnabled)
}

@MainActor @Test func existingTickDeliversMailWhenRunningBeforeNine() async throws {
    let fixture = try SettingsFixture(withLetter: true)
    defer { fixture.cleanUp() }
    let center = SettingsNotificationCenter()
    let model = fixture.model(center: center)
    // The initial logbook was already read; only the newly settled daily letter is pending.
    if let first = model.letters.first { model.markRead(first) }
    await model.checkNotifications()
    #expect(center.sent.isEmpty)
    fixture.clock.now = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: fixture.clock.now)!
    model.tick()
    for _ in 0..<100 where center.sent.isEmpty { await Task.yield() }
    #expect(center.sent.count == 1)
    #expect(center.sent.first?.letterID == model.letters.first?.id)
}

@MainActor @Test func clickingNotificationOpensSpecifiedLetterAndMissingLetterOpensMailbox() throws {
    let fixture = try SettingsFixture(withLetter: true)
    defer { fixture.cleanUp() }
    fixture.clock.now.addTimeInterval(3600)
    let center = SettingsNotificationCenter()
    let model = fixture.model(center: center)
    let letter = try #require(model.letters.first)
    var opened = 0
    model.onNotificationOpen = { opened += 1 }
    model.showingSettings = true
    model.showingAccounts = true
    center.onResponse?(letter.id)
    #expect(model.tab == .mail && model.selectedLetterID == letter.id)
    #expect(!model.showingAccounts && !model.showingSettings && opened == 1)
    center.onResponse?(Int.max)
    #expect(model.tab == .mail && model.selectedLetterID == nil && opened == 2)
    center.onResponse?(nil)
    #expect(model.tab == .mail && model.selectedLetterID == nil && opened == 3)
}

@MainActor @Test func loginItemFailureAndApprovalHaveExplanationsAndDoNotChangeToggle() {
    let manager = TestLoginItem()
    let setting = LoginItemSetting(manager: manager)
    setting.setEnabled(true)
    #expect(setting.enabled && setting.explanationKey == nil)
    manager.fail = true
    setting.setEnabled(false)
    #expect(setting.enabled && setting.explanationKey == "settings.loginFailed")
    manager.status = .requiresApproval
    let approval = LoginItemSetting(manager: manager)
    #expect(approval.enabled && approval.explanationKey == "settings.loginApproval")
    #expect(LoginItemSetting(manager: nil).explanationKey == "settings.loginUnavailable")
}

@MainActor @Test func noUsageHasTheSameExplanationInHomeAndDashboard() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    await model.scan()
    await model.loadDashboard()
    #expect(model.usageDisplayState == .noUsage)
    #expect(model.usageDisplayState.messageKey == "usage.noRecords")
    #expect(model.dashboardDays == [])
    for language in Language.allCases {
        let text = L10n(language: language)("usage.noRecords")
        #expect(text.contains(language == .en ? "this Mac" : "本机"))
    }
}

@MainActor @Test(arguments: ["missing", "exit", "parse"])
func usageFailureRetainsJourneyAndShowsRecoverableExplanation(mode: String) async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let model = fixture.model { _, _ in
        if mode == "missing" { throw UsageError.missingBinary }
        if mode == "exit" { throw UsageError.failed(17) }
        throw CocoaError(.coderReadCorrupt)
    }
    let original = model.state
    let journey = try fixture.bytes(.journey)
    let care = try fixture.bytes(.care)
    await model.scan()
    #expect(!model.isLocked && model.state == original)
    #expect(model.usageDisplayState == .failed)
    #expect(model.usageDisplayState.messageKey == "usage.recoverableFailure")
    #expect(try fixture.bytes(.journey) == journey && fixture.bytes(.care) == care)
}

@MainActor @Test func retryAfterUsageFailureAutomaticallyCatchesUpWithoutLosingTheJourney() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let reader = RecoveringUsage()
    let model = fixture.model { _, _ in try await reader.read() }
    await model.scan()
    #expect(model.usageDisplayState == .failed)
    await model.scan()
    #expect(model.lastError == nil && model.usageDisplayState == .ready)
    #expect(model.state?.totalFuel == 1_000_000)
    #expect(model.state?.letters.filter { $0.kind == .daily }.count == 1)
    #expect(await reader.calls == 2)
}

@MainActor @Test func offlineEnrichmentStillSettlesMailWithoutWeatherPlaceOrError() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let model = fixture.model { _, _ in
        [DayDetail(date: "2026-11-01", rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: 1_000_000))])]
    }
    await model.scan()
    let letter = try #require(model.state?.letters.last)
    #expect(letter.kind == .daily && letter.texts?.isEmpty == false)
    #expect(letter.weatherCode == nil && letter.temperatureC == nil && letter.place.isEmpty)
    #expect(model.lastError == nil && model.usageDisplayState == .ready)
}

@MainActor @Test func importingReplacesBothModelStatesAndClearsStalePresentationWithoutRestart() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let source = try SettingsFixture(withLetter: true)
    defer { source.cleanUp() }
    let model = fixture.model()
    await model.scan()
    await model.loadDashboard()
    let candidate = try fixture.store.validateArchive(source.store.exportArchive(appVersion: "test"))
    model.selectedLetterID = 99
    #expect(model.importSave(candidate))
    #expect(model.state == candidate.journey && model.care == candidate.care)
    #expect(model.dashboardDays == nil && model.todayTotals == nil && model.history.isEmpty)
    #expect(model.selectedLetterID == nil && model.onboarding == nil && !model.isLocked)
    #expect(try JSONDecoder().decode(JourneyState.self, from: fixture.bytes(.journey)) == candidate.journey)
    #expect(try JSONDecoder().decode(CareState.self, from: fixture.bytes(.care)) == candidate.care)
}

@MainActor @Test func scanStartedBeforeImportCannotOverwriteTheImportedJourney() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.cleanUp() }
    let source = try SettingsFixture(withLetter: true)
    defer { source.cleanUp() }
    let reader = SuspendedSettingsUsage()
    let model = fixture.model { _, _ in await reader.read() }
    let running = Task { await model.scan() }
    while !(await reader.started) { await Task.yield() }
    let candidate = try fixture.store.validateArchive(source.store.exportArchive(appVersion: "test"))
    #expect(model.importSave(candidate))
    await reader.release()
    await running.value
    #expect(model.state == candidate.journey && model.care == candidate.care)
    #expect(model.lastScan == nil && model.dashboardDays == nil && model.lastError == nil)
}

@Test(arguments: Language.allCases) func archiveErrorsAreLocalizedAndNeverEchoFileContents(language: Language) {
    let l10n = L10n(language: language)
    for error: SaveArchiveError in [.tooLarge, .unreadable, .invalidArchive, .unsupportedFormat(9), .newerSave(file: .journey, version: 999), .invalidSave(.care), .unavailable, .writeFailed, .recoveryRequired] {
        let text = l10n.archiveError(error)
        #expect(!text.hasPrefix("archive.") && !text.isEmpty)
        if language == .en { #expect(!containsHan(text)) }
    }
    let injected = NSError(domain: "private", code: 1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE FILE CONTENT"])
    #expect(!l10n.archiveError(injected).contains("PRIVATE FILE CONTENT"))
    #expect(!l10n("settings.privacy").hasPrefix("settings."))
}
