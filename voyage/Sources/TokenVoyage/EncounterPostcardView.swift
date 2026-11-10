import SwiftUI
import VoyageCore

@MainActor
enum EncounterPostcardArt {
    static let width = 96
    static let height = 48
    private static let land = WorldMapData.rows.map { Array($0.utf8) }

    /// A small map crop around the saved city uses the same sea/land colors as the journey map.
    static func image(_ encounter: EncounterPhoto, catalog: CityCatalog, theme: AppTheme) -> CGImage {
        let city = catalog.city(encounter.cityId)
        let centerX = Int((city.lon + 180) / 360 * Double(WorldMapData.width))
        let centerY = Int((WorldMapData.latTop - city.lat) / (WorldMapData.latTop - WorldMapData.latBottom)
                          * Double(WorldMapData.height))
        var pixels: [UInt32?] = (0..<height).flatMap { y in
            (0..<width).map { x in
                let sourceX = (centerX + (x - width / 2) / 4 + WorldMapData.width) % WorldMapData.width
                let sourceY = min(max(centerY + (y - height / 2) / 4, 0), WorldMapData.height - 1)
                return land[sourceY][sourceX] == 35 ? theme.rgb(.mapLand) : theme.rgb(.mapSea)
            }
        }
        place(encounter.own, centerX: 31, catalog: catalog.pets, silhouette: theme.rgb(.mapMarker), pixels: &pixels)
        place(encounter.partner, centerX: 65, catalog: catalog.pets, silhouette: theme.rgb(.mapMarker), pixels: &pixels)
        return PixelImage.make(width: width, height: height, pixels: pixels)
    }

    private static func place(_ appearance: EncounterAppearance, centerX: Int, catalog: PetCatalog,
                              silhouette: UInt32, pixels: inout [UInt32?]) {
        let pet = PetID(rawValue: appearance.species)
        let form = PetForm(rawValue: appearance.stage) ?? .hatchling
        let sprite: [UInt32?]
        let spriteWidth: Int
        let spriteHeight: Int
        if catalog.find(pet) != nil {
            let image = Sprites.image(pet, .rest, catalog: catalog, form: form)
            spriteWidth = image.width
            spriteHeight = image.height
            let bytes = image.dataProvider!.data! as Data
            sprite = (0..<(spriteWidth * spriteHeight)).map { index in
                let offset = index * 4
                guard bytes[offset + 3] > 0 else { return nil }
                return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
            }
        } else {
            // No species guess: a neutral messenger silhouette remains valid for future content packs.
            let rows = ["......####......", ".....######.....", "....########....", "....########....",
                        ".....######.....", "......####......", ".....######.....", "....########....",
                        "...##########...", "...##########...", "....########....", "....########....",
                        ".....######.....", ".....##..##.....", "....###..###....", "................"]
            spriteWidth = 16
            spriteHeight = rows.count
            sprite = rows.flatMap { $0.map { $0 == "#" ? silhouette : nil } }
        }
        let left = centerX - spriteWidth / 2
        let top = 39 - spriteHeight
        for (index, color) in sprite.enumerated() {
            if let color { pixels[(top + index / spriteWidth) * width + left + index % spriteWidth] = color }
        }
    }
}

struct EncounterPostcardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let encounter: EncounterPhoto
    let catalog: CityCatalog

    var body: some View {
        Image(decorative: EncounterPostcardArt.image(encounter, catalog: catalog, theme: theme), scale: 1)
            .interpolation(.none).resizable().aspectRatio(2, contentMode: .fit)
            .frame(maxWidth: 480).pixelBorder(theme.paperBorder)
            .accessibilityLabel(l10n("encounter.photoAccessibility", l10n.cityName(catalog.city(encounter.cityId))))
    }
}
