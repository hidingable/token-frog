import Foundation

public struct StoryReply: Codable, Equatable, Sendable {
    public var id: String
    public var habit: String
    public var text: [String: String]
}

public struct StoryRewards: Codable, Equatable, Sendable {
    public var itemIds: [String] = []
    public var menuIds: [String] = []
    public var dropRarity: String?
    public var duplicateClueCityId: String?
    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        itemIds = try values.decode([String].self, forKey: .itemIds)
        menuIds = try values.decode([String].self, forKey: .menuIds)
        dropRarity = try values.decodeIfPresent(String.self, forKey: .dropRarity)
        duplicateClueCityId = try values.decodeIfPresent(String.self, forKey: .duplicateClueCityId)
    }
}

public struct Story: Codable, Equatable, Sendable, Identifiable {
    public struct Requirements: Codable, Equatable, Sendable {
        public var habit: String?
        public var item: String?
        public var season: String?
        public var tool: String?
        public var rainySeason: Bool?

        public var isEmpty: Bool {
            habit == nil && item == nil && season == nil && tool == nil && rainySeason == nil
        }
    }

    public var id: String
    public var version: Int
    public var kind: String
    public var cityId: String?
    public var factIds: [String]
    public var tags: [String]
    public var requires: Requirements
    public var fulfills: [String]
    public var fulfillsHabit: String?
    public var lead: [String: String]?
    public var text: [String: String]
    public var replies: [StoryReply]
    public var rewards: StoryRewards
    public var learned: [String: String]?
    public var memoryLead: [String: String]? = nil
}

/// Loaded and validated with CityCatalog; sorted IDs make file order irrelevant to draws.
public struct StoryLibrary: Sendable {
    public let all: [Story]
    private var remoteIDs: Set<String> = []

    init(stories: [Story]) { all = stories.sorted { $0.id < $1.id } }

    func addingRemote(_ entries: [Story]) -> StoryLibrary {
        let existing = Set(all.map(\.id))
        let additions = entries.filter { !existing.contains($0.id) }
        var result = StoryLibrary(stories: all + additions)
        result.remoteIDs = remoteIDs.union(additions.map(\.id))
        return result
    }

    func availableForTrip(_ ids: Set<String>) -> StoryLibrary {
        guard !remoteIDs.isEmpty else { return self }
        return StoryLibrary(stories: all.filter { !remoteIDs.contains($0.id) || ids.contains($0.id) })
    }
}

enum StorySlots {
    static let pattern = try! NSRegularExpression(pattern: #"\{([^{}]*)\}"#)

    static func names(in text: String) -> Set<String> {
        Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        })
    }

    /// Replace matches in the original template only: names and quoted replies are literal input.
    static func render(_ template: String, values: [String: String]) -> String {
        var text = template
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let name = String(template[Range(match.range(at: 1), in: template)!])
            text.replaceSubrange(Range(match.range, in: text)!, with: values[name]!)
        }
        return text
    }
}
