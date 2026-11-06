import Foundation

public struct ClaudeQuota: QuotaProvider {
    public let id = "claude"
    public let displayName = "Claude"
    public let linkMethods: [QuotaLinkMethod] = [.localLogin]

    public init() {}

    public func request(credential: QuotaCredential) throws -> URLRequest {
        try credential.validateForRequest()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    public func parse(_ data: Data, readAt: Date) throws -> QuotaReading {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(Response.self, from: data)
            let sources: [(QuotaWindowKind, Window?)] = [
                (.session, response.fiveHour),
                (.weekly, response.sevenDay),
                (.weeklySonnet, response.sevenDaySonnet),
                (.weeklyOpus, response.sevenDayOpus),
            ]
            let windows = try sources.compactMap { kind, window in
                try window.map { try quotaWindow(kind: kind, usedPercent: $0.utilization, resetsAt: $0.resetsAt) }
            }
            guard !windows.isEmpty else { throw QuotaProviderError.invalidResponse }
            return QuotaReading(providerID: id, windows: windows, readAt: readAt)
        } catch {
            throw QuotaProviderError.invalidResponse
        }
    }

    private struct Response: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDaySonnet: Window?
        let sevenDayOpus: Window?
    }

    private struct Window: Decodable {
        let utilization: Double
        let resetsAt: QuotaResetTime?
    }
}
