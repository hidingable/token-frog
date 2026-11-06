import Foundation
import Testing
@testable import VoyageCore

private extension ContentSandbox {
    func firstPetFile() throws -> URL {
        try #require(PetCatalog.readPets(directory: directory).first?.file)
    }

    func editPet(_ body: (inout [String: Any]) -> Void) throws {
        let file = try firstPetFile()
        try edit("pets/\(file.lastPathComponent)", body)
    }

    func editSprite(_ target: String, _ body: (inout [String: Any]) -> Void) throws {
        let path = target == "pet" ? "pets/\(try firstPetFile().lastPathComponent)"
            : target == "icon" ? "sprites/icons.json" : "sprites/eggs.json"
        let key = target == "pet" ? "sprite"
            : target == "icon" ? try #require(PetCatalog.readIcons(directory: directory).keys.sorted().first) : target
        try edit(path) { json in
            var sprite = json[key] as! [String: Any]
            body(&sprite)
            json[key] = sprite
        }
    }
}

@Suite struct PetContentTests {
    @Test func repositoryPetsAndSpritesLoadAsOneValidatedCatalog() throws {
        #expect(ContentValidator.validatePets(directory: contentDirectory).isEmpty)
        let pets = try PetCatalog.load(directory: contentDirectory)
        #expect(!pets.all.isEmpty)
        #expect(pets.all.map(\.order) == pets.all.map(\.order).sorted())
        #expect(pets.find(pets.defaultID)?.id == pets.all.first?.id)
        #expect(pets.find(PetID(rawValue: "missing-pet")) == nil)
        #expect(!pets.icons.isEmpty)
    }

    @Test func addingAPetOnlyRequiresAContentFile() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let entries = try PetCatalog.readPets(directory: box.directory)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: entries[0].file)) as? [String: Any])
        json["id"] = "new-pet"
        json["order"] = try #require(entries.map(\.pet.order).max()) + 1
        json["names"] = ["zh-Hans": "新伙伴", "en": "New friend"]
        try JSONSerialization.data(withJSONObject: json).write(to: box.directory.appendingPathComponent("pets/new-pet.json"))
        #expect(ContentValidator.validate(directory: box.directory).isEmpty)
        let catalog = try CityCatalog.load(directory: box.directory)
        #expect(catalog.pets.all.count == entries.count + 1)
        #expect(catalog.pets.find(PetID(rawValue: "new-pet"))?.names["en"] == "New friend")
    }

    @Test func atLeastOnePetIsRequired() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        for entry in try PetCatalog.readPets(directory: box.directory) {
            try FileManager.default.removeItem(at: entry.file)
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petCount" })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: ["empty", "duplicate"])
    func petIdsMustBeNonemptyAndUnique(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        if failure == "empty" { try box.editPet { $0["id"] = "" } }
        else {
            try FileManager.default.copyItem(at: box.firstPetFile(), to: box.directory.appendingPathComponent("pets/duplicate.json"))
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petID" })
    }

    @Test func petFilenameMustEqualItsId() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editPet { $0["id"] = "different-file" }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petFilename" })
    }

    @Test func displayOrdersMustBeUnique() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try FileManager.default.copyItem(at: box.firstPetFile(), to: box.directory.appendingPathComponent("pets/duplicate-order.json"))
        try box.edit("pets/duplicate-order.json") { $0["id"] = "duplicate-order" }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petOrder" })
    }

    @Test(arguments: ["names", "eggNames", "quirks"], ["missing-zh", "missing-en", "blank-zh", "blank-en"])
    func allPetTextsRequireBothLanguages(field: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editPet { json in
            let language = failure.hasSuffix("zh") ? "zh-Hans" : "en"
            let value: String? = failure.hasPrefix("missing") ? nil : " \n\t "
            if field == "quirks" {
                var quirks = json[field] as! [[String: String]]
                quirks[0][language] = value
                json[field] = quirks
            } else {
                var texts = json[field] as! [String: String]
                texts[language] = value
                json[field] = texts
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petTranslation" })
    }

    @Test(arguments: ["zh-Hans", "en"], ["too-long", "at-limit", "grapheme-limit"])
    func defaultNameLimitCountsSwiftCharacters(language: String, example: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editPet { json in
            var names = json["names"] as! [String: String]
            names[language] = example == "grapheme-limit" ? String(repeating: "👨‍👩‍👧‍👦", count: 12)
                : String(repeating: "a", count: example == "too-long" ? 13 : 12)
            json["names"] = names
        }
        let issues = ContentValidator.validate(directory: box.directory)
        #expect(issues.contains { $0.rule == "petNameLength" } == (example == "too-long"))
    }

    @Test func everyPetRequiresAtLeastThreeQuirks() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editPet { $0["quirks"] = Array(($0["quirks"] as! [[String: String]]).prefix(2)) }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petQuirks" })
    }

    @Test(arguments: ["pet", "base", "cracked", "placeholder", "icon"], ["width", "height", "extra-dimension", "no-dimensions", "row-count", "row-length", "unknown-character"])
    func spritesRequireTheDeclaredGridAndPalette(target: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editSprite(target) { sprite in
            var size = sprite["size"] as! [Int]
            var rows = sprite["rows"] as! [String]
            switch failure {
            case "width": size[0] -= 1
            case "height": size[1] -= 1
            case "extra-dimension": size.append(1)
            case "no-dimensions": size = []
            case "row-count": rows.removeLast()
            case "row-length": rows[0].removeLast()
            default: rows[0] = "?" + rows[0].dropFirst()
            }
            sprite["size"] = size
            sprite["rows"] = rows
        }
        let rule = failure == "unknown-character" ? "spriteCharacter"
            : failure.hasPrefix("row-") ? "spriteRows" : "spriteSize"
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
    }

    @Test(arguments: ["long-key", "empty-key", "missing-transparency", "opaque-transparency", "null-color", "missing-hash", "short-color", "trailing-line-break", "invalid-hex"])
    func paletteRequiresSingleCharactersTransparencyAndHexColors(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("sprites/palette.json") { palette in
            switch failure {
            case "long-key": palette["kk"] = "#123456"
            case "empty-key": palette[""] = "#123456"
            case "missing-transparency": palette.removeValue(forKey: ".")
            case "opaque-transparency": palette["."] = "#123456"
            case "null-color": palette["k"] = NSNull()
            case "missing-hash": palette["k"] = "123456"
            case "short-color": palette["k"] = "#12345"
            case "trailing-line-break": palette["k"] = "#123456\n"
            default: palette["k"] = "#12345G"
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "spritePalette" })
    }

    @Test(arguments: ["unknown-source", "unknown-target", "long-source", "long-target", "empty-source", "empty-target"])
    func eggRecoloringOnlyMapsSinglePaletteCharacters(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editPet { json in
            let source = failure == "unknown-source" ? "?" : failure == "long-source" ? "ww" : failure == "empty-source" ? "" : "w"
            let target = failure == "unknown-target" ? "?" : failure == "long-target" ? "yy" : failure == "empty-target" ? "" : "y"
            json["egg"] = ["recolor": [source: target]]
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petRecolor" })
    }

    @Test func itemIconCatalogCannotBeEmpty() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("sprites/icons.json") { $0 = [:] }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "spriteIcons" })
    }

    @Test func newlyDeclaredIconsCanBeReferencedByItems() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("sprites/palette.json") { $0["z"] = "#abcdef" }
        try box.edit("sprites/icons.json") { icons in
            icons["new-icon"] = ["size": [12, 12], "rows": Array(repeating: String(repeating: "z", count: 12), count: 12)]
        }
        try box.editItems { $0[0].icon = "new-icon" }
        #expect(ContentValidator.validate(directory: box.directory).isEmpty)
        let pets = try CityCatalog.load(directory: box.directory).pets
        #expect(pets.icons["new-icon"]?.size == [12, 12])
    }

    @Test(arguments: ["missing-pets", "pet-json", "pet-fields", "unreadable-pet", "missing-palette", "palette-json", "missing-eggs", "eggs-json", "missing-icons", "icons-json"])
    func missingAndMalformedFilesBecomeContentValidationErrors(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let rule: String
        switch failure {
        case "missing-pets":
            try FileManager.default.removeItem(at: box.directory.appendingPathComponent("pets"))
            rule = "petJSON"
        case "pet-json", "pet-fields":
            try Data((failure == "pet-json" ? "{" : "{}").utf8).write(to: box.directory.appendingPathComponent("pets/broken.json"))
            rule = "petJSON"
        case "unreadable-pet":
            try FileManager.default.createDirectory(at: box.directory.appendingPathComponent("pets/broken.json"), withIntermediateDirectories: false)
            rule = "petJSON"
        default:
            let name = failure.hasPrefix("missing-") ? String(failure.dropFirst("missing-".count))
                : String(failure.dropLast("-json".count))
            let file = box.directory.appendingPathComponent("sprites/\(name).json")
            if failure.hasPrefix("missing") { try FileManager.default.removeItem(at: file) }
            else { try Data("{".utf8).write(to: file) }
            rule = name == "palette" ? "spritePalette" : name == "eggs" ? "spriteEggs" : "spriteIcons"
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
        #expect(throws: ContentValidationError.self) { try PetCatalog.load(directory: box.directory) }
    }
}
