import Foundation
import Testing
@testable import VoyageCore

@Suite struct PetFormTests {
    @Test(arguments: [(0, PetForm.hatchling), (1, .hatchling), (4, .hatchling), (5, .juvenile),
                      (19, .juvenile), (20, .teen), (60, .teen), (170, .teen), (340, .teen)])
    func appearanceUsesTheExistingCompanionStage(example: (Int, PetForm)) throws {
        let (days, expected) = example
        let catalog = try PetCatalog.load(directory: contentDirectory)
        let form = PetForm.current(companionDays: days)
        #expect(form == expected)
        for pet in catalog.all {
            #expect(catalog.sprite(pet.id, form: form).size == (days < 5 ? [16, 16] : [20, 20]))
            #expect(catalog.sprite(pet.id, form: form).rows == (days < 5 ? pet.sprite.rows : pet.juvenile.rows))
            #expect(catalog.accessories(pet.id, form: form).isEmpty == (days < 20))
            #expect(catalog.motion(pet.id, form: form).footRows == (days < 5 ? pet.hatchlingMotion.footRows : pet.juvenileMotion.footRows))
        }
    }

    @Test func unknownPetsAlwaysUseTheSixteenPixelPlaceholder() throws {
        let catalog = try PetCatalog.load(directory: contentDirectory)
        let unknown = PetID(rawValue: "unknown")
        for form in PetForm.allCases {
            #expect(catalog.sprite(unknown, form: form).rows == catalog.eggs.placeholder.rows)
            #expect(catalog.motion(unknown, form: form).footRows == [14, 15])
            #expect(catalog.accessories(unknown, form: form).isEmpty)
        }
    }

    @Test func growingBodiesAreNewDrawingsAndAccessoriesAreCharacterSpecific() throws {
        let catalog = try PetCatalog.load(directory: contentDirectory)
        var accessoryIDs: Set<String> = []
        for pet in catalog.all {
            let oldRows = pet.sprite.rows.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            let newRows = pet.juvenile.rows.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            #expect(!newRows.dropLast(4).elementsEqual(oldRows))
            #expect(!pet.accessories.isEmpty)
            for accessory in pet.accessories { #expect(accessoryIDs.insert(accessory.id).inserted) }
        }
    }

    @Test(arguments: ["juvenile", "accessory"], ["size", "rows", "palette"])
    func growingSpritesValidateGridAndPalette(target: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try editFirstPet(box) { pet in
            func breakSprite(_ sprite: inout [String: Any]) {
                if failure == "size" { sprite["size"] = [16, 20] }
                else {
                    var rows = sprite["rows"] as! [String]
                    if failure == "rows" { rows.removeLast() }
                    else { rows[0] = "?" + rows[0].dropFirst() }
                    sprite["rows"] = rows
                }
            }
            if target == "juvenile" {
                var sprite = pet["juvenile"] as! [String: Any]
                breakSprite(&sprite)
                pet["juvenile"] = sprite
            } else {
                var accessories = pet["accessories"] as! [[String: Any]]
                var sprite = accessories[0]["sprite"] as! [String: Any]
                breakSprite(&sprite)
                accessories[0]["sprite"] = sprite
                pet["accessories"] = accessories
            }
        }
        let rule = failure == "size" ? "spriteSize" : failure == "rows" ? "spriteRows" : "spriteCharacter"
        #expect(ContentValidator.validatePets(directory: box.directory).contains { $0.rule == rule })
        #expect(throws: ContentValidationError.self) { try PetCatalog.load(directory: box.directory) }
    }

    @Test(arguments: ["hatchlingMotion", "juvenileMotion"], ["missing-end", "negative", "reversed", "outside", "transparent"])
    func walkingFeetRequireVisibleRowsInsideTheirBody(target: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try editFirstPet(box) { pet in
            var motion = pet[target] as! [String: Any]
            switch failure {
            case "missing-end": motion["footRows"] = [14]
            case "negative": motion["footRows"] = [-1, 1]
            case "reversed": motion["footRows"] = [15, 14]
            case "outside": motion["footRows"] = [19, 20]
            default: motion["footRows"] = [0, 0]
            }
            pet[target] = motion
        }
        #expect(ContentValidator.validatePets(directory: box.directory).contains { $0.rule == "spriteFootRows" })
    }

    @Test(arguments: ["hatchlingMotion", "juvenileMotion"], ["missing-coordinate", "negative", "outside", "overflow", "off-head"])
    func sleepingCapsStayInsideTheirBodyAndMeetItsHead(target: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try editFirstPet(box) { pet in
            var motion = pet[target] as! [String: Any]
            switch failure {
            case "missing-coordinate": motion["nightcapAnchor"] = [3]
            case "negative": motion["nightcapAnchor"] = [-1, 0]
            case "outside": motion["nightcapAnchor"] = [12, 0]
            case "overflow": motion["nightcapAnchor"] = [Int.max, Int.max]
            default: motion["nightcapAnchor"] = [3, 10]
            }
            pet[target] = motion
        }
        #expect(ContentValidator.validatePets(directory: box.directory).contains { $0.rule == "spriteNightcapAnchor" })
    }

    @Test(arguments: ["missing", "empty-id", "duplicate-id", "transparent"])
    func teenAccessoriesRequireUniqueIdsAndVisibleLayers(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try editFirstPet(box) { pet in
            var accessories = pet["accessories"] as! [[String: Any]]
            switch failure {
            case "missing": accessories = []
            case "empty-id": accessories[0]["id"] = " \n "
            case "duplicate-id": accessories.append(accessories[0])
            default: accessories[0]["sprite"] = ["size": [20, 20], "rows": Array(repeating: String(repeating: ".", count: 20), count: 20)]
            }
            pet["accessories"] = accessories
        }
        let rule = failure == "empty-id" || failure == "duplicate-id" ? "petAccessoryID" : "petAccessories"
        #expect(ContentValidator.validatePets(directory: box.directory).contains { $0.rule == rule })
    }

    private func editFirstPet(_ box: ContentSandbox, _ body: (inout [String: Any]) -> Void) throws {
        let file = try #require(PetCatalog.readPets(directory: box.directory).first?.file)
        try box.edit("pets/\(file.lastPathComponent)", body)
    }
}
