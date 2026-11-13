import Foundation
import Testing
@testable import VoyageCore

@Suite struct FriendContentTests {
    @Test func bundledFriendsHaveBothMeetingVariantsNotesAndDistinctPaletteSprites() {
        let content = testCatalog.friends
        #expect(content.version > 0 && content.friends.count == 6)
        #expect(Set(content.friends.map(\.id)).count == content.friends.count)
        #expect(Set(content.friends.map { $0.sprite.rows.joined() }).count == content.friends.count)
        let palette = Set(testCatalog.pets.palette.keys).union(["."])
        for friend in content.friends {
            #expect(friend.notes.count >= 5)
            #expect(friend.sprite.size == [16, 16] && friend.sprite.rows.count == 16)
            #expect(friend.sprite.rows.allSatisfy { $0.count == 16 && Set($0).isSubset(of: palette) })
            #expect(friend.sprite.rows.contains { $0.contains { $0 != "." } })
            for language in Language.allCases {
                let key = language.rawValue
                #expect(friend.name[key]?.isEmpty == false && friend.intro[key]?.isEmpty == false)
                #expect(friend.notes.allSatisfy { $0[key]?.isEmpty == false })
                #expect(StorySlots.names(in: friend.letters["city"]![key]!) == ["pet", "city"])
                #expect(StorySlots.names(in: friend.letters["noCity"]![key]!) == ["pet"])
            }
        }
    }

    @Test(arguments: ["empty", "duplicate"])
    func emptyPoolsAndDuplicateIDsAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            if failure == "empty" { friends = [] }
            else { friends[0]["id"] = friends[1]["id"] }
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "friends.json" && $0.rule == "friends" })
    }

    @Test(arguments: ["name", "intro", "city", "noCity", "note"], ["zh-Hans", "en"])
    func everyNameIntroMeetingAndNoteRequiresBothLanguages(field: String, language: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            if ["name", "intro"].contains(field) {
                var texts = friends[0][field] as! [String: String]
                texts.removeValue(forKey: language)
                friends[0][field] = texts
            } else if field == "note" {
                var notes = friends[0]["notes"] as! [[String: String]]
                notes[0].removeValue(forKey: language)
                friends[0]["notes"] = notes
            } else {
                var letters = friends[0]["letters"] as! [String: [String: String]]
                letters[field]!.removeValue(forKey: language)
                friends[0]["letters"] = letters
            }
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
    }

    @Test(arguments: ["city", "noCity"])
    func missingEitherMeetingVariantIsRejected(variant: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            var letters = friends[0]["letters"] as! [String: [String: String]]
            letters.removeValue(forKey: variant)
            friends[0]["letters"] = letters
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
    }

    @Test func fewerThanFiveNotesIsRejected() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            friends[0]["notes"] = Array((friends[0]["notes"] as! [[String: String]]).prefix(4))
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
    }

    @Test(arguments: ["dimensions", "rows", "width", "palette", "transparent"])
    func malformedSpritesAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            var sprite = friends[0]["sprite"] as! [String: Any]
            var rows = sprite["rows"] as! [String]
            switch failure {
            case "dimensions": sprite["size"] = [15, 16]
            case "rows": rows.removeLast()
            case "width": rows[0] = String(rows[0].dropLast())
            case "palette": rows[0] = "?" + String(rows[0].dropFirst())
            default: rows = Array(repeating: String(repeating: ".", count: 16), count: 16)
            }
            sprite["rows"] = rows
            friends[0]["sprite"] = sprite
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
    }

    @Test(arguments: ["blank", "unknown-slot", "missing-city", "markup"])
    func invalidMeetingCopyIsRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            var letters = friends[0]["letters"] as! [String: [String: String]]
            let text: String
            switch failure {
            case "blank": text = " \n "
            case "unknown-slot": text = "{pet} met {stranger} in {city}."
            case "missing-city": text = "{pet} met a new friend."
            default: text = "<b>{pet}</b> met a new friend in {city}."
            }
            letters["city"]!["en"] = text
            friends[0]["letters"] = letters
            json["friends"] = friends
        }
        #expect(throws: ContentValidationError.self) { try FriendContent.load(directory: box.directory) }
    }
}
