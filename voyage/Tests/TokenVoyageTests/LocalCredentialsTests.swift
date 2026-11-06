import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let localCredentialFakeToken = "VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"
private let localCredentialFakeEmail = "fake-local-account@example.invalid"
private let localCredentialCodexHome = URL(fileURLWithPath: "/voyage-fake-credentials/custom-codex-home")
private let localCredentialClaudeHome = URL(fileURLWithPath: "/voyage-fake-credentials/claude-home")

private struct FakeCredentialReadError: Error {
    let fakeDetail: String
}

private actor LocalCredentialReadProbe {
    var fileURLs: [URL] = []
    var keychainReads = 0

    func recordFile(_ url: URL) { fileURLs.append(url) }
    func recordKeychain() { keychainReads += 1 }
    func snapshot() -> (fileURLs: [URL], keychainReads: Int) { (fileURLs, keychainReads) }
}

@Test func codexLocalCredentialParserKeepsOnlyAccessTokenAndAccountID() throws {
    let json = #"{"tokens":{"access_token":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY","account_id":"fake-codex-account","refresh_token":{"never":"decode"},"id_token":["never","decode"]},"access_token":"fake-root-token-not-selected","email":"fake-local-account@example.invalid"}"#
    let credential = try LocalCredentials.codex(Data(json.utf8))
    #expect(credential.accessToken == localCredentialFakeToken)
    #expect(credential.accountID == "fake-codex-account")
    for description in [String(describing: credential), String(reflecting: credential)] {
        #expect(!description.contains(localCredentialFakeToken))
        #expect(!description.contains(localCredentialFakeEmail))
        #expect(!description.contains("fake-codex-account"))
        #expect(!description.contains("fake-root-token-not-selected"))
        #expect(!description.contains("refresh_token"))
    }
}

@Test func claudeLocalCredentialParserKeepsOnlyOAuthAccessToken() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY","refreshToken":{"never":"decode"},"email":"fake-local-account@example.invalid","accountId":"fake-claude-account"},"accessToken":"fake-root-token-not-selected","email":["do","not","decode"]}"#
    let credential = try LocalCredentials.claude(Data(json.utf8))
    #expect(credential.accessToken == localCredentialFakeToken)
    #expect(credential.accountID == nil)
    for description in [String(describing: credential), String(reflecting: credential)] {
        #expect(!description.contains(localCredentialFakeToken))
        #expect(!description.contains(localCredentialFakeEmail))
        #expect(!description.contains("fake-claude-account"))
        #expect(!description.contains("refreshToken"))
    }
}

@Test func codexLocalCredentialAccountIDIsOptional() throws {
    let json = #"{"tokens":{"access_token":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}}"#
    let credential = try LocalCredentials.codex(Data(json.utf8))
    #expect(credential.accessToken == localCredentialFakeToken)
    #expect(credential.accountID == nil)
}

@Test(arguments: [
    "{}",
    #"{"access_token":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}"#,
    #"{"tokens":null}"#,
    #"{"tokens":{"access_token":""}}"#,
    #"{"tokens":{"access_token":null}}"#,
    #"{"tokens":{"access_token":["VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"]}}"#,
    #"{"tokens":{"access_token":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY","account_id":42}}"#,
    "not-json-VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY",
])
func codexLocalCredentialInvalidInputsExposeOnlySemanticErrors(_ json: String) {
    do {
        _ = try LocalCredentials.codex(Data(json.utf8))
        Issue.record("Invalid Codex login data should fail")
    } catch {
        #expect(error as? QuotaProviderError == .missingLogin)
        #expect(!String(describing: error).contains(localCredentialFakeToken))
        #expect(!String(reflecting: error).contains(localCredentialFakeToken))
    }
}

@Test(arguments: [
    "{}",
    #"{"accessToken":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}"#,
    #"{"oauth":{"accessToken":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}}"#,
    #"{"claudeAiOauth":null}"#,
    #"{"claudeAiOauth":{"accessToken":""}}"#,
    #"{"claudeAiOauth":{"accessToken":null}}"#,
    #"{"claudeAiOauth":{"accessToken":["VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"]}}"#,
    "not-json-VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY",
])
func claudeLocalCredentialInvalidInputsExposeOnlySemanticErrors(_ json: String) {
    do {
        _ = try LocalCredentials.claude(Data(json.utf8))
        Issue.record("Invalid Claude login data should fail")
    } catch {
        #expect(error as? QuotaProviderError == .missingLogin)
        #expect(!String(describing: error).contains(localCredentialFakeToken))
        #expect(!String(reflecting: error).contains(localCredentialFakeToken))
    }
}

@Test func constructingLocalCredentialsDoesNotReadAnyInjectedSource() async {
    let probe = LocalCredentialReadProbe()
    _ = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        },
        readKeychain: {
            await probe.recordKeychain()
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        }
    )
    let calls = await probe.snapshot()
    #expect(calls.fileURLs.isEmpty)
    #expect(calls.keychainReads == 0)
}

@Test func codexReadsOnlyTheInjectedCodexHomeAuthFile() async throws {
    let probe = LocalCredentialReadProbe()
    let credentials = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            return Data(#"{"tokens":{"access_token":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY","account_id":"fake-selected-account"}}"#.utf8)
        },
        readKeychain: {
            await probe.recordKeychain()
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        }
    )
    let credential = try await credentials.read(.codex)
    #expect(credential.accessToken == localCredentialFakeToken)
    #expect(credential.accountID == "fake-selected-account")
    let calls = await probe.snapshot()
    #expect(calls.fileURLs == [localCredentialCodexHome.appendingPathComponent("auth.json")])
    #expect(calls.keychainReads == 0)
}

@Test func claudePrefersInjectedKeychainWithoutReadingItsFile() async throws {
    let probe = LocalCredentialReadProbe()
    let credentials = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        },
        readKeychain: {
            await probe.recordKeychain()
            return Data(#"{"claudeAiOauth":{"accessToken":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}}"#.utf8)
        }
    )
    let credential = try await credentials.read(.claude)
    #expect(credential.accessToken == localCredentialFakeToken)
    #expect(credential.accountID == nil)
    let calls = await probe.snapshot()
    #expect(calls.fileURLs.isEmpty)
    #expect(calls.keychainReads == 1)
}

@Test(arguments: [false, true])
func claudeFallsBackToInjectedFileWhenKeychainFailsOrIsInvalid(_ invalidData: Bool) async throws {
    let probe = LocalCredentialReadProbe()
    let credentials = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            return Data(#"{"claudeAiOauth":{"accessToken":"VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"}}"#.utf8)
        },
        readKeychain: {
            await probe.recordKeychain()
            if invalidData {
                return Data(#"{"claudeAiOauth":{"accessToken":["VOYAGE_LOCAL_CREDENTIALS_FAKE_TOKEN_ONLY"]}}"#.utf8)
            }
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        }
    )
    let credential = try await credentials.read(.claude)
    #expect(credential.accessToken == localCredentialFakeToken)
    let calls = await probe.snapshot()
    #expect(calls.keychainReads == 1)
    #expect(calls.fileURLs == [localCredentialClaudeHome.appendingPathComponent(".credentials.json")])
}

@Test func localCredentialReadFailuresCannotExposeInjectedErrorDetails() async {
    let probe = LocalCredentialReadProbe()
    let credentials = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        },
        readKeychain: {
            await probe.recordKeychain()
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        }
    )
    for source in [QuotaSource.codex, .claude, .otherTools] {
        do {
            _ = try await credentials.read(source)
            Issue.record("Missing local login should fail")
        } catch {
            #expect(error as? QuotaProviderError == .missingLogin)
            #expect(!String(describing: error).contains(localCredentialFakeToken))
            #expect(!String(reflecting: error).contains(localCredentialFakeToken))
            #expect(!String(describing: error).contains(localCredentialCodexHome.path))
            #expect(!String(describing: error).contains(localCredentialClaudeHome.path))
        }
    }
    let calls = await probe.snapshot()
    #expect(calls.keychainReads == 1)
    #expect(calls.fileURLs == [
        localCredentialCodexHome.appendingPathComponent("auth.json"),
        localCredentialClaudeHome.appendingPathComponent(".credentials.json"),
    ])
}

@Test func otherToolsNeverReadNativeCredentialSources() async {
    let probe = LocalCredentialReadProbe()
    let credentials = LocalCredentials(
        codexDirectory: { localCredentialCodexHome },
        claudeDirectory: { localCredentialClaudeHome },
        readFile: { url in
            await probe.recordFile(url)
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        },
        readKeychain: {
            await probe.recordKeychain()
            throw FakeCredentialReadError(fakeDetail: localCredentialFakeToken)
        }
    )
    do {
        _ = try await credentials.read(.otherTools)
        Issue.record("Other tools have no native credential reader")
    } catch {
        #expect(error as? QuotaProviderError == .missingLogin)
    }
    let calls = await probe.snapshot()
    #expect(calls.fileURLs.isEmpty)
    #expect(calls.keychainReads == 0)
}
