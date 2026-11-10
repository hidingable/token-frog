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
        let petIsHome: Bool
        let icons: [String]
        let catalog: PetCatalog
        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.pet == rhs.pet && lhs.form == rhs.form && lhs.placements == rhs.placements && lhs.nightcap == rhs.nightcap && lhs.petIsHome == rhs.petIsHome && lhs.icons == rhs.icons && lhs.catalog === rhs.catalog
        }
    }
    private static var cache: [String: (key: Key, image: CGImage)] = [:]

    static func image(pet: PetID, shelf: [Item], theme: AppTheme, catalog: PetCatalog, form: PetForm = .hatchling, placements: [RoomSlot: Item] = [:], nightcap: Bool = false, petIsHome: Bool = true) -> CGImage {
        let key = Key(pet: pet, form: form, placements: RoomSlot.allCases.map { placements[$0]?.icon ?? "" }, nightcap: nightcap, petIsHome: petIsHome, icons: shelf.prefix(CareRules.shelfCapacity).map(\.icon), catalog: catalog)
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
        if !petIsHome {
            // A note on the ajar door is the mockup's away state.
            rect(theme.rgb(.roomWindowBack), 204, 54, 7, 40)
            rect(theme.rgb(.roomPaper), 214, 64, 9, 8)
            rect(theme.rgb(.roomMail), 216, 66, 5, 1)
            rect(theme.rgb(.roomWoodDark), 216, 68, 5, 1)
            rect(theme.rgb(.roomWoodDark), 216, 70, 3, 1)
        }
        if petIsHome {
            let bounds = RoomLayout.petBounds(form: form)
            sprite(Sprites.petPixels(pet, catalog: catalog, form: form, nightcap: nightcap),
                   width: catalog.sprite(pet, form: form).size[0], x: Int(bounds.minX), y: Int(bounds.minY), scale: 2)
        }
        let image = PixelImage.make(width: width, height: height, pixels: pixels)
        cache[theme.id] = (key, image)
        return image
    }

    private struct FloorKey: Equatable {
        let rows: Int
        let parcels: Int
        let footprints: Int
        let colors: [Int]
        let looseBoard: Bool
        let crate: HomeFloorDisplay.Crate
    }
    private static var floorCache: [String: (key: FloorKey, catalog: PetCatalog, image: CGImage)] = [:]

    /// Transparent over the original room, then continues its planks below y=132.
    static func floor(display: HomeFloorDisplay, rows: Int, theme: AppTheme, catalog: PetCatalog) -> CGImage {
        let key = FloorKey(rows: rows, parcels: display.parcels.count, footprints: display.footprintLevel,
                           colors: display.patches.map(\.colorIndex), looseBoard: display.looseBoard != nil, crate: display.crate)
        if let cached = floorCache[theme.id], cached.key == key, cached.catalog === catalog { return cached.image }
        let width = RoomLayout.width
        var pixels = [UInt32?](repeating: nil, count: width * rows)
        func rect(_ color: UInt32, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for row in max(y, 0)..<min(y + h, rows) {
                for column in max(x, 0)..<min(x + w, width) { pixels[row * width + column] = color }
            }
        }
        func fill(_ color: UInt32, _ bounds: CGRect) {
            rect(color, Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height))
        }
        rect(theme.rgb(.roomFloor), 0, RoomLayout.height, width, max(0, rows - RoomLayout.height))
        for x in stride(from: 0, to: width, by: 20) {
            rect(theme.rgb(.roomFloorLine), x, RoomLayout.height, 1, max(0, rows - RoomLayout.height))
        }
        for y in stride(from: 140, to: rows, by: 9) { rect(theme.rgb(.roomFloorLine), 0, y, width, 1) }
        // Door-to-pet trail stays above the rug and clear of the parcel hit areas.
        if display.footprintLevel > 0 {
            let count = [0, 2, 4, 6][display.footprintLevel]
            for index in 0..<count {
                rect(theme.rgb(.roomShadow), 198 - index * 8, 116 + index % 2 * 3, 3, 2)
            }
        }
        let rug = RoomLayout.rug
        fill(theme.rgb(.paperCompanionText), rug)
        rect(catalog.palette["y"]!, Int(rug.minX), Int(rug.minY) + 2, Int(rug.width), 1)
        rect(catalog.palette["y"]!, Int(rug.minX), Int(rug.maxY) - 3, Int(rug.width), 1)
        // Muted textile colors keep the same city identity in both room themes.
        let palette = ["c", "w", "b", "g", "o"].map { catalog.palette[Character($0)]! }
        for (index, patch) in display.patches.enumerated() { fill(palette[patch.colorIndex], RoomLayout.rugPatch(index)) }
        for index in display.parcels.indices {
            let bounds = RoomLayout.parcel(index)
            for (pixel, color) in Sprites.itemPixels("box", catalog: catalog).enumerated() {
                if let color { rect(color, Int(bounds.minX) + pixel % 12, Int(bounds.minY) + pixel / 12, 1, 1) }
            }
        }
        let crate = RoomLayout.crate
        fill(theme.rgb(.roomWood), crate)
        let x = Int(crate.minX), y = Int(crate.minY)
        rect(theme.rgb(.roomWoodDark), x, y, 24, 2)
        rect(theme.rgb(.roomWoodDark), x, y + 18, 24, 2)
        rect(theme.rgb(.roomWoodDark), x + 7, y, 2, 20)
        rect(theme.rgb(.roomWoodDark), x + 16, y, 2, 20)
        switch display.crate {
        case .nailed:
            for i in 0..<16 { rect(theme.rgb(.roomPaper), x + 4 + i, y + 2 + i, 2, 2) }
            rect(theme.rgb(.roomShadow), x + 5, y + 4, 1, 1)
            rect(theme.rgb(.roomShadow), x + 18, y + 16, 1, 1)
        case .ready:
            rect(theme.rgb(.roomLight), x + 10, y + 7, 4, 5)
        case .opened:
            rect(theme.rgb(.roomShadow), x + 2, y + 2, 20, 8)
            rect(theme.rgb(.roomWood), x - 2, y - 4, 24, 3)
        }
        if display.looseBoard != nil {
            let board = RoomLayout.looseBoard
            fill(theme.rgb(.roomShadow), board.offsetBy(dx: 1, dy: 2))
            fill(theme.rgb(.roomWood), board)
            let bx = Int(board.minX), by = Int(board.minY)
            rect(theme.rgb(.roomLight), bx, by, 24, 1)
            rect(theme.rgb(.roomWoodDark), bx + 2, by + 6, 18, 1)
            rect(theme.rgb(.roomLight), bx + 23, by, 1, 12)
        }
        let image = PixelImage.make(width: width, height: rows, pixels: pixels)
        floorCache[theme.id] = (key, catalog, image)
        return image
    }
}
