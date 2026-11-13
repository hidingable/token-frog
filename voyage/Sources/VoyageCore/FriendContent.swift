import Foundation

public struct FriendContent: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: [String: String]
        public let intro: [String: String]
        public let letters: [String: [String: String]]
        public let notes: [[String: String]]
        public let sprite: PixelSprite
    }
    public let version: Int
    public let friends: [Entry]

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("friends.json")))
        let palette = Set(try PetCatalog.readPalette(directory: directory).keys)
        func complete(_ texts: [String: String], slots: Set<String> = []) -> Bool {
            Language.allCases.allSatisfy { language in
                guard let text = texts[language.rawValue], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                let literal = StorySlots.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                return StorySlots.names(in: text) == slots && !literal.contains("{") && !literal.contains("}") && !text.contains("<")
            }
        }
        guard content.version > 0, !content.friends.isEmpty,
              Set(content.friends.map(\.id)).count == content.friends.count,
              content.friends.allSatisfy({ friend in
                  friend.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
                      && complete(friend.name) && complete(friend.intro)
                      && complete(friend.letters["city"] ?? [:], slots: ["pet", "city"])
                      && complete(friend.letters["noCity"] ?? [:], slots: ["pet"])
                      && friend.notes.count >= 5 && friend.notes.allSatisfy { complete($0) }
                      && friend.sprite.size == [16, 16] && friend.sprite.rows.count == 16
                      && friend.sprite.rows.allSatisfy { $0.count == 16 && $0.allSatisfy { palette.contains(String($0)) } }
                      && friend.sprite.rows.contains { $0.contains { $0 != "." } }
              }) else {
            throw ContentValidationError(issues: [.init(file: "friends.json", rule: "friends", message: "Friends require unique IDs, bilingual names, intros, city/noCity letters, five notes and a 16x16 palette sprite")])
        }
        return content
    }
}
