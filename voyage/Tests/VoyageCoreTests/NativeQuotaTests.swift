import Foundation
import Testing
@testable import VoyageCore

private let quotaObservationTime = Date(timeIntervalSince1970: 1_793_923_200)

private func quotaFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/quota"))
    return try Data(contentsOf: url)
}

@Test func codexNativeQuotaDecodesOnlyWindowFields() throws {
    let reading = try CodexQuota().parse(quotaFixture("codex-normal"), readAt: quotaObservationTime)
    #expect(reading.providerID == "codex")
    #expect(reading.readAt == quotaObservationTime)
    #expect(reading.windows.map(\.kind) == [.session, .weekly])
    #expect(reading.windows.map(\.remainingPercent) == [75, 14.5])
    #expect(reading.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    let description = String(describing: reading)
    #expect(!description.contains("fake-person@example.invalid"))
    #expect(!description.contains("fake-codex-account"))
    #expect(!description.contains("fake-plan"))
}

@Test func claudeNativeQuotaDecodesOnlyWindowFields() throws {
    let reading = try ClaudeQuota().parse(quotaFixture("claude-normal"), readAt: quotaObservationTime)
    #expect(reading.providerID == "claude")
    #expect(reading.readAt == quotaObservationTime)
    #expect(reading.windows.map(\.kind) == [.session, .weekly, .weeklySonnet, .weeklyOpus])
    #expect(reading.windows.map(\.remainingPercent) == [65, 6.75, 80, 95])
    let description = String(describing: reading)
    #expect(!description.contains("fake-person@example.invalid"))
    #expect(!description.contains("another-fake@example.invalid"))
    #expect(!description.contains("fake-claude-account"))
}

@Test(arguments: ["codex-missing", "codex-range", "claude-missing", "claude-range"])
func malformedNativeQuotaFixturesFailSemantically(_ fixture: String) throws {
    let provider: any QuotaProvider = fixture.hasPrefix("codex") ? CodexQuota() : ClaudeQuota()
    let data = try quotaFixture(fixture)
    #expect(throws: QuotaProviderError.invalidResponse) {
        try provider.parse(data, readAt: quotaObservationTime)
    }
}

@Test func nullNativeQuotaWindowsAreAbsentRatherThanZero() throws {
    for provider in [CodexQuota() as any QuotaProvider, ClaudeQuota() as any QuotaProvider] {
        let reading = try provider.parse(quotaFixture("\(provider.id)-null"), readAt: quotaObservationTime)
        #expect(reading.windows == [QuotaWindow(kind: .weekly, remainingPercent: 50)])
    }
}

@Test func codexNativeQuotaAcceptsSupportedResetFormatsAndCadences() throws {
    let reading = try CodexQuota().parse(quotaFixture("codex-time-formats"), readAt: quotaObservationTime)
    #expect(reading.windows.map(\.kind) == [.daily, .monthly])
    #expect(reading.windows.map(\.remainingPercent) == [100, 0])
    let reset = try #require(ISO8601DateFormatter().date(from: "2026-11-06T02:00:00Z"))
    let firstReset = try #require(reading.windows.first?.resetsAt)
    #expect(abs(firstReset.timeIntervalSince(reset) - 0.125) < 0.001)
    #expect(reading.windows.last?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func claudeNativeQuotaAcceptsFractionalAndOffsetResetTimes() throws {
    let reading = try ClaudeQuota().parse(quotaFixture("claude-time-formats"), readAt: quotaObservationTime)
    #expect(reading.windows.map(\.remainingPercent) == [100, 0])
    let firstReset = try #require(reading.windows.first?.resetsAt)
    let lastReset = try #require(reading.windows.last?.resetsAt)
    #expect(abs(firstReset.timeIntervalSince(lastReset) - 0.125) < 0.001)
}

@Test(arguments: [
    "{}",
    #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":-1}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":101}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":true}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":50,"reset_at":"not-a-date"}}}"#,
    #"{"rate_limit":{"primary_window":{"used_percent":1e400}}}"#,
])
func codexNativeQuotaRejectsUnknownOrInvalidWindows(_ json: String) {
    #expect(throws: QuotaProviderError.invalidResponse) {
        try CodexQuota().parse(Data(json.utf8), readAt: quotaObservationTime)
    }
}

@Test(arguments: [
    "{}",
    #"{"five_hour":null,"seven_day":null}"#,
    #"{"five_hour":{"utilization":-1}}"#,
    #"{"five_hour":{"utilization":101}}"#,
    #"{"five_hour":{"utilization":true}}"#,
    #"{"five_hour":{"utilization":50,"resets_at":"not-a-date"}}"#,
    #"{"five_hour":{"utilization":1e400}}"#,
])
func claudeNativeQuotaRejectsUnknownOrInvalidWindows(_ json: String) {
    #expect(throws: QuotaProviderError.invalidResponse) {
        try ClaudeQuota().parse(Data(json.utf8), readAt: quotaObservationTime)
    }
}

@Test func nativeQuotaRequestCredentialsStayInRequiredHeaders() throws {
    let fakeToken = "VOYAGE_FAKE_REQUEST_TOKEN_ONLY"
    let credential = QuotaCredential(accessToken: fakeToken, accountID: "fake-account-id")
    let codex = try CodexQuota().request(credential: credential)
    #expect(codex.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(codex.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fake-account-id")
    let claude = try ClaudeQuota().request(credential: credential)
    #expect(claude.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(claude.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(claude.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    for request in [codex, claude] {
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeToken)")
        #expect(request.allHTTPHeaderFields?.filter { $0.value.contains(fakeToken) }.count == 1)
        #expect(request.url?.absoluteString.contains(fakeToken) == false)
    }
    #expect(!String(describing: credential).contains(fakeToken))
    #expect(!String(reflecting: credential).contains(fakeToken))
    #expect(!String(describing: credential).contains("fake-account-id"))
    #expect(CodexQuota().linkMethods.count == 1)
    #expect(ClaudeQuota().linkMethods.count == 1)
}

@Test func nativeQuotaErrorsNeverEchoMalformedSecretsOrResponseFields() {
    let fakeToken = "VOYAGE_FAKE_ERROR_TOKEN_ONLY"
    let credential = QuotaCredential(accessToken: "\(fakeToken)\r\nInjected: bad")
    for provider in [CodexQuota() as any QuotaProvider, ClaudeQuota() as any QuotaProvider] {
        do {
            _ = try provider.request(credential: credential)
            Issue.record("Malformed request credentials should fail")
        } catch {
            #expect(error as? QuotaProviderError == .missingLogin)
            #expect(!String(describing: error).contains(fakeToken))
        }
        let json = provider.id == "codex"
            ? #"{"rate_limit":{"primary_window":{"used_percent":"VOYAGE_FAKE_ERROR_TOKEN_ONLY"}}}"#
            : #"{"five_hour":{"utilization":"VOYAGE_FAKE_ERROR_TOKEN_ONLY"}}"#
        do {
            _ = try provider.parse(Data(json.utf8), readAt: quotaObservationTime)
            Issue.record("Malformed response percentages should fail")
        } catch {
            #expect(error as? QuotaProviderError == .invalidResponse)
            #expect(!String(describing: error).contains(fakeToken))
        }
    }
}

@Test func nativeQuotaDoesNotDecodeUnrequestedAccountFields() throws {
    let codex = #"{"email":{"unexpected":"fake@example.invalid"},"account_id":["fake@example.invalid"],"rate_limit":{"primary_window":{"used_percent":5}}}"#
    let claude = #"{"email":["fake@example.invalid"],"account":{"email":"fake@example.invalid"},"five_hour":{"utilization":5}}"#
    let readings = [
        try CodexQuota().parse(Data(codex.utf8), readAt: quotaObservationTime),
        try ClaudeQuota().parse(Data(claude.utf8), readAt: quotaObservationTime),
    ]
    for reading in readings {
        #expect(reading.windows.map(\.remainingPercent) == [95])
        #expect(!String(describing: reading).contains("fake@example.invalid"))
        #expect(!String(reflecting: reading).contains("fake@example.invalid"))
    }
}
