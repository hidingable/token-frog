import Foundation
import Testing
@testable import VoyageCore

@Suite struct IdentityContentTests {
    @Test func bundledContentHasAllNamesAndLetterVariantsInBothLanguages() {
        let content = testCatalog.identities
        #expect(content.version == 1)
        #expect(Set(content.identities.map(\.id)) == Set(TravellerIdentity.allCases))
        for entry in content.identities {
            for language in Language.allCases {
                #expect(entry.name[language.rawValue]?.isEmpty == false)
                for variant in ["first", "changed", "same", "zero", "zeroChanged", "zeroSame"] {
                    let text = entry.letters[variant]![language.rawValue]!
                    #expect(StorySlots.names(in: text) == ["pet"])
                    #expect(!text.contains("<"))
                }
            }
            #expect(entry.letters["changed"] != entry.letters["same"])
        }
    }

    @Test(arguments: TravellerIdentity.allCases)
    func missingIdentityIsRejected(identity: TravellerIdentity) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("identities.json") { json in
            var entries = json["identities"] as! [[String: Any]]
            entries.removeAll { $0["id"] as? String == identity.rawValue }
            json["identities"] = entries
        }
        #expect(throws: ContentValidationError.self) { try IdentityContent.load(directory: box.directory) }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "identities.json" && $0.rule == "identities" })
    }

    @Test(arguments: ["name", "first", "changed", "same", "zero", "zeroChanged", "zeroSame"], ["zh-Hans", "en"])
    func missingLanguageInAnyNameOrVariantIsRejected(field: String, language: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("identities.json") { json in
            var entries = json["identities"] as! [[String: Any]]
            if field == "name" {
                var names = entries[0]["name"] as! [String: String]
                names.removeValue(forKey: language)
                entries[0]["name"] = names
            } else {
                var letters = entries[0]["letters"] as! [String: [String: String]]
                letters[field]!.removeValue(forKey: language)
                entries[0]["letters"] = letters
            }
            json["identities"] = entries
        }
        #expect(throws: ContentValidationError.self) { try IdentityContent.load(directory: box.directory) }
    }

    @Test(arguments: ["duplicate", "blank", "unknown-slot", "markup"])
    func invalidIdentityCopyIsRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("identities.json") { json in
            var entries = json["identities"] as! [[String: Any]]
            if failure == "duplicate" { entries[0] = entries[1] }
            else {
                var letters = entries[0]["letters"] as! [String: [String: String]]
                letters["first"]!["en"] = failure == "blank" ? "  " : failure == "unknown-slot" ? "{pet} met {stranger}." : "<b>{pet}</b>"
                entries[0]["letters"] = letters
            }
            json["identities"] = entries
        }
        #expect(throws: ContentValidationError.self) { try IdentityContent.load(directory: box.directory) }
    }
}
