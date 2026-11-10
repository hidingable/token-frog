import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class HubWishDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey name: String) -> Any? { values[name] }
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func set(_ value: Any?, forKey name: String) { values[name] = value }
}

private actor HubWishTransport {
    enum Reply: Sendable {
        case tags([String], source: String)
        case status(Int)
        case invalidJSON
        case failure
        case slow
    }

    private let reply: Reply
    private let wishEnabled: Bool
    private(set) var requests: [URLRequest] = []

    init(_ reply: Reply = .tags(["art", "invented"], source: "model"), wishEnabled: Bool = true) {
        self.reply = reply
        self.wishEnabled = wishEnabled
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path == "/v1/config" {
            return response(try JSONEncoder().encode(HubConfig(wishResolveEnabled: wishEnabled)), request: request)
        }
        #expect(request.url?.path == "/v1/wishes/resolve")
        switch reply {
        case .tags(let tags, let source):
            let data = try JSONSerialization.data(withJSONObject: ["tags": tags, "source": source])
            return response(data, request: request)
        case .status(let status):
            return response(Data(), request: request, status: status)
        case .invalidJSON:
            return response(Data("broken response".utf8), request: request)
        case .failure:
            throw URLError(.notConnectedToInternet)
        case .slow:
            try await Task.sleep(for: .seconds(60))
            return response(Data(#"{"tags":["art"],"source":"model"}"#.utf8), request: request)
        }
    }

    private func response(_ data: Data, request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                               headerFields: ["Content-Type": "application/json"])!)
    }

    var wishRequests: [URLRequest] { requests.filter { $0.url?.path == "/v1/wishes/resolve" } }
}

@MainActor private struct HubWishFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-hub-wish-\(UUID().uuidString)")
    let defaults = HubWishDefaults()
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!

    func save() throws {
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: localizationCatalog)
        let care = CareState(petName: "Private pet name", species: journey.pet, hatchedAt: journey.startDate)
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
    }

    func client(_ transport: HubWishTransport, configured: Bool = true) -> HubClient {
        HubClient(baseURL: configured ? URL(string: "https://hub.invalid") : nil,
                  transport: { try await transport.send($0) }, keyLoader: { Data(repeating: 7, count: 32) })
    }

    func model(_ client: HubClient, timeout: Duration = .seconds(3)) -> AppModel {
        AppModel(languageOverride: .en, defaults: defaults, directory: directory,
                 catalog: localizationCatalog, themes: testThemes, now: { now },
                 usageReader: { _, _ in [] }, hoursReader: { _, _ in [] }, enrichmentReader: { _ in Enrichment() },
                 hubClient: client, wishTimeout: timeout, runtimeEnabled: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor struct HubWishTests {
    @Test func serverTagsReplaceKeywordsAndPayloadContainsOnlyTheWishContract() async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let transport = HubWishTransport()
        let model = fixture.model(fixture.client(transport))
        let before = model.state
        #expect(localizationCatalog.wishes.keywordTags(for: "**beach**", language: .en) == ["coast"])
        #expect(await model.setWish("**beach**"))
        #expect(model.care?.wish == "**beach**")
        #expect(model.care?.wishResolution?.tags == ["art"])
        #expect(model.state == before)

        let requests = await transport.wishRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        #expect(request.timeoutInterval <= 3)
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(payload.keys) == ["text", "language", "allowedTags"])
        #expect(payload["text"] as? String == "**beach**")
        #expect(payload["language"] as? String == "en")
        #expect(payload["allowedTags"] as? [String] == localizationCatalog.wishes.tagIDs)
    }

    @Test(arguments: ["model", "cache"])
    func aSuccessfulEmptyAnswerDoesNotRestoreKeywordTags(source: String) async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let transport = HubWishTransport(.tags([], source: source))
        let model = fixture.model(fixture.client(transport))
        #expect(await model.setWish("beach"))
        #expect(model.care?.wish == "beach")
        #expect(model.care?.wishResolution?.tags == [])
        #expect(await transport.wishRequests.count == 1)
    }

    @Test(arguments: ["transport", "http", "invalidJSON", "error", "timeout", "disabled"])
    func unavailableHubFallsBackToKeywordsWithoutChangingJourneyOrRewards(failure: String) async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let reply: HubWishTransport.Reply
        switch failure {
        case "transport": reply = .failure
        case "http": reply = .status(503)
        case "invalidJSON": reply = .invalidJSON
        default: reply = .tags([], source: failure)
        }
        let transport = HubWishTransport(reply)
        let model = fixture.model(fixture.client(transport))
        let journey = model.state
        let care = try #require(model.care)
        #expect(await model.setWish("beach"))
        #expect(model.care?.wish == "beach")
        #expect(model.care?.wishResolution?.tags == ["coast"])
        #expect(model.state == journey)
        #expect(model.care?.habits == care.habits)
        #expect(model.care?.pity == care.pity)
        #expect(model.care?.souvenirs == care.souvenirs)
        #expect(model.care?.menus == care.menus)
        #expect(model.care?.bag == care.bag)
        #expect(await transport.wishRequests.count == 1)
    }

    @Test func wishBudgetCancelsASlowTransportAndSavesTheKeywordFallback() async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let transport = HubWishTransport(.slow)
        let model = fixture.model(fixture.client(transport), timeout: .milliseconds(5))
        #expect(await model.setWish("beach"))
        #expect(model.care?.wishResolution?.tags == ["coast"])
        #expect(!model.isSavingWish)
        #expect(await transport.wishRequests.count == 1)
    }

    @Test(arguments: ["toggle", "emptyURL", "config"])
    func disabledNetworkPathsNeverRequestWishResolution(disabledBy: String) async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let transport = HubWishTransport(wishEnabled: disabledBy != "config")
        let client = fixture.client(transport, configured: disabledBy != "emptyURL")
        if disabledBy == "config" { await client.refreshConfig(now: fixture.now) }
        let model = fixture.model(client)
        if disabledBy == "toggle" { model.wishResolveEnabled = false }
        #expect(await model.setWish("beach"))
        #expect(model.care?.wishResolution?.tags == ["coast"])
        #expect(await transport.wishRequests.isEmpty)
        #expect(await transport.requests.count == (disabledBy == "config" ? 1 : 0))
    }

    @Test func aSavedWishSurvivesReloadAndRepeatedSaveWithoutAnotherRequest() async throws {
        let fixture = HubWishFixture()
        defer { fixture.cleanUp() }
        try fixture.save()
        let transport = HubWishTransport(.tags(["art"], source: "cache"))
        let client = fixture.client(transport)
        let first = fixture.model(client)
        #expect(await first.setWish("beach"))
        #expect(await first.setWish("beach"))
        let saved = first.care?.wishResolution

        let reloaded = fixture.model(client)
        reloaded.languagePreference = .zhHans
        reloaded.tick()
        await reloaded.scan()
        #expect(reloaded.care?.wish == "beach")
        #expect(reloaded.care?.wishResolution == saved)
        #expect(await reloaded.setWish("beach"))
        #expect(await transport.wishRequests.count == 1)
    }
}
