import CryptoKit
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let hubTestURL = URL(string: "https://voyage.example.invalid")!
private let hubTestSeed = Data(stride(from: 0, to: 64, by: 2).map { offset in
    let hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    let start = hex.index(hex.startIndex, offsetBy: offset)
    return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
})
private let hubEnabledConfig = #"{"schemaVersion":1,"cityContentEnabled":true,"wishResolveEnabled":true,"encountersEnabled":false,"sponsorContentEnabled":false}"#
private let hubDisabledConfig = #"{"schemaVersion":1,"cityContentEnabled":false,"wishResolveEnabled":false,"encountersEnabled":false,"sponsorContentEnabled":false}"#

private actor HubTransportProbe {
    enum Reply: Sendable { case json(String, Int = 200), timeout, failure }
    var reply: Reply
    var requests: [URLRequest] = []
    var keyReads = 0

    init(_ reply: Reply) { self.reply = reply }
    func set(_ reply: Reply) { self.reply = reply }
    func snapshot() -> [URLRequest] { requests }
    func recordKey() -> Data { keyReads += 1; return hubTestSeed }
    func keyReadCount() -> Int { keyReads }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch reply {
        case .json(let text, let status):
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case .timeout: throw URLError(.timedOut)
        case .failure: throw URLError(.cannotConnectToHost)
        }
    }
}

private func makeHubClient(_ probe: HubTransportProbe, baseURL: URL? = hubTestURL, configURL: URL? = nil) -> HubClient {
    HubClient(baseURL: baseURL, configURL: configURL, transport: { try await probe.send($0) },
              keyLoader: { await probe.recordKey() })
}

private func hubConfigFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("voyage-hub-test-\(UUID().uuidString)")
        .appendingPathComponent("hub-config.json")
}

@Test func hubSigningMatchesReadmeFixedVector() throws {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hubTestSeed)
    var request = URLRequest(url: hubTestURL.appendingPathComponent("v1/wishes/resolve"))
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"text":"Sea","language":"en"}"#.utf8)
    let canonical = try HubRequestSigner.canonicalString(for: request, timestamp: 1_700_000_000)
    #expect(canonical == "POST\n/v1/wishes/resolve\n1700000000\n895ab08e3bbe7108c3f5e0f19d347db7a735b79bae98e9f7dfda829a4ed95e2e")
    let signed = try HubRequestSigner.signed(request, privateKey: key, timestamp: 1_700_000_000)
    #expect(signed.value(forHTTPHeaderField: "X-Voyage-Device") == "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
    #expect(signed.value(forHTTPHeaderField: "X-Voyage-Timestamp") == "1700000000")
    let expectedSignature = try #require(Data(base64Encoded: "ZcXYcypapsgkZLVgpkdFDahx+Ed6QLX7ocMNE8yRo5ajcda2/NKsFLEgcjnZmWn+50GhacL3FQWV3Yh9kCz+AQ=="))
    #expect(key.publicKey.isValidSignature(expectedSignature, for: Data(canonical.utf8)))
    // Current macOS CryptoKit randomizes Ed25519 signatures; the public API has no deterministic mode.
    // Verify the fixed server vector and our emitted signature against the same exact signed bytes.
    let signatureHeader = try #require(signed.value(forHTTPHeaderField: "X-Voyage-Signature"))
    let actualSignature = try #require(Data(base64Encoded: signatureHeader))
    #expect(actualSignature.count == 64)
    #expect(actualSignature.base64EncodedString() == signatureHeader)
    #expect(key.publicKey.isValidSignature(actualSignature, for: Data(canonical.utf8)))
    #expect(signed.httpBody == request.httpBody)
}

@Test func hubSigningPreservesEncodedPathQueryOrderAndCase() throws {
    let request = URLRequest(url: URL(string: "https://voyage.example.invalid/v1/%7efoo?a=%2f&z=%2F&z=second")!)
    let canonical = try HubRequestSigner.canonicalString(for: request, timestamp: 0)
    #expect(canonical == "GET\n/v1/%7efoo?a=%2f&z=%2F&z=second\n0\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func hubURLConfigurationHasExplicitEmptyOverride() {
    #expect(HubClient.configuredBaseURL(environment: [:], info: [:]) == nil)
    #expect(HubClient.configuredBaseURL(environment: [:], info: ["VoyageHubURL": ""]) == nil)
    #expect(HubClient.configuredBaseURL(environment: [:], info: ["VoyageHubURL": hubTestURL.absoluteString]) == hubTestURL)
    #expect(HubClient.configuredBaseURL(environment: ["TOKEN_VOYAGE_HUB_URL": ""], info: ["VoyageHubURL": hubTestURL.absoluteString]) == nil)
    #expect(HubClient.configuredBaseURL(environment: ["TOKEN_VOYAGE_HUB_URL": "http://localhost:17322"], info: [:])?.host == "localhost")
    for value in ["relative/path", "file:///tmp/hub", "https://user:password@example.invalid", "https://example.invalid?secret=x"] {
        #expect(HubClient.configuredBaseURL(environment: ["TOKEN_VOYAGE_HUB_URL": value], info: [:]) == nil)
    }
}

@Test func hubEmptyURLAndLocalTogglesPreventTransportAndKeyAccess() async {
    for baseURL: URL? in [nil, hubTestURL] {
        let probe = HubTransportProbe(.failure)
        let hub = makeHubClient(probe, baseURL: baseURL)
        let enabled = baseURL == nil
        await #expect(throws: HubClientError.disabled) {
            try await hub.resolveWish(text: "sea", language: .en, allowedTags: ["sea"], enabled: enabled)
        }
        await #expect(throws: HubClientError.disabled) {
            try await hub.cityContent(cityID: "hangzhou", language: .en, enabled: enabled)
        }
        if baseURL == nil { #expect(await hub.refreshConfig() == .defaults) }
        #expect(await probe.snapshot().isEmpty)
        #expect(await probe.keyReadCount() == 0)
    }
}

@Test func hubServerSwitchesGateRequestsAndConfigIsUnsigned() async {
    let probe = HubTransportProbe(.json(hubDisabledConfig))
    let hub = makeHubClient(probe)
    let config = await hub.refreshConfig()
    #expect(!config.cityContentEnabled)
    #expect(!config.wishResolveEnabled)
    await #expect(throws: HubClientError.disabled) {
        try await hub.resolveWish(text: "sea", language: .en, allowedTags: ["sea"], enabled: true)
    }
    await #expect(throws: HubClientError.disabled) {
        try await hub.cityContent(cityID: "hangzhou", language: .en, enabled: true)
    }
    let requests = await probe.snapshot()
    #expect(requests.count == 1)
    #expect(requests.first?.url?.path == "/v1/config")
    #expect(requests.first?.value(forHTTPHeaderField: "X-Voyage-Device") == nil)
    #expect(await probe.keyReadCount() == 0)
}

@Test func hubConfigPersistsGoodValueAndDailyAttemptAcrossFailuresAndRestart() async throws {
    let configURL = hubConfigFile()
    defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let firstProbe = HubTransportProbe(.json(hubDisabledConfig))
    let first = makeHubClient(firstProbe, configURL: configURL)
    #expect(!(await first.refreshConfig(now: start)).wishResolveEnabled)
    _ = await first.refreshConfig(now: start.addingTimeInterval(86_399))
    #expect(await firstProbe.snapshot().count == 1)

    let secondProbe = HubTransportProbe(.failure)
    let second = makeHubClient(secondProbe, configURL: configURL)
    #expect(!(await second.refreshConfig(now: start.addingTimeInterval(10))).cityContentEnabled)
    #expect(await secondProbe.snapshot().isEmpty)
    #expect(!(await second.refreshConfig(now: start.addingTimeInterval(86_400))).cityContentEnabled)
    #expect(await secondProbe.snapshot().count == 1)

    let thirdProbe = HubTransportProbe(.json(hubEnabledConfig))
    let third = makeHubClient(thirdProbe, configURL: configURL)
    #expect(!(await third.refreshConfig(now: start.addingTimeInterval(86_401))).wishResolveEnabled)
    #expect(await thirdProbe.snapshot().isEmpty)
    #expect((await third.refreshConfig(now: start.addingTimeInterval(172_800))).wishResolveEnabled)
    #expect(await thirdProbe.snapshot().count == 1)
}

@Test func hubConfigFallsBackToDefaultsAndPersistsFailedAttempt() async throws {
    let configURL = hubConfigFile()
    defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let probe = HubTransportProbe(.timeout)
    #expect(await makeHubClient(probe, configURL: configURL).refreshConfig(now: start) == .defaults)
    let restartProbe = HubTransportProbe(.json(hubDisabledConfig))
    #expect(await makeHubClient(restartProbe, configURL: configURL).refreshConfig(now: start.addingTimeInterval(1)) == .defaults)
    #expect(await restartProbe.snapshot().isEmpty)
}

@Test func hubUnsupportedOrInvalidConfigKeepsDefaults() async {
    for value in ["not json", "{}", hubDisabledConfig.replacingOccurrences(of: "schemaVersion\":1", with: "schemaVersion\":2")] {
        let probe = HubTransportProbe(.json(value))
        #expect(await makeHubClient(probe).refreshConfig() == .defaults)
    }
    let probe = HubTransportProbe(.json(hubDisabledConfig, 503))
    #expect(await makeHubClient(probe).refreshConfig() == .defaults)
}

@Test func hubWishOnlySendsPermittedFieldsAndSignsExactBytes() async throws {
    let probe = HubTransportProbe(.json(#"{"tags":["sea","foreign","sea","quiet"],"source":"model"}"#))
    let hub = makeHubClient(probe)
    let result = try await hub.resolveWish(text: "Sea", language: .en, allowedTags: ["sea", "quiet"], enabled: true)
    #expect(result == ["sea", "quiet"])
    let request = try #require(await probe.snapshot().first)
    #expect(request.url?.absoluteString == "https://voyage.example.invalid/v1/wishes/resolve")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == Data(#"{"allowedTags":["sea","quiet"],"language":"en","text":"Sea"}"#.utf8))
    #expect(request.timeoutInterval == 2.5)
    #expect(!request.httpShouldHandleCookies)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hubTestSeed)
    let timestampHeader = try #require(request.value(forHTTPHeaderField: "X-Voyage-Timestamp"))
    let timestamp = try #require(Int64(timestampHeader))
    let canonical = try HubRequestSigner.canonicalString(for: request, timestamp: timestamp)
    let signatureHeader = try #require(request.value(forHTTPHeaderField: "X-Voyage-Signature"))
    let signature = try #require(Data(base64Encoded: signatureHeader))
    #expect(key.publicKey.isValidSignature(signature, for: Data(canonical.utf8)))
}

@Test func hubSuccessfulEmptyWishTagsAreAnAnswer() async throws {
    for source in ["model", "cache"] {
        let probe = HubTransportProbe(.json("{\"tags\":[],\"source\":\"\(source)\"}"))
        #expect(try await makeHubClient(probe).resolveWish(text: "sea", language: .en, allowedTags: ["sea"], enabled: true).isEmpty)
    }
}

@Test func hubWishFailureSourcesRequestErrorsAndTimeoutThrowForKeywordFallback() async {
    for source in ["error", "timeout", "disabled", "unknown"] {
        let probe = HubTransportProbe(.json("{\"tags\":[],\"source\":\"\(source)\"}"))
        await #expect(throws: HubClientError.wishUnavailable) {
            try await makeHubClient(probe).resolveWish(text: "sea", language: .en, allowedTags: ["sea"], enabled: true)
        }
    }
    for reply in [HubTransportProbe.Reply.timeout, .failure, .json("{}"), .json("{}", 429)] {
        let probe = HubTransportProbe(reply)
        await #expect(throws: (any Error).self) {
            try await makeHubClient(probe).resolveWish(text: "sea", language: .en, allowedTags: ["sea"], enabled: true)
        }
    }
}

@Test func hubCityContentPreservesRawObjectsForValidationAndSendsOnlyCityAndLanguage() async throws {
    let json = #"{"schemaVersion":1,"cityId":"hangzhou","language":"zh-Hans","disabled":false,"items":[{"id":"hub.hangzhou.good","sponsor":{"nested":true}},42,{"id":"hub.hangzhou.second"}]}"#
    let probe = HubTransportProbe(.json(json))
    let entries = try await makeHubClient(probe).cityContent(cityID: "hangzhou", language: .zhHans, enabled: true)
    #expect(entries.count == 2)
    #expect(String(decoding: entries[0], as: UTF8.self).contains("sponsor"))
    let request = try #require(await probe.snapshot().first)
    #expect(request.url?.absoluteString == "https://voyage.example.invalid/v1/cities/hangzhou/content?lang=zh-Hans")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    #expect(request.value(forHTTPHeaderField: "X-Voyage-Device") != nil)
}

@Test func hubCityRejectsWrongEnvelopeDisabledUnsupportedSchemaAndBadCityPath() async {
    for json in [
        #"{"schemaVersion":1,"cityId":"other","language":"en","disabled":false,"items":[]}"#,
        #"{"schemaVersion":1,"cityId":"hangzhou","language":"zh-Hans","disabled":false,"items":[]}"#,
        #"{"schemaVersion":2,"cityId":"hangzhou","language":"en","disabled":false,"items":[]}"#,
        #"{"schemaVersion":1,"cityId":"hangzhou","language":"en","disabled":true,"items":[]}"#,
        #"{"schemaVersion":1,"cityId":"hangzhou","language":"en","disabled":false}"#,
    ] {
        let probe = HubTransportProbe(.json(json))
        await #expect(throws: (any Error).self) {
            try await makeHubClient(probe).cityContent(cityID: "hangzhou", language: .en, enabled: true)
        }
    }
    let probe = HubTransportProbe(.failure)
    await #expect(throws: HubClientError.invalidRequest) {
        try await makeHubClient(probe).cityContent(cityID: "../config", language: .en, enabled: true)
    }
    #expect(await probe.snapshot().isEmpty)
    #expect(await probe.keyReadCount() == 0)
}
