import Foundation

public struct WishResolution: Codable, Equatable, Sendable {
    public var tags: [String]
    public var parsedAt: Date
    public var weekStart: String
    public var explanationLetterId: Int?
}

/// Only writing a wish parses it. Journey and care consume the saved result.
public enum WishEngine {
    public static let characterLimit = 40

    public static func tags(in care: CareState) -> Set<String> {
        care.wish == nil ? [] : Set(care.wishResolution?.tags ?? [])
    }

    @discardableResult
    public static func write(_ text: String, tags: Set<String>, at date: Date, care: inout CareState, calendar: Calendar = .current) -> Bool {
        guard text.count <= characterLimit else { return false }
        refreshWeek(at: date, care: &care, calendar: calendar)
        guard text != (care.wish ?? "") || (!text.isEmpty && care.wishResolution == nil) else { return true }
        care.wish = text.isEmpty ? nil : text
        care.wishResolution = text.isEmpty ? nil : WishResolution(
            tags: tags.sorted(), parsedAt: date,
            weekStart: WeeklyEngine.weekStart(for: DayKey.string(from: date, calendar: calendar), calendar: calendar)!
        )
        return true
    }

    @discardableResult
    public static func refreshWeek(at date: Date, care: inout CareState, calendar: Calendar = .current) -> Bool {
        guard care.wish != nil || care.wishResolution != nil,
              let week = WeeklyEngine.weekStart(for: DayKey.string(from: date, calendar: calendar), calendar: calendar),
              week > (care.wishResolution?.weekStart ?? care.weekly.weekStart) else { return false }
        care.wish = nil
        care.wishResolution = nil
        return true
    }
}

public struct WishContent: Sendable {
    public typealias Resolver = @Sendable (_ text: String, _ language: Language, _ allowedTags: [String]) async throws -> [String]
    public let tagIDs: [String]
    public let unmatched: [String: String]
    private let keywords: [String: [String: [String]]]

    private struct Document: Decodable {
        var keywords: [String: [String: [String]]]
        var unmatched: [String: String]
    }

    public static func load(directory: URL) throws -> WishContent {
        let decoder = JSONDecoder()
        let tags = try decoder.decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("tags.json")))
        let document = try decoder.decode(Document.self, from: Data(contentsOf: directory.appendingPathComponent("wish.json")))
        let allowed = Set(tags)
        for language in Language.allCases {
            guard let keywords = document.keywords[language.rawValue], Set(keywords.keys) == allowed,
                  keywords.values.allSatisfy({ words in
                      !words.isEmpty && words.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                          && Set(words.map { $0.lowercased() }).count == words.count
                  }), let unmatched = document.unmatched[language.rawValue],
                  !unmatched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !unmatched.contains("{"), !unmatched.contains("}") else {
                throw ContentValidationError(issues: [.init(file: "wish.json", rule: "wish", message: "Wish keywords must cover existing tags and both languages; explanation must be literal bilingual text")])
            }
        }
        return WishContent(tagIDs: tags.sorted(), unmatched: document.unmatched, keywords: document.keywords)
    }

    public func keywordTags(for text: String, language: Language) -> Set<String> {
        Set(keywords[language.rawValue]!.compactMap { tag, words in
            words.contains { word in
                if language == .zhHans { return text.range(of: word, options: .caseInsensitive) != nil }
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            } ? tag : nil
        })
    }

    public func resolve(_ text: String, language: Language, resolver: Resolver? = nil, timeout: Duration = .seconds(3)) async -> Set<String> {
        guard !text.isEmpty else { return [] }
        let keywords = keywordTags(for: text, language: language)
        guard let resolver else { return keywords }
        let race = WishResolverRace()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation, timeout: timeout) { try? await resolver(text, language, tagIDs) }
            }
        } onCancel: { race.finish(nil) }
        // A successful server answer replaces keywords, even when it is empty.
        guard let result else { return keywords }
        return Set(result).intersection(tagIDs)
    }
}

/// Return on timeout even if an injected resolver ignores cancellation. Late responses cannot mutate saves.
private final class WishResolverRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    func start(_ continuation: CheckedContinuation<[String]?, Never>, timeout: Duration,
               operation: @escaping @Sendable () async -> [String]?) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation
        tasks = [
            Task { self.finish(await operation()) },
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.finish(nil)
            },
        ]
        lock.unlock()
    }

    func finish(_ result: [String]?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
