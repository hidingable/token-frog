import Foundation

extension ContentValidator {
    static func validatePets(directory: URL) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        func complete(_ texts: [String: String]) -> Bool {
            ["zh-Hans", "en"].allSatisfy {
                !(texts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        var symbols: Set<Character>?
        do {
            let palette = try PetCatalog.readPalette(directory: directory)
            symbols = Set(palette.keys.filter { $0.count == 1 }.compactMap(\.first))
            if !palette.keys.contains(".") {
                report("sprites/palette.json", "spritePalette", "The palette requires a transparent '.' entry")
            }
            for (symbol, color) in palette {
                if symbol.count != 1 {
                    report("sprites/palette.json", "spritePalette", "Palette keys must contain one character: \(symbol)")
                }
                if symbol == "." {
                    if color != nil { report("sprites/palette.json", "spritePalette", "The '.' palette entry must be null") }
                } else if color?.count != 7 || color?.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil {
                    report("sprites/palette.json", "spritePalette", "Palette colors must be nonnull #RRGGBB values: \(symbol)")
                }
            }
        } catch { report("sprites/palette.json", "spritePalette", "Cannot read the palette: \(error)") }

        func validateSprite(_ sprite: PixelSprite, dimension: Int, file: String, name: String) {
            if sprite.size != [dimension, dimension] {
                report(file, "spriteSize", "\(name) must declare a \(dimension)x\(dimension) size")
            }
            if sprite.rows.count != dimension || sprite.rows.contains(where: { $0.count != dimension }) {
                report(file, "spriteRows", "\(name) must contain \(dimension) rows of \(dimension) characters")
            }
            if let symbols, sprite.rows.contains(where: { !Set($0).isSubset(of: symbols) }) {
                report(file, "spriteCharacter", "\(name) contains a character absent from the palette")
            }
        }

        func validateMotion(_ motion: SpriteMotion, sprite: PixelSprite, dimension: Int, file: String, name: String) {
            let rows = sprite.rows.map(Array.init)
            let feet = motion.footRows
            if feet.count != 2 || feet[0] < 0 || feet[1] < feet[0] || feet[1] >= dimension {
                report(file, "spriteFootRows", "\(name) footRows requires two ordered inclusive row endpoints inside its body")
            } else if (feet[0]...feet[1]).contains(where: { row in
                row >= rows.count || !rows[row].contains(where: { $0 != "." })
            }) {
                report(file, "spriteFootRows", "\(name) footRows must contain visible foot pixels on every declared row")
            }
            let anchor = motion.nightcapAnchor
            let capWidth = dimension == 16 ? 12 : 10
            guard anchor.count == 2, anchor[0] >= 0, anchor[1] >= 0,
                  anchor[0] <= dimension - capWidth, anchor[1] <= dimension - 4 else {
                report(file, "spriteNightcapAnchor", "\(name) nightcapAnchor must keep its \(capWidth)x4 cap inside the body grid")
                return
            }
            let headTop = rows.indices.first { row in
                rows[row].indices.contains { column in
                    (anchor[0]..<anchor[0] + capWidth).contains(column) && rows[row][column] != "."
                }
            }
            // The brim may cover an existing hat, handle or antennae, but must meet the head.
            guard let headTop, (-3...1).contains(headTop - (anchor[1] + 3)) else {
                report(file, "spriteNightcapAnchor", "\(name) nightcap brim must sit at the body's head or existing headwear")
                return
            }
        }

        do {
            let eggs = try PetCatalog.readEggs(directory: directory)
            for (name, sprite) in [("base", eggs.base), ("cracked", eggs.cracked), ("placeholder", eggs.placeholder)] {
                validateSprite(sprite, dimension: 16, file: "sprites/eggs.json", name: name)
            }
        } catch { report("sprites/eggs.json", "spriteEggs", "Cannot read egg and placeholder sprites: \(error)") }

        do {
            let icons = try PetCatalog.readIcons(directory: directory)
            if icons.isEmpty { report("sprites/icons.json", "spriteIcons", "At least one item icon is required") }
            for name in icons.keys.sorted() {
                validateSprite(icons[name]!, dimension: 12, file: "sprites/icons.json", name: name)
            }
        } catch { report("sprites/icons.json", "spriteIcons", "Cannot read item icon sprites: \(error)") }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("pets"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            report("pets", "petJSON", "Cannot read pets: \(error)")
            return issues
        }
        if files.isEmpty { report("pets", "petCount", "At least one pet is required") }
        var ids: Set<PetID> = []
        var orders: Set<Int> = []
        for file in files {
            let path = "pets/\(file.lastPathComponent)"
            let pet: PetDefinition
            do { pet = try JSONDecoder().decode(PetDefinition.self, from: Data(contentsOf: file)) }
            catch { report(path, "petJSON", "Cannot decode pet: \(error)"); continue }
            if pet.id.rawValue.isEmpty || !ids.insert(pet.id).inserted {
                report(path, "petID", "Pet IDs must be nonempty and unique")
            }
            if pet.id.rawValue != file.deletingPathExtension().lastPathComponent {
                report(path, "petFilename", "Filename must equal the pet ID")
            }
            if !orders.insert(pet.order).inserted { report(path, "petOrder", "Pet display orders must be unique") }
            if !complete(pet.names) || !complete(pet.eggNames) || !pet.quirks.allSatisfy(complete) {
                report(path, "petTranslation", "Pet names, egg names and quirks require nonempty zh-Hans and en")
            }
            if pet.names.values.contains(where: { $0.count > 12 }) {
                report(path, "petNameLength", "Default pet names must be at most 12 characters")
            }
            if pet.quirks.count < 3 { report(path, "petQuirks", "Every pet requires at least three quirks") }
            validateSprite(pet.sprite, dimension: 16, file: path, name: "\(pet.id.rawValue) hatchling")
            validateSprite(pet.juvenile, dimension: 20, file: path, name: "\(pet.id.rawValue) juvenile")
            validateMotion(pet.hatchlingMotion, sprite: pet.sprite, dimension: 16, file: path, name: "hatchling")
            validateMotion(pet.juvenileMotion, sprite: pet.juvenile, dimension: 20, file: path, name: "juvenile")
            var accessoryIDs: Set<String> = []
            if pet.accessories.isEmpty {
                report(path, "petAccessories", "Every pet requires a visible teen accessory layer")
            }
            for accessory in pet.accessories {
                if accessory.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !accessoryIDs.insert(accessory.id).inserted {
                    report(path, "petAccessoryID", "Accessory IDs must be nonempty and unique within a pet")
                }
                validateSprite(accessory.sprite, dimension: 20, file: path, name: "accessory \(accessory.id)")
                if !accessory.sprite.rows.contains(where: { $0.contains(where: { $0 != "." }) }) {
                    report(path, "petAccessories", "Accessory \(accessory.id) must contain visible pixels")
                }
            }
            for (source, target) in pet.egg.recolor {
                if source.count != 1 || target.count != 1
                    || symbols.map({ !Set(source + target).isSubset(of: $0) }) == true {
                    report(path, "petRecolor", "Egg recoloring must map single palette characters to palette characters")
                }
            }
        }
        return issues
    }
}
