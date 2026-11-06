import Foundation

public enum QuotaLinkMethod: Sendable {
    case localLogin, apiKey, webAuthorization
}

/// A request-scoped credential. It is never part of display or persistence models.
public struct QuotaCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }

    public var description: String { "QuotaCredential(redacted)" }
    public var debugDescription: String { description }

    func validateForRequest() throws {
        guard !accessToken.isEmpty,
              !accessToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              accountID?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true
        else { throw QuotaProviderError.missingLogin }
    }
}

public enum QuotaWindowKind: String, Sendable {
    case session, weekly, daily, monthly, weeklySonnet, weeklyOpus, other
}

public struct QuotaWindow: Equatable, Sendable, Identifiable {
    public let kind: QuotaWindowKind
    public let remainingPercent: Double
    public let resetsAt: Date?
    public var id: QuotaWindowKind { kind }

    public init(kind: QuotaWindowKind, remainingPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

/// Only quota windows and their observation time cross into the UI.
public struct QuotaReading: Equatable, Sendable {
    public let providerID: String
    public let windows: [QuotaWindow]
    public let readAt: Date

    public init(providerID: String, windows: [QuotaWindow], readAt: Date) {
        self.providerID = providerID
        self.windows = windows
        self.readAt = readAt
    }
}

public enum QuotaUnavailable: String, Sendable {
    case missingLogin, invalidResponse, network, timedOut, service, localSource
}

public enum QuotaStatus: Equatable, Sendable {
    case notLinked
    case ok
    case stale(lastGoodAt: Date)
    case expired
    case rateLimited(until: Date?)
    case unavailable(QuotaUnavailable)
}

public enum QuotaProviderError: Error, Equatable, Sendable {
    case invalidResponse, missingLogin
}

public struct QuotaHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public protocol QuotaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> QuotaHTTPResponse
}

/// Adapters construct requests and decode windows without accessing the local login.
public protocol QuotaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var linkMethods: [QuotaLinkMethod] { get }
    func request(credential: QuotaCredential) throws -> URLRequest
    func parse(_ data: Data, readAt: Date) throws -> QuotaReading
}

/// The native endpoints report either Unix timestamps or ISO 8601 reset dates.
struct QuotaResetTime: Decodable {
    let date: Date

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            guard number.isFinite else { throw QuotaProviderError.invalidResponse }
            date = Date(timeIntervalSince1970: number > 20_000_000_000 ? number / 1000 : number)
            return
        }
        let text = try container.decode(String.self)
        if let number = Double(text), number.isFinite {
            date = Date(timeIntervalSince1970: number > 20_000_000_000 ? number / 1000 : number)
            return
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw QuotaProviderError.invalidResponse
        }
        date = parsed
    }
}

func quotaWindow(kind: QuotaWindowKind, usedPercent: Double, resetsAt: QuotaResetTime?) throws -> QuotaWindow {
    guard usedPercent.isFinite, (0...100).contains(usedPercent) else { throw QuotaProviderError.invalidResponse }
    return QuotaWindow(kind: kind, remainingPercent: 100 - usedPercent, resetsAt: resetsAt?.date)
}
