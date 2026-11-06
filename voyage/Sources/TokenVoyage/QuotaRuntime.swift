import Foundation
import Observation
import VoyageCore

enum QuotaSource: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, otherTools
    var id: String { rawValue }
    var provider: (any QuotaProvider)? {
        switch self {
        case .codex: CodexQuota()
        case .claude: ClaudeQuota()
        case .otherTools: nil
        }
    }
    func name(_ l10n: L10n) -> String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .otherTools: l10n("accounts.otherTools")
        }
    }
}

enum QuotaFailure: Equatable, Sendable {
    case expired, rateLimited(Date?), unavailable(QuotaUnavailable)
}

struct QuotaAccountState: Equatable, Sendable {
    var linked = false
    var status: QuotaStatus = .notLinked
    var readings: [QuotaReading] = []
    var failure: QuotaFailure?
    var isRefreshing = false

    /// Cached authentication failures are retained internally but never shown as current percentages.
    var displayedReadings: [QuotaReading] {
        switch status {
        case .ok, .stale: readings
        default: []
        }
    }
}

private enum QuotaOutcome: Sendable {
    case success([QuotaReading]), failure(QuotaFailure), cancelled
}

@MainActor
@Observable
final class QuotaRuntime {
    static let interval: TimeInterval = 600
    private(set) var accounts: [QuotaSource: QuotaAccountState]
    private let defaults: UserDefaults
    private let disabled: Bool
    private let credentials: LocalCredentials.Reader
    private let transport: any QuotaTransport
    private let otherReader: @Sendable () async throws -> [ProviderQuota]
    private let now: @Sendable () -> Date
    private let timeout: Duration
    @ObservationIgnored private var requests: [QuotaSource: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [QuotaSource: Task<Void, Never>] = [:]
    private var generations: [QuotaSource: UUID] = [:]
    private var failures: [QuotaSource: Int] = [:]
    private var nextAttempts: [QuotaSource: Date] = [:]

    init(defaults: UserDefaults, disabled: Bool = false,
         credentials: @escaping LocalCredentials.Reader = { try await LocalCredentials().read($0) },
         transport: any QuotaTransport = ProviderQuotaTransport(),
         otherReader: @escaping @Sendable () async throws -> [ProviderQuota] = UsageSource.fetchQuotas,
         now: @escaping @Sendable () -> Date = Date.init, timeout: Duration = .seconds(20)) {
        self.defaults = defaults
        self.disabled = disabled
        self.credentials = credentials
        self.transport = transport
        self.otherReader = otherReader
        self.now = now
        self.timeout = timeout
        accounts = Dictionary(uniqueKeysWithValues: QuotaSource.allCases.map { source in
            let linked = !disabled && defaults.bool(forKey: Self.key(source))
            return (source, QuotaAccountState(linked: linked, status: linked ? .unavailable(.network) : .notLinked))
        })
    }

    static func key(_ source: QuotaSource) -> String { "quota.linked.\(source.rawValue)" }
    func account(_ source: QuotaSource) -> QuotaAccountState { accounts[source]! }
    var hasLinkedAccounts: Bool { accounts.values.contains { $0.linked } }

    func link(_ source: QuotaSource) async {
        guard !disabled else { return }
        await begin(source, linking: true)?.value
    }

    func disconnect(_ source: QuotaSource) {
        cancel(source)
        accounts[source] = QuotaAccountState()
        failures[source] = nil
        nextAttempts[source] = nil
        if !disabled { defaults.set(false, forKey: Self.key(source)) }
    }

    /// Only lifecycle events and the explicit refresh action call this. Scans never call it.
    func refresh() async {
        let tasks = QuotaSource.allCases.compactMap { begin($0) }
        for task in tasks { await task.value }
    }

    func trigger() {
        for source in QuotaSource.allCases {
            if case .expired = account(source).status { continue }
            _ = begin(source)
        }
    }

    func stop() {
        for source in QuotaSource.allCases { cancel(source); accounts[source]?.isRefreshing = false }
    }

    private func cancel(_ source: QuotaSource) {
        generations[source] = UUID()
        requests.removeValue(forKey: source)?.cancel()
        retries.removeValue(forKey: source)?.cancel()
    }

    @discardableResult
    private func begin(_ source: QuotaSource, linking: Bool = false) -> Task<Void, Never>? {
        guard !disabled, linking || account(source).linked else { return nil }
        // Even manual refresh respects provider Retry-After/backoff. A new login validation may try again.
        guard linking || nextAttempts[source].map({ now() >= $0 }) != false else { return nil }
        cancel(source)
        let generation = UUID()
        generations[source] = generation
        accounts[source]?.isRefreshing = true
        let credentials = credentials, transport = transport, otherReader = otherReader, now = now, timeout = timeout
        let task = Task { [weak self] in
            let outcome = await quotaTimeout(timeout) {
                do {
                    try Task.checkCancellation()
                    if let provider = source.provider {
                        // Credential and request live only in this operation, never in runtime state or UI.
                        let credential = try await credentials(source)
                        try Task.checkCancellation()
                        let request = try provider.request(credential: credential)
                        let response = try await transport.send(request)
                        try Task.checkCancellation()
                        switch response.statusCode {
                        case 200:
                            return .success([try provider.parse(response.data, readAt: now())])
                        case 401, 403: return .failure(.expired)
                        case 429:
                            return .failure(.rateLimited(Self.retryAfter(response.headers, now: now())))
                        case 500...599: return .failure(.unavailable(.service))
                        default: return .failure(.unavailable(.invalidResponse))
                        }
                    }
                    let rows = try await otherReader()
                    try Task.checkCancellation()
                    let readings = Self.otherReadings(rows, at: now())
                    guard !readings.isEmpty else { return .failure(.unavailable(.localSource)) }
                    return .success(readings)
                } catch is CancellationError { return .cancelled }
                catch QuotaProviderError.missingLogin { return .failure(.unavailable(.missingLogin)) }
                catch QuotaProviderError.invalidResponse { return .failure(.unavailable(.invalidResponse)) }
                catch let error as URLError where error.code == .timedOut { return .failure(.unavailable(.timedOut)) }
                catch UsageError.timedOut { return .failure(.unavailable(.timedOut)) }
                catch { return .failure(.unavailable(source == .otherTools ? .localSource : .network)) }
            }
            guard let self, self.generations[source] == generation else { return }
            self.requests[source] = nil
            self.accounts[source]?.isRefreshing = false
            switch outcome {
            case .cancelled: break
            case .success(let readings):
                self.accounts[source] = QuotaAccountState(linked: true, status: .ok, readings: readings)
                self.failures[source] = nil
                self.nextAttempts[source] = nil
                if linking { self.defaults.set(true, forKey: Self.key(source)) }
            case .failure(let failure):
                self.apply(failure, to: source)
            }
        }
        requests[source] = task
        return task
    }

    private func apply(_ failure: QuotaFailure, to source: QuotaSource) {
        accounts[source]?.failure = failure
        switch failure {
        case .expired:
            accounts[source]?.status = .expired
            nextAttempts[source] = nil
            return // No automatic retry or token refresh after unauthorized responses.
        case .rateLimited(let until): accounts[source]?.status = .rateLimited(until: until)
        case .unavailable(let reason):
            if let last = account(source).readings.map(\.readAt).min() {
                accounts[source]?.status = .stale(lastGoodAt: last)
            } else { accounts[source]?.status = .unavailable(reason) }
        }
        let count = min((failures[source] ?? 0) + 1, 8)
        failures[source] = count
        let backoff = min(3600, 30 * pow(2, Double(count - 1)))
        let until: Date
        if case .rateLimited(let requested?) = failure { until = requested }
        else { until = now().addingTimeInterval(backoff) }
        nextAttempts[source] = until
        if case .rateLimited = failure {
            accounts[source]?.failure = .rateLimited(until)
            if let last = account(source).readings.map(\.readAt).min() {
                accounts[source]?.status = .stale(lastGoodAt: last)
            } else { accounts[source]?.status = .rateLimited(until: until) }
        }
        guard account(source).linked else { return }
        let delay = max(0, until.timeIntervalSince(now()))
        retries[source] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.begin(source)
        }
    }

    nonisolated static func retryAfter(_ headers: [String: String], now: Date) -> Date? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0,
           seconds <= Date.distantFuture.timeIntervalSince(now) { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(now, $0) }
    }

    nonisolated static func otherReadings(_ rows: [ProviderQuota], at date: Date) -> [QuotaReading] {
        rows.filter { !["codex", "claude"].contains($0.provider.lowercased()) }.compactMap { row in
            let windows = row.metrics.compactMap { metric -> QuotaWindow? in
                guard metric.remainingPercent.isFinite, (0...100).contains(metric.remainingPercent) else { return nil }
                let kind: QuotaWindowKind = switch metric.label.lowercased() {
                case "weekly": .weekly
                case "daily": .daily
                case "monthly": .monthly
                case "session": .session
                default: .other
                }
                let reset = metric.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) ?? DayKey.date(from: $0) }
                return QuotaWindow(kind: kind, remainingPercent: metric.remainingPercent, resetsAt: reset)
            }
            guard !windows.isEmpty else { return nil }
            // Provider identifiers are public tool names; no account/plan/label fields are forwarded.
            let tool = row.provider.lowercased()
            guard !tool.isEmpty, tool.count <= 64,
                  tool.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 32 }) else { return nil }
            return QuotaReading(providerID: tool, windows: windows, readAt: date)
        }
    }

    func withSnapshotAccounts(_ examples: [QuotaSource: QuotaAccountState], render: () -> Void) {
        precondition(disabled)
        let original = accounts
        accounts = examples
        defer { accounts = original }
        render()
    }
}

/// An ephemeral session with redirects, cookies, credentials and disk caches disabled.
struct ProviderQuotaTransport: QuotaTransport {
    func send(_ request: URLRequest) async throws -> QuotaHTTPResponse {
        guard let url = request.url, url.scheme == "https",
              (url.host == "chatgpt.com" && url.path == "/backend-api/wham/usage") ||
              (url.host == "api.anthropic.com" && url.path == "/api/oauth/usage") else {
            throw QuotaProviderError.invalidResponse
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: QuotaRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaProviderError.invalidResponse }
        var headers: [String: String] = [:]
        if let retry = http.value(forHTTPHeaderField: "Retry-After") { headers["Retry-After"] = retry }
        return QuotaHTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}

private final class QuotaRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A timeout must return even if an injected reader/transport ignores cancellation.
private func quotaTimeout(_ timeout: Duration, operation: @escaping @Sendable () async -> QuotaOutcome) async -> QuotaOutcome {
    let race = QuotaRace()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            race.start(continuation, timeout: timeout, operation: operation)
        }
    } onCancel: { race.finish(.cancelled) }
}

private final class QuotaRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<QuotaOutcome, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var result: QuotaOutcome?

    func start(_ continuation: CheckedContinuation<QuotaOutcome, Never>, timeout: Duration,
               operation: @escaping @Sendable () async -> QuotaOutcome) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result); return }
        self.continuation = continuation
        tasks = [
            Task { self.finish(await operation()) },
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.finish(.failure(.unavailable(.timedOut)))
            },
        ]
        lock.unlock()
    }

    func finish(_ result: QuotaOutcome) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation, tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
