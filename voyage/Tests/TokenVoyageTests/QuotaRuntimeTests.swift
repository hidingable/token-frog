import Foundation
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private let quotaDate = Date(timeIntervalSince1970: 1_799_424_000)
private let fakeQuotaToken = "VOYAGE-TEST-ONLY-SECRET-918273"

private func quotaResponse(_ used: Int = 35, claude: Bool = false) -> QuotaHTTPResponse {
    let json = claude
        ? "{\"five_hour\":{\"utilization\":\(used),\"resets_at\":null},\"email\":\"fake-account@example.invalid\"}"
        : "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(used),\"reset_at\":1799431200}},\"email\":\"fake-account@example.invalid\"}"
    return QuotaHTTPResponse(statusCode: 200, data: Data(json.utf8))
}

private actor QuotaProbe: QuotaTransport {
    enum Action: Sendable { case response(QuotaHTTPResponse), network, timeout, suspend }
    private var actions: [Action]
    private(set) var calls = 0
    private(set) var credentialCalls = 0
    private(set) var otherCalls = 0
    private(set) var scans = 0
    private var suspended: [CheckedContinuation<QuotaHTTPResponse, Never>] = []

    init(_ actions: [Action] = []) { self.actions = actions }
    func append(_ action: Action) { actions.append(action) }
    func credential(_ source: QuotaSource) -> QuotaCredential {
        credentialCalls += 1
        return QuotaCredential(accessToken: fakeQuotaToken, accountID: source == .codex ? "fake-account" : nil)
    }
    func other() throws -> [ProviderQuota] {
        otherCalls += 1
        return try QuotaReport.parse(Data("[{\"provider\":\"Codex\",\"metrics\":[{\"label\":\"Weekly\",\"remaining_percent\":40}]},{\"provider\":\"Claude\",\"metrics\":[{\"label\":\"Weekly\",\"remaining_percent\":50}]},{\"provider\":\"Copilot\",\"email\":\"fake@example.invalid\",\"metrics\":[{\"label\":\"Premium\",\"remaining_percent\":10}]}]".utf8))
    }
    func usage(until: String) throws -> [DayDetail] {
        scans += 1
        let json = "{\"contributions\":[{\"date\":\"\(until)\",\"clients\":[{\"client\":\"codex\",\"modelId\":\"fake-model\",\"tokens\":{\"input\":\(scans * 1000),\"output\":100,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0}}]}]}"
        return try TokscaleGraph.parseDetails(Data(json.utf8))
    }
    func send(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        calls += 1
        let action = actions.isEmpty ? .response(quotaResponse(claude: request.url?.host == "api.anthropic.com")) : actions.removeFirst()
        switch action {
        case .response(let response): return response
        case .network: throw NSError(domain: fakeQuotaToken, code: 1, userInfo: [NSLocalizedDescriptionKey: fakeQuotaToken])
        case .timeout: throw URLError(.timedOut)
        case .suspend: return await withCheckedContinuation { suspended.append($0) }
        }
    }
    func release(_ response: QuotaHTTPResponse = quotaResponse(99)) {
        let pending = suspended
        suspended = []
        pending.forEach { $0.resume(returning: response) }
    }
}

private final class QuotaDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private final class QuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = quotaDate
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@MainActor private func runtime(_ probe: QuotaProbe, defaults: QuotaDefaults = QuotaDefaults(),
                                clock: QuotaClock = QuotaClock(), timeout: Duration = .seconds(5), disabled: Bool = false) -> QuotaRuntime {
    QuotaRuntime(defaults: defaults, disabled: disabled, credentials: { await probe.credential($0) },
                 transport: probe, otherReader: { try await probe.other() }, now: { clock.read() }, timeout: timeout)
}

@MainActor private func waitQuota(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await condition())
}

@MainActor
@Test func quotaUnlinkedRuntimeNeverReadsAnySource() async {
    let probe = QuotaProbe()
    let runtime = runtime(probe)
    runtime.trigger()
    await runtime.refresh()
    #expect(!runtime.hasLinkedAccounts)
    #expect(await probe.calls == 0)
    #expect(await probe.credentialCalls == 0)
    #expect(await probe.otherCalls == 0)
    #expect(QuotaSource.allCases.allSatisfy { runtime.account($0).displayedReadings.isEmpty })
}

@MainActor
@Test(arguments: [200, 401, 403, 429, 500])
func quotaHTTPStatusesAreSemanticAndFailedLinksAreNotSaved(_ status: Int) async {
    let probe = QuotaProbe([.response(status == 200 ? quotaResponse() : QuotaHTTPResponse(statusCode: status, data: Data(fakeQuotaToken.utf8)))])
    let defaults = QuotaDefaults()
    let runtime = runtime(probe, defaults: defaults)
    await runtime.link(.codex)
    switch status {
    case 200: #expect(runtime.account(.codex).status == .ok)
    case 401, 403: #expect(runtime.account(.codex).status == .expired)
    case 429: #expect(runtime.account(.codex).status == .rateLimited(until: quotaDate.addingTimeInterval(30)))
    default: #expect(runtime.account(.codex).status == .unavailable(.service))
    }
    #expect(runtime.account(.codex).linked == (status == 200))
    #expect(defaults.values[QuotaRuntime.key(.codex)] as? Bool == (status == 200 ? true : nil))
    #expect(!String(describing: runtime.account(.codex)).contains(fakeQuotaToken))
    #expect(await probe.calls == 1)
    runtime.stop()
}

@MainActor
@Test func quotaRetryAfterAndExponentialBackoffAreHonored() async {
    let defaults = QuotaDefaults()
    defaults.set(true, forKey: QuotaRuntime.key(.codex))
    let clock = QuotaClock()
    let probe = QuotaProbe([
        .response(QuotaHTTPResponse(statusCode: 429, headers: ["rEtRy-AfTeR": "120"])),
        .response(QuotaHTTPResponse(statusCode: 429)),
        .response(quotaResponse()),
    ])
    let runtime = runtime(probe, defaults: defaults, clock: clock)
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .rateLimited(until: quotaDate.addingTimeInterval(120)))
    await runtime.refresh()
    #expect(await probe.calls == 1)
    clock.advance(120)
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .rateLimited(until: quotaDate.addingTimeInterval(180)))
    clock.advance(59)
    await runtime.refresh()
    #expect(await probe.calls == 2)
    clock.advance(1)
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .ok)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    let future = quotaDate.addingTimeInterval(240)
    #expect(QuotaRuntime.retryAfter(["Retry-After": formatter.string(from: future)], now: quotaDate) == future)
    #expect(QuotaRuntime.retryAfter(["Retry-After": "not a date"], now: quotaDate) == nil)
    runtime.stop()
}

@MainActor
@Test func quotaKeepsLastGoodReadingAndTimestampWhenARefreshFails() async {
    let probe = QuotaProbe([.response(quotaResponse()), .network])
    let clock = QuotaClock()
    let runtime = runtime(probe, clock: clock)
    await runtime.link(.codex)
    let reading = runtime.account(.codex).readings
    clock.advance(600)
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .stale(lastGoodAt: quotaDate))
    #expect(runtime.account(.codex).displayedReadings == reading)
    #expect(runtime.account(.codex).failure == .unavailable(.network))
    #expect(!String(describing: runtime.account(.codex)).contains(fakeQuotaToken))
    runtime.stop()
}

@MainActor
@Test func quotaExponentialBackoffStopsAtOneHour() async {
    let defaults = QuotaDefaults()
    defaults.set(true, forKey: QuotaRuntime.key(.codex))
    let probe = QuotaProbe((0..<10).map { _ in .response(QuotaHTTPResponse(statusCode: 429)) })
    let clock = QuotaClock()
    let runtime = runtime(probe, defaults: defaults, clock: clock)
    for delay in [30.0, 60, 120, 240, 480, 960, 1920, 3600, 3600, 3600] {
        await runtime.refresh()
        #expect(runtime.account(.codex).status == .rateLimited(until: clock.read().addingTimeInterval(delay)))
        clock.advance(delay)
    }
    #expect(await probe.calls == 10)
    runtime.stop()
}

@MainActor
@Test(arguments: [401, 403])
func quotaExpiredReadingsAreRetainedOnlyInMemoryWithoutAutomaticRetries(_ code: Int) async {
    let probe = QuotaProbe([.response(quotaResponse()), .response(QuotaHTTPResponse(statusCode: code))])
    let runtime = runtime(probe)
    await runtime.link(.codex)
    let lastGood = runtime.account(.codex).readings
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .expired)
    #expect(runtime.account(.codex).readings == lastGood)
    #expect(runtime.account(.codex).displayedReadings.isEmpty)
    #expect(await probe.calls == 2)
    runtime.trigger()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await probe.calls == 2)
    // An explicit manual refresh can recover after the user signs in in the original tool.
    await runtime.refresh()
    #expect(runtime.account(.codex).status == .ok)
    #expect(await probe.calls == 3)
    runtime.disconnect(.codex)
    await runtime.refresh()
    #expect(await probe.calls == 3)
}

@MainActor
@Test func disconnectBeforeAQueuedRefreshStartsPreventsCredentialReads() async {
    let defaults = QuotaDefaults()
    defaults.set(true, forKey: QuotaRuntime.key(.codex))
    let probe = QuotaProbe()
    let runtime = runtime(probe, defaults: defaults)
    runtime.trigger()
    runtime.disconnect(.codex)
    await Task.yield()
    #expect(await probe.calls == 0)
    #expect(await probe.credentialCalls == 0)
    #expect(runtime.account(.codex) == QuotaAccountState())
}

@MainActor
@Test func quotaTransportTimeoutErrorsAreMappedWithoutSavingALink() async {
    let probe = QuotaProbe([.timeout])
    let defaults = QuotaDefaults()
    let runtime = runtime(probe, defaults: defaults)
    await runtime.link(.codex)
    #expect(runtime.account(.codex).status == .unavailable(.timedOut))
    #expect(defaults.values.isEmpty)
}

@MainActor
@Test func quotaTimeoutDoesNotBlockAnotherToolEvenIfTransportIgnoresCancellation() async throws {
    let probe = QuotaProbe([.suspend, .response(quotaResponse(80, claude: true))])
    let runtime = runtime(probe, timeout: .milliseconds(100))
    let codex = Task { await runtime.link(.codex) }
    try await waitQuota { await probe.calls == 1 }
    await runtime.link(.claude)
    #expect(runtime.account(.claude).status == .ok)
    await codex.value
    #expect(runtime.account(.codex).status == .unavailable(.timedOut))
    await probe.release()
    runtime.stop()
}

@MainActor
@Test func quotaLatestRequestWinsAndDisconnectDiscardsInflightResults() async throws {
    let probe = QuotaProbe([.suspend, .response(quotaResponse(20)), .suspend])
    let defaults = QuotaDefaults()
    let runtime = runtime(probe, defaults: defaults)
    let first = Task { await runtime.link(.codex) }
    try await waitQuota { await probe.calls == 1 }
    await runtime.link(.codex)
    await first.value
    #expect(runtime.account(.codex).readings.first?.windows.first?.remainingPercent == 80)
    await probe.release()
    #expect(runtime.account(.codex).readings.first?.windows.first?.remainingPercent == 80)
    let refresh = Task { await runtime.refresh() }
    try await waitQuota { await probe.calls == 3 }
    runtime.disconnect(.codex)
    await probe.release()
    await refresh.value
    runtime.trigger()
    await runtime.refresh()
    #expect(runtime.account(.codex) == QuotaAccountState())
    #expect(!defaults.bool(forKey: QuotaRuntime.key(.codex)))
    #expect(await probe.calls == 3)
    #expect(await probe.credentialCalls == 3)
}

@MainActor
@Test func quotaOtherToolsAreSeparatelyAuthorizedAndExcludeNativeAdapters() async {
    let probe = QuotaProbe()
    let runtime = runtime(probe)
    await runtime.link(.codex)
    #expect(await probe.otherCalls == 0)
    await runtime.link(.otherTools)
    #expect(await probe.otherCalls == 1)
    #expect(await probe.credentialCalls == 1)
    #expect(runtime.account(.otherTools).readings.map(\.providerID) == ["copilot"])
    #expect(!String(describing: runtime.account(.otherTools)).contains("@"))
    runtime.disconnect(.otherTools)
    await runtime.refresh()
    #expect(await probe.otherCalls == 1)
}

@Test func unknownQuotaDisplayNeverInventsAPercentageAndEnglishContainsNoHan() {
    let reading = QuotaReading(providerID: "codex", windows: [QuotaWindow(kind: .weekly, remainingPercent: 0)], readAt: quotaDate)
    let statuses: [QuotaStatus] = [.notLinked, .expired] + QuotaUnavailable.allTestCases.map { .unavailable($0) }
    for status in statuses {
        let account = QuotaAccountState(status: status, readings: [reading])
        #expect(account.displayedReadings.isEmpty)
        for source in QuotaSource.allCases {
            let english = L10n(language: .en).quotaStatus(status, source: source)
            #expect(!english.contains("%"))
            #expect(!containsHan(english))
        }
    }
}

private extension QuotaUnavailable {
    static var allTestCases: [Self] { [.missingLogin, .invalidResponse, .network, .timedOut, .service, .localSource] }
}

@MainActor
private struct QuotaModelFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-quota-\(UUID().uuidString)")
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        let state = JourneyState(seed: 1, startCityId: "shanghai", date: DayKey.string(from: quotaDate), now: quotaDate, catalog: localizationCatalog)
        try store.save(state)
        try store.save(CareState.legacy(from: state, pets: localizationCatalog.pets))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func model(_ probe: QuotaProbe, defaults: QuotaDefaults = QuotaDefaults(), snapshot: Bool = false, runtimeEnabled: Bool = false) -> AppModel {
        AppModel(isSnapshot: snapshot, defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { quotaDate }, quotaReader: { try await probe.other() }, credentialReader: { await probe.credential($0) },
                 quotaTransport: probe, quotaNow: { quotaDate }, usageReader: { _, until in try await probe.usage(until: until) },
                 hoursReader: { _, _ in [] }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: runtimeEnabled, watcherRoots: { [] })
    }
}

@MainActor
@Test func exportingAfterFakeAccountLinkContainsNeitherCredentialsNorTokenFields() async throws {
    let fixture = try QuotaModelFixture()
    defer { fixture.remove() }
    let probe = QuotaProbe()
    let defaults = QuotaDefaults()
    let model = fixture.model(probe, defaults: defaults)
    await model.linkQuota(.codex)
    #expect(model.quotaRuntime.account(.codex).linked)
    #expect(await probe.credentialCalls == 1)
    #expect(await probe.calls == 1)
    let destination = fixture.directory.appendingPathComponent("export.json")
    model.exportSave(to: destination)
    #expect(model.archiveError == nil)
    let bytes = try Data(contentsOf: destination)
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(!text.contains(fakeQuotaToken) && !text.contains("accessToken") && !text.contains("token"))
    let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(json.keys) == ["format", "exportedAt", "appVersion", "journey", "care"])
    model.quotaRuntime.stop()
}

@MainActor
@Test func freshAppStartupScanningQuotaPageAndSnapshotPathsNeverReadCredentials() async throws {
    let fixture = try QuotaModelFixture()
    defer { fixture.remove() }
    let probe = QuotaProbe()
    let model = fixture.model(probe, runtimeEnabled: true)
    model.start()
    await model.scan()
    model.navigate(to: .data)
    model.dataTab = .quota
    _ = QuotaTab(model: model).body
    model.showingAccounts = true
    _ = AccountsView(model: model).body
    await model.loadQuotas(force: true)
    model.quotaTimerFired()
    model.quotaDidWake()
    let defaults = QuotaDefaults()
    for source in QuotaSource.allCases { defaults.set(true, forKey: QuotaRuntime.key(source)) }
    let snapshot = fixture.model(probe, defaults: defaults, snapshot: true)
    snapshot.start()
    await snapshot.scan()
    await snapshot.loadQuotas(force: true)
    await snapshot.linkQuota(.codex)
    snapshot.quotaRuntime.withSnapshotAccounts(Snapshots.quotaExamples(now: quotaDate)) {
        _ = QuotaTab(model: snapshot).body
        _ = AccountsView(model: snapshot).body
    }
    #expect(await probe.calls == 0)
    #expect(await probe.credentialCalls == 0)
    #expect(await probe.otherCalls == 0)
    #expect(snapshot.quotaRuntime.accounts.values.allSatisfy { $0 == QuotaAccountState() })
    model.quotaRuntime.stop()
}

@MainActor
@Test func usageChangesNeverRefreshLinkedQuotaButTimerWakeAndManualDo() async throws {
    let fixture = try QuotaModelFixture()
    defer { fixture.remove() }
    let probe = QuotaProbe()
    let model = fixture.model(probe)
    await model.linkQuota(.codex)
    #expect(await probe.calls == 1)
    for _ in 0..<3 { await model.scan() }
    #expect(await probe.scans == 3)
    #expect(model.lastError == nil)
    #expect(model.todayFuel == 3100)
    #expect(await probe.calls == 1)
    #expect(await probe.otherCalls == 0)
    model.quotaTimerFired()
    try await waitQuota { await probe.calls == 2 && !model.quotaRuntime.account(.codex).isRefreshing }
    model.quotaDidWake()
    try await waitQuota { await probe.calls == 3 && !model.quotaRuntime.account(.codex).isRefreshing }
    await model.loadQuotas(force: true)
    #expect(await probe.calls == 4)
    model.quotaRuntime.stop()
}

@MainActor
@Test func fakeCredentialsNeverEnterDefaultsSavesDisplayReadingsOrAppErrors() async throws {
    let fixture = try QuotaModelFixture()
    defer { fixture.remove() }
    let probe = QuotaProbe([.response(quotaResponse()), .network])
    let defaults = QuotaDefaults()
    let model = fixture.model(probe, defaults: defaults)
    await model.linkQuota(.codex)
    await model.loadQuotas(force: true)
    await model.scan()
    let display = String(describing: model.quotas) + String(describing: model.lastError)
        + String(describing: model.quotaRuntime.accounts) + String(describing: defaults.values)
    #expect(!display.contains(fakeQuotaToken))
    #expect(!display.contains("fake-account@example.invalid"))
    #expect(defaults.values.values.allSatisfy { $0 is Bool })
    for file in try quotaFiles(in: fixture.directory) {
        #expect(!(try Data(contentsOf: file)).contains(Data(fakeQuotaToken.utf8)))
    }
    model.quotaRuntime.stop()
}

private func quotaFiles(in directory: URL) throws -> [URL] {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    return try files.compactMap { item in
        guard let file = item as? URL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
        return file
    }
}
