import Foundation

public struct StoryReply: Codable, Equatable, Sendable {
    public var id: String
    public var habit: String
    public var text: [String: String]
}

public struct StoryRewards: Codable, Equatable, Sendable {
    public var itemIds: [String] = []
    public var menuIds: [String] = []
    public init() {}
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
}

/// Loaded and validated with CityCatalog; sorted IDs make file order irrelevant to draws.
public struct StoryLibrary: Sendable {
    public let all: [Story]

    init(stories: [Story]) { all = stories.sorted { $0.id < $1.id } }
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
