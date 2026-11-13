import Foundation

public struct IdentityContent: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public let id: TravellerIdentity
        public let name: [String: String]
        public let letters: [String: [String: String]]
    }
    public let version: Int
    public let identities: [Entry]

    public func entry(_ identity: TravellerIdentity) -> Entry {
        identities.first { $0.id == identity }!
    }

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("identities.json")))
        func complete(_ texts: [String: String], slots: Set<String>) -> Bool {
            Language.allCases.allSatisfy { language in
                guard let text = texts[language.rawValue], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                let literal = StorySlots.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                return StorySlots.names(in: text) == slots && !literal.contains("{") && !literal.contains("}") && !text.contains("<")
            }
        }
        guard content.version > 0, content.identities.count == TravellerIdentity.allCases.count,
              Set(content.identities.map(\.id)) == Set(TravellerIdentity.allCases),
              content.identities.allSatisfy({ entry in
                  complete(entry.name, slots: []) && ["first", "changed", "same", "zero", "zeroChanged", "zeroSame"].allSatisfy {
                      complete(entry.letters[$0] ?? [:], slots: ["pet"])
                  }
              }) else {
            throw ContentValidationError(issues: [.init(file: "identities.json", rule: "identities", message: "All six identities require bilingual names and first/changed/same letters, including zero-score variants, using the pet slot")])
        }
        return content
    }
}

