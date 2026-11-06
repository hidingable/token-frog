import Foundation

public struct CodexQuota: QuotaProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let linkMethods: [QuotaLinkMethod] = [.localLogin]

    public init() {}

    public func request(credential: QuotaCredential) throws -> URLRequest {
        try credential.validateForRequest()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    public func parse(_ data: Data, readAt: Date) throws -> QuotaReading {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(Response.self, from: data)
            var windows: [QuotaWindow] = []
            if let window = response.rateLimit?.primaryWindow {
                windows.append(try window.reading(defaultKind: .session))
            }
            if let window = response.rateLimit?.secondaryWindow {
                windows.append(try window.reading(defaultKind: .weekly))
            }
            guard !windows.isEmpty else { throw QuotaProviderError.invalidResponse }
            return QuotaReading(providerID: id, windows: windows, readAt: readAt)
        } catch {
            // Decoder errors can contain raw values. Keep them inside this boundary.
            throw QuotaProviderError.invalidResponse
        }
    }

    private struct Response: Decodable {
        let rateLimit: RateLimit?
    }

    private struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let resetAt: QuotaResetTime?
        let limitWindowSeconds: Double?

        func reading(defaultKind: QuotaWindowKind) throws -> QuotaWindow {
            let kind: QuotaWindowKind
            switch limitWindowSeconds {
            case 2_592_000: kind = .monthly
            case let seconds? where seconds >= 604_800: kind = .weekly
            case let seconds? where seconds >= 86_400: kind = .daily
            case 18_000: kind = .session
            default: kind = defaultKind
            }
            return try quotaWindow(kind: kind, usedPercent: usedPercent, resetsAt: resetAt)
        }
    }
}
