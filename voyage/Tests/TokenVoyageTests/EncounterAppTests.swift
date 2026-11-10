import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@MainActor private final class EncounterClock {
    var now: Date
    init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))! }
}

private final class EncounterDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = ["cityContentEnabled": false, "wishResolveEnabled": false]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private actor EncounterUsage {
    var values: [String: Int] = [:]
    func set(_ date: String, _ total: Int) { values[date] = total }
    func read() -> [DayDetail] {
        values.map { DayDetail(date: $0.key, rows: [UsageRow(client: "codex", model: "private-model", tokens: UsageTotals(input: $0.value))]) }
    }
}

private actor EncounterTransport {
    var requests: [URLRequest] = []
    var serverEnabled = true
    var pairedPost = false
    var pairedGet = false
    var postStatus = 200
    var holdPost = false
    var postGate: CheckedContinuation<Void, Never>?
    var postWaiters: [CheckedContinuation<Void, Never>] = []
    var persistedBeforeSend = false
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func configure(enabled: Bool = true, pairedPost: Bool = false, pairedGet: Bool = false, postStatus: Int = 200, holdPost: Bool = false) {
        serverEnabled = enabled; self.pairedPost = pairedPost; self.pairedGet = pairedGet
        self.postStatus = postStatus; self.holdPost = holdPost
    }
    func snapshot() -> [URLRequest] { requests }
    func savedBeforeSend() -> Bool { persistedBeforeSend }
    func waitForPost() async {
        if requests.contains(where: { $0.httpMethod == "POST" }) { return }
        await withCheckedContinuation { postWaiters.append($0) }
    }
    func release() { postGate?.resume(); postGate = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let paired = request.httpMethod == "POST" ? pairedPost : pairedGet
        var json: String
        var status = 200
        if path == "/v1/config" {
            json = "{\"schemaVersion\":1,\"cityContentEnabled\":false,\"wishResolveEnabled\":false,\"encountersEnabled\":\(serverEnabled),\"sponsorContentEnabled\":false}"
        } else if path == "/v1/sync" || path == "/v1/me" { json = "{}" }
        else {
            if request.httpMethod == "POST" {
                let state = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: directory.appendingPathComponent("journey.json")))
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                persistedBeforeSend = state.encounterStaysByTrip?.values.contains { $0.stayId == body["stayId"] as? String } == true
                postWaiters.forEach { $0.resume() }; postWaiters = []
                if holdPost { await withCheckedContinuation { postGate = $0 } }
                status = postStatus
            }
            json = paired ? #"{"status":"paired","partner":{"appearance":{"species":"snail","stage":"juvenile"}},"pairedAt":"2026-11-10T04:00:00.000Z"}"# : #"{"status":"waiting"}"#
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite @MainActor struct EncounterAppTests {
    private func fixture(configured: Bool = true, photo: Bool = false, previousDay: Bool = false) async throws
        -> (AppModel, EncounterClock, EncounterUsage, EncounterTransport, URL, EncounterDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-encounters-\(UUID().uuidString)")
        let clock = EncounterClock()
        let day = DayKey.string(from: clock.now)
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: day, now: clock.now, catalog: localizationCatalog)
        journey.targetCityId = "quanzhou"
        journey.legTo = localizationCatalog.city("quanzhou").coordinate
        journey.targetCountryCode = "CN"
        journey.legCost = outboundTokensPerKm
        journey.legFuel = outboundTokensPerKm - 1
        if previousDay { journey.openDate = DayKey.string(from: clock.now.addingTimeInterval(-86_400)); journey.startDate = journey.openDate }
        if photo {
            journey.recordEncounter(.init(cityId: "quanzhou", partner: .init(species: "snail", stage: "hatchling"), localDate: day,
                                          own: .init(species: "pigeon", stage: "hatchling")))
        }
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(CareState(petName: "private-name", species: journey.pet, hatchedAt: journey.startDate))
        let usage = EncounterUsage()
        await usage.set(day, 1)
        let probe = EncounterTransport(directory: directory)
        let hub = HubClient(baseURL: configured ? URL(string: "https://voyage.example.invalid") : nil,
                            transport: { try await probe.send($0) }, keyLoader: { Data(repeating: 7, count: 32) })
        let defaults = EncounterDefaults()
        let model = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog,
                             contentDirectory: LocalizationTestFiles.root.appendingPathComponent("Content"), themes: testThemes,
                             now: { clock.now }, usageReader: { _, _ in await usage.read() }, hoursReader: { _, _ in [] },
                             enrichmentReader: { _ in Enrichment() }, hubClient: hub, runtimeEnabled: false)
        return (model, clock, usage, probe, directory, defaults)
    }

    private func consent(_ model: AppModel) async {
        await model.refreshHubConfiguration()
        model.requestEncountersEnabled(true)
        model.confirmEncounterConsent()
    }

    private func finish(_ model: AppModel) async {
        while let task = model.encounterTasks.values.first { await task.value }
    }

    @Test func defaultOffAndConsentCancelNeverRegisterOrSync() async throws {
        let (app, _, _, probe, directory, defaults) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.refreshHubConfiguration()
        #expect(app.encountersAvailable && !app.encountersEnabled)
        app.requestEncountersEnabled(true)
        #expect(app.showingEncounterConsent && !app.encountersEnabled)
        app.showingEncounterConsent = false
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().allSatisfy { $0.url?.path == "/v1/config" })
        #expect(defaults.object(forKey: "encountersEnabled") == nil)
    }

    @Test(arguments: [false, true]) func unavailableToggleCannotGrantConsent(unconfigured: Bool) async throws {
        let (app, _, _, probe, directory, _) = try await fixture(configured: !unconfigured)
        defer { try? FileManager.default.removeItem(at: directory) }
        await probe.configure(enabled: false)
        await app.refreshHubConfiguration()
        #expect(!app.encountersAvailable)
        app.requestEncountersEnabled(true); app.confirmEncounterConsent()
        #expect(!app.encountersEnabled && !app.showingEncounterConsent)
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().allSatisfy { $0.url?.path == "/v1/config" })
    }

    @Test func arrivalPersistsUUIDBeforeBackgroundPostAndSnapshotsActualAppearanceWithoutPrivateData() async throws {
        let (app, _, _, probe, directory, defaults) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app)
        await probe.configure(holdPost: true)
        await app.scan()
        #expect(app.state?.phase == .staying)
        let stay = try #require(app.state?.encounterStaysByTrip?[1])
        #expect(UUID(uuidString: stay.stayId) != nil)
        #expect(stay.appearance.species == app.state?.pet.rawValue && stay.appearance.stage == app.petForm.rawValue)
        await probe.waitForPost()
        #expect(await probe.savedBeforeSend())
        #expect(defaults.object(forKey: "encountersEnabled") as? Bool == true)
        let request = try #require(await probe.snapshot().first { $0.httpMethod == "POST" })
        #expect(request.value(forHTTPHeaderField: "X-Voyage-Signature") != nil)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["stayId", "cityId", "day", "endsAt", "appearance"])
        #expect(!String(data: request.httpBody!, encoding: .utf8)!.contains("private-"))
        await probe.release(); await finish(app)
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test(arguments: [false, true]) func existingCityPhotoAndCatchUpArrivalSkipRegistration(catchUp: Bool) async throws {
        let (app, _, _, probe, directory, _) = try await fixture(photo: !catchUp, previousDay: catchUp)
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app)
        await app.scan(); await finish(app)
        #expect(app.state?.phase == .staying)
        #expect(await probe.snapshot().allSatisfy { $0.httpMethod != "POST" })
    }

    @Test func pollingWaitsFifteenMinutesAndFinalHomeCheckRunsOnlyOnce() async throws {
        let (app, clock, usage, probe, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app); await app.scan(); await finish(app)
        clock.now += 899
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().filter { $0.httpMethod == "GET" && $0.url!.path.contains("/stays/") }.isEmpty)
        clock.now += 1
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().filter { $0.url!.path.contains("/stays/") }.count == 1)
        clock.now += 6 * 3600
        await usage.set(DayKey.string(from: clock.now), 2_000_000_000)
        await app.scan(); await finish(app)
        #expect(app.state?.tripCount == 1 && app.state?.encounterStaysByTrip?[1]?.finalChecked == true)
        #expect(await probe.snapshot().filter { $0.url!.path.contains("/stays/") }.count == 2)
        clock.now += 1800
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().filter { $0.url!.path.contains("/stays/") }.count == 2)
    }

    @Test func pairingCreatesNextSettlementPostcardAndStopsPollingAndReadingAddsNoCompanionDay() async throws {
        let (app, clock, _, probe, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await probe.configure(pairedPost: true)
        await consent(app); await app.scan(); await finish(app)
        #expect(app.state?.encounterPhotos?.first?.cityId == "quanzhou")
        #expect(app.state?.letters.allSatisfy { $0.encounter == nil } == true)
        clock.now += 1800
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().allSatisfy { !$0.url!.path.contains("/stays/") })
        clock.now += 86_400
        await app.scan(); await finish(app)
        let letter = try #require(app.state?.letters.first { $0.encounter != nil })
        #expect(letter.kind == .postcard && letter.encounter?.partner.species == "snail")
        let care = try #require(app.care)
        app.markRead(letter)
        #expect(app.care == care)
        let ordinary = try #require(app.state?.letters.first { $0.kind == .daily })
        #expect(LetterComposer.number(for: ordinary, letters: app.state!.letters) == ordinary.id)
    }

    @Test func pollingPairIsDurableAndRestartReplayMakesNoTransportCalls() async throws {
        let (app, clock, _, probe, directory, defaults) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app); await app.scan(); await finish(app)
        await probe.configure(pairedGet: true)
        clock.now += 900
        await app.scan(); await finish(app)
        #expect(app.state?.encounterPhotos?.first?.partner.species == "snail")
        clock.now += 86_400
        await app.scan(); await finish(app)
        let saved = try #require(app.state)
        let count = await probe.snapshot().count
        let hub = HubClient(baseURL: URL(string: "https://voyage.example.invalid"),
                            transport: { try await probe.send($0) }, keyLoader: { Data(repeating: 7, count: 32) })
        let restarted = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog,
            contentDirectory: LocalizationTestFiles.root.appendingPathComponent("Content"), themes: testThemes,
            now: { clock.now }, usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
            enrichmentReader: { _ in Enrichment() }, hubClient: hub, runtimeEnabled: false)
        #expect(restarted.state == saved)
        #expect(await probe.snapshot().count == count)
        #expect(restarted.state?.letters.filter { $0.encounter != nil }.count == 1)
        #expect(restarted.state?.letters.first { $0.encounter != nil }?.texts == saved.letters.first { $0.encounter != nil }?.texts)
        var replay = saved
        replay.sync(today: DayUsage(date: replay.openDate), now: clock.now, catalog: localizationCatalog)
        #expect(replay.encounterPhotos == saved.encounterPhotos)
        #expect(replay.letters == saved.letters)
        #expect(await probe.snapshot().count == count)
    }

    @Test(arguments: [409, 500]) func failedRegistrationNeverPollsOrCreatesPhoto(status: Int) async throws {
        let (app, clock, _, probe, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await probe.configure(postStatus: status)
        await consent(app); await app.scan(); await finish(app)
        clock.now += 1800
        await app.scan(); await finish(app)
        #expect(app.state?.encounterPhotos == nil)
        #expect(await probe.snapshot().allSatisfy { !$0.url!.path.contains("/stays/") })
    }

    @Test func syncRunsAtMostDailyAndSendsOnlyOwnedIDsAndStayedCities() async throws {
        let (app, clock, _, probe, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app); await app.scan(); await finish(app)
        await app.scan(); await finish(app)
        var syncs = await probe.snapshot().filter { $0.url!.path == "/v1/sync" }
        #expect(syncs.count == 1 && syncs[0].httpMethod == "PUT")
        let body = try #require(JSONSerialization.jsonObject(with: syncs[0].httpBody!) as? [String: [String]])
        #expect(Set(body.keys) == ["collection"])
        #expect(Set(body["collection"] ?? []) == Set(app.care!.bag.owned + ["quanzhou"]))
        clock.now += 86_400
        await app.scan(); await finish(app)
        syncs = await probe.snapshot().filter { $0.url!.path == "/v1/sync" }
        #expect(syncs.count == 2)
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().filter { $0.url!.path == "/v1/sync" }.count == 2)
    }

    @Test(arguments: [false, true]) func optOutDeletesOnlyWhenRequestedAndStopsFutureRequests(delete: Bool) async throws {
        let (app, clock, _, probe, directory, defaults) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await consent(app); await app.scan(); await finish(app)
        app.requestEncountersEnabled(false)
        #expect(app.showingEncounterOptOut && app.encountersEnabled)
        app.disableEncounters(deleteRecords: delete); await finish(app)
        #expect(!app.encountersEnabled && defaults.object(forKey: "encountersEnabled") as? Bool == false)
        let before = await probe.snapshot()
        #expect(before.filter { $0.httpMethod == "DELETE" }.count == (delete ? 1 : 0))
        clock.now += 1800
        await app.scan(); await finish(app)
        #expect(await probe.snapshot().count == before.count)
    }

    @Test func deleteWaitsForInFlightPostAndLatePairingCannotReenableOrWritePhoto() async throws {
        let (app, _, _, probe, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await probe.configure(pairedPost: true, holdPost: true)
        await consent(app); await app.scan()
        await probe.waitForPost()
        app.disableEncounters(deleteRecords: true)
        #expect(await probe.snapshot().allSatisfy { $0.httpMethod != "DELETE" })
        await probe.release(); await finish(app)
        #expect(app.state?.encounterPhotos == nil && !app.encountersEnabled)
        #expect(await probe.snapshot().last?.httpMethod == "DELETE")
    }
}
