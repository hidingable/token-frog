import CoreGraphics
import VoyageCore

/// Level-one room() from the mockup, in top-to-bottom logical pixels.
@MainActor
enum RoomArt {
    private struct Key: Equatable {
        let pet: PetID
        let form: PetForm
        let placements: [String]
        let nightcap: Bool
        let icons: [String]
        let catalog: PetCatalog
        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.pet == rhs.pet && lhs.form == rhs.form && lhs.placements == rhs.placements && lhs.nightcap == rhs.nightcap && lhs.icons == rhs.icons && lhs.catalog === rhs.catalog
        }
    }
    private static var cache: [String: (key: Key, image: CGImage)] = [:]

    static func image(pet: PetID, shelf: [Item], theme: AppTheme, catalog: PetCatalog, form: PetForm = .hatchling, placements: [RoomSlot: Item] = [:], nightcap: Bool = false) -> CGImage {
        let key = Key(pet: pet, form: form, placements: RoomSlot.allCases.map { placements[$0]?.icon ?? "" }, nightcap: nightcap, icons: shelf.prefix(CareRules.shelfCapacity).map(\.icon), catalog: catalog)
        if let cached = cache[theme.id], cached.key == key { return cached.image }
        let width = RoomLayout.width
        let height = RoomLayout.height
        var pixels = [UInt32?](repeating: nil, count: width * height)
        func rect(_ color: UInt32, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for row in y..<(y + h) {
                for column in x..<(x + w) { pixels[row * width + column] = color }
            }
        }
        func sprite(_ source: [UInt32?], width: Int, x: Int, y: Int, scale: Int) {
            for (index, color) in source.enumerated() {
                if let color { rect(color, x + index % width * scale, y + index / width * scale, scale, scale) }
            }
        }
        rect(theme.rgb(.roomWall), 0, 0, width, height)
        for x in stride(from: 0, to: width, by: 16) { rect(theme.rgb(.roomWallLine), x, 0, 1, 96) }
        rect(theme.rgb(.roomFloor), 0, 96, width, 36)
        for x in stride(from: 0, to: width, by: 20) { rect(theme.rgb(.roomFloorLine), x, 96, 1, 36) }
        for y in stride(from: 104, to: height, by: 9) { rect(theme.rgb(.roomFloorLine), 0, y, width, 1) }
        // Window, stars and mullion.
        rect(theme.rgb(.roomWindowBack), 16, 18, 44, 40)
        rect(theme.rgb(.roomWindowFrame), 14, 16, 48, 2); rect(theme.rgb(.roomWindowFrame), 14, 58, 48, 2)
        rect(theme.rgb(.roomWindowFrame), 14, 16, 2, 44); rect(theme.rgb(.roomWindowFrame), 60, 16, 2, 44)
        rect(theme.rgb(.roomWindowFrame), 37, 18, 2, 40)
        rect(theme.rgb(.roomStar), 24, 26, 1, 1); rect(theme.rgb(.roomStar), 50, 30, 1, 1)
        rect(theme.rgb(.roomStar), 44, 44, 1, 1); rect(theme.rgb(.roomLight), 52, 22, 3, 3)
        // Empty shelf slots stay empty; acquisition order comes from care.souvenirs.
        rect(theme.rgb(.roomWoodDark), 78, 52, 78, 3)
        for (index, item) in shelf.prefix(CareRules.shelfCapacity).enumerated() {
            sprite(Sprites.itemPixels(item.icon, catalog: catalog), width: 12, x: 80 + index * 19, y: 40, scale: 1)
        }
        rect(theme.rgb(.roomWood), 0, 84, 92, 14)
        rect(theme.rgb(.roomWoodDark), 0, 84, 92, 2); rect(theme.rgb(.roomWoodDark), 0, 98, 92, 2)
        rect(theme.rgb(.roomCabinet), 4, 64, 26, 20)
        for x in 0..<3 {
            for y in 0..<2 { rect(theme.rgb(.roomShadow), 6 + x * 8, 66 + y * 9, 6, 7) }
        }
        rect(theme.rgb(.roomPaper), 7, 68, 4, 4)
        rect(theme.rgb(.roomDoor), 202, 52, 28, 44); rect(theme.rgb(.roomDoorDark), 204, 54, 24, 40)
        rect(theme.rgb(.roomLight), 224, 74, 2, 2); rect(theme.rgb(.roomMail), 207, 44, 18, 6)
        rect(theme.rgb(.roomShadow), 100, 10, 8, 1); rect(theme.rgb(.roomShadow), 108, 12, 6, 1)
        rect(theme.rgb(.roomCabinet), 140, 18, 1, 20); rect(theme.rgb(.roomCabinet), 141, 28, 6, 1)
        // A ledge below the glass and the cabinet top keep souvenirs clear of the window itself.
        if form == .teen { rect(theme.rgb(.roomWoodDark), 44, 73, 16, 2) }
        for slot in RoomSlot.allCases {
            if let item = placements[slot] {
                let bounds = RoomLayout.slotBounds(slot)
                sprite(Sprites.itemPixels(item.icon, catalog: catalog), width: 12,
                       x: Int(bounds.minX), y: Int(bounds.minY), scale: 1)
            }
        }
        let bounds = RoomLayout.petBounds(form: form)
        sprite(Sprites.petPixels(pet, catalog: catalog, form: form, nightcap: nightcap),
               width: catalog.sprite(pet, form: form).size[0], x: Int(bounds.minX), y: Int(bounds.minY), scale: 2)
        let image = PixelImage.make(width: width, height: height, pixels: pixels)
        cache[theme.id] = (key, image)
        return image
    }
}
