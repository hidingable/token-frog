import CryptoKit
import Foundation
import VoyageCore

struct HubConfig: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var cityContentEnabled = true
    var wishResolveEnabled = true
    var encountersEnabled = false
    var sponsorContentEnabled = false

    static let defaults = HubConfig()
}

enum HubClientError: Error, Equatable {
    case disabled
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case wishUnavailable
}

/// Opt-in enrichment: only approved city, collection and anonymous appearance fields cross this boundary.
actor HubClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias KeyLoader = @Sendable () async throws -> Data

    nonisolated let isConfigured: Bool

    private struct CachedConfig: Codable {
        let version: Int
        let baseURL: URL
        var lastAttempt: Date?
        var config: HubConfig
    }

    private let baseURL: URL?
    private let configURL: URL?
    private let transport: Transport
    private let keyLoader: KeyLoader
    private var cached: CachedConfig?
    private var privateKey: Curve25519.Signing.PrivateKey?

    init(baseURL: URL?, configURL: URL? = nil,
         transport: @escaping Transport = HubClient.urlSessionTransport(),
         keyLoader: @escaping KeyLoader = { try HubDeviceKey.loadOrCreate().rawRepresentation }) {
        self.baseURL = baseURL
        isConfigured = baseURL != nil
        self.configURL = configURL
        self.transport = transport
        self.keyLoader = keyLoader
        if let configURL, let baseURL, let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(CachedConfig.self, from: data),
           saved.version == 1, saved.baseURL == baseURL, saved.config.schemaVersion == 1 {
            cached = saved
        } else if let baseURL {
            cached = CachedConfig(version: 1, baseURL: baseURL, config: .defaults)
        }
    }

    /// An explicit empty development override also disables networking.
    static func configuredBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        let value = environment["TOKEN_VOYAGE_HUB_URL"] ?? (info["VoyageHubURL"] as? String) ?? ""
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }

    /// Persist attempts too, so an unavailable Hub cannot create a launch/retry loop.
    @discardableResult
    func refreshConfig(now: Date = Date()) async -> HubConfig {
        guard var state = cached else { return .defaults }
        if let lastAttempt = state.lastAttempt, now.timeIntervalSince(lastAttempt) < 86_400 {
            return state.config
        }
        state.lastAttempt = now
        cached = state
        persistConfig()
        do {
            let request = try makeRequest(path: "/v1/config")
            let data = try await send(request)
            let config = try JSONDecoder().decode(HubConfig.self, from: data)
            guard config.schemaVersion == 1 else { throw HubClientError.invalidResponse }
            cached?.config = config
            persistConfig()
        } catch {
            // Keep the last good switches, or defaults before the first successful fetch.
        }
        return cached?.config ?? .defaults
    }

    func resolveWish(text: String, language: Language, allowedTags: [String], enabled: Bool) async throws -> [String] {
        guard enabled, baseURL != nil, cached?.config.wishResolveEnabled == true else {
            throw HubClientError.disabled
        }
        struct WishRequest: Encodable { let text: String; let language: String; let allowedTags: [String] }
        struct WishResponse: Decodable { let tags: [String]; let source: String }
        var request = try makeRequest(path: "/v1/wishes/resolve")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(WishRequest(text: text, language: language.rawValue, allowedTags: allowedTags))
        let response = try JSONDecoder().decode(WishResponse.self, from: await sendSigned(request))
        guard ["model", "cache"].contains(response.source) else { throw HubClientError.wishUnavailable }
        let allowed = Set(allowedTags)
        var seen = Set<String>()
        return response.tags.filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    /// Preserve raw fields so remote validation can distinguish a valid sponsor from nested or malformed data.
    func cityContent(cityID: String, language: Language, enabled: Bool) async throws -> [Data] {
        guard enabled, baseURL != nil, cached?.config.cityContentEnabled == true else {
            throw HubClientError.disabled
        }
        guard !cityID.isEmpty, cityID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw HubClientError.invalidRequest
        }
        struct ContentResponse: Decodable {
            let schemaVersion: Int
            let cityId: String
            let language: String
            let disabled: Bool
        }
        let request = try makeRequest(path: "/v1/cities/\(cityID)/content",
                                      query: [URLQueryItem(name: "lang", value: language.rawValue)])
        let data = try await sendSigned(request)
        let response = try JSONDecoder().decode(ContentResponse.self, from: data)
        guard response.schemaVersion == 1, response.cityId == cityID, response.language == language.rawValue,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = envelope["items"] as? [Any] else { throw HubClientError.invalidResponse }
        guard !response.disabled else { throw HubClientError.disabled }
        return entries.compactMap { entry in
            guard let object = entry as? [String: Any] else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    struct StayResponse: Decodable, Sendable {
        struct Partner: Decodable, Sendable { let appearance: EncounterAppearance }
        let status: String
        let partner: Partner?
        let pairedAt: Date?
    }

    func encountersAvailable() -> Bool { isConfigured && cached?.config.encountersEnabled == true }

    func registerStay(_ stay: EncounterStay, enabled: Bool) async throws -> StayResponse {
        struct Body: Encodable {
            let stayId: String; let cityId: String; let day: String; let endsAt: Date
            let appearance: EncounterAppearance
        }
        return try await encounterResponse(path: "/v1/stays", method: "POST", body: Body(
            stayId: stay.stayId, cityId: stay.cityId, day: stay.day, endsAt: stay.endsAt, appearance: stay.appearance), enabled: enabled)
    }

    func stayStatus(stayID: String, enabled: Bool) async throws -> StayResponse {
        guard enabled, encountersAvailable() else { throw HubClientError.disabled }
        guard UUID(uuidString: stayID) != nil else { throw HubClientError.invalidRequest }
        return try decodeStay(await sendSigned(makeRequest(path: "/v1/stays/\(stayID)")))
    }

    func syncCollection(_ collection: [String], enabled: Bool) async throws {
        guard enabled, encountersAvailable() else { throw HubClientError.disabled }
        struct Body: Encodable { let collection: [String] }
        let request = try jsonRequest(path: "/v1/sync", method: "PUT", body: Body(collection: collection))
        _ = try await sendSigned(request)
    }

    /// Deletion stays available even when encounters have been switched off remotely or locally.
    func deleteMe() async throws {
        var request = try makeRequest(path: "/v1/me")
        request.httpMethod = "DELETE"
        _ = try await sendSigned(request)
    }

    private func encounterResponse<Body: Encodable>(path: String, method: String, body: Body, enabled: Bool) async throws -> StayResponse {
        guard enabled, encountersAvailable() else { throw HubClientError.disabled }
        return try decodeStay(await sendSigned(jsonRequest(path: path, method: method, body: body)))
    }

    private func decodeStay(_ data: Data) throws -> StayResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw HubClientError.invalidResponse }
            return date
        }
        let response = try decoder.decode(StayResponse.self, from: data)
        guard response.status == "waiting" || (response.status == "paired" && response.partner != nil && response.pairedAt != nil) else {
            throw HubClientError.invalidResponse
        }
        return response
    }

    private func jsonRequest<Body: Encodable>(path: String, method: String, body: Body) throws -> URLRequest {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HubClientError.disabled
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = prefix.isEmpty ? path : "/" + prefix + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw HubClientError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func sendSigned(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        if privateKey == nil {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: await keyLoader())
        }
        guard let privateKey else { throw HubClientError.invalidRequest }
        let signed = try HubRequestSigner.signed(request, privateKey: privateKey,
                                                 timestamp: Int64(max(0, Date().timeIntervalSince1970)))
        return try await send(signed)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else { throw HubClientError.httpStatus(response.statusCode) }
        return data
    }

    private func persistConfig() {
        guard let configURL, let cached, let data = try? JSONEncoder().encode(cached) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    static func urlSessionTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: HubRedirectBlocker(), delegateQueue: nil)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw HubClientError.invalidResponse }
            return (data, response)
        }
    }
}

/// Do not forward the signed wish body or anonymous device identifier to another origin.
private final class HubRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
