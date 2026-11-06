import CoreGraphics
import VoyageCore

/// Level-one room() from the mockup, in top-to-bottom logical pixels.
enum RoomArt {
    static func image(pet: PetKind, shelf: [Item]) -> CGImage {
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
        rect(0x2C2850, 0, 0, width, height)
        for x in stride(from: 0, to: width, by: 16) { rect(0x262245, x, 0, 1, 96) }
        rect(0x5E3B2A, 0, 96, width, 36)
        for x in stride(from: 0, to: width, by: 20) { rect(0x4C2F22, x, 96, 1, 36) }
        for y in stride(from: 104, to: height, by: 9) { rect(0x4C2F22, 0, y, width, 1) }
        // Window, stars and mullion.
        rect(0x0F0D22, 16, 18, 44, 40)
        rect(0x5E3B2A, 14, 16, 48, 2); rect(0x5E3B2A, 14, 58, 48, 2)
        rect(0x5E3B2A, 14, 16, 2, 44); rect(0x5E3B2A, 60, 16, 2, 44)
        rect(0x5E3B2A, 37, 18, 2, 40)
        rect(Palette.paper, 24, 26, 1, 1); rect(Palette.paper, 50, 30, 1, 1)
        rect(Palette.paper, 44, 44, 1, 1); rect(Palette.amber, 52, 22, 3, 3)
        // Empty shelf slots stay empty; acquisition order comes from care.souvenirs.
        rect(0x5E3B2A, 78, 52, 78, 3)
        for (index, item) in shelf.prefix(CareRules.shelfCapacity).enumerated() {
            sprite(Sprites.itemPixels(item.icon), width: 12, x: 80 + index * 19, y: 40, scale: 1)
        }
        rect(0x8A5A3C, 0, 84, 92, 14)
        rect(0x5E3B2A, 0, 84, 92, 2); rect(0x5E3B2A, 0, 98, 92, 2)
        rect(0x3A3560, 4, 64, 26, 20)
        for x in 0..<3 {
            for y in 0..<2 { rect(0x1D1A39, 6 + x * 8, 66 + y * 9, 6, 7) }
        }
        rect(Palette.paper, 7, 68, 4, 4)
        rect(0x3F7F5F, 202, 52, 28, 44); rect(0x2B5C47, 204, 54, 24, 40)
        rect(Palette.amber, 224, 74, 2, 2); rect(Palette.red, 207, 44, 18, 6)
        rect(0x1D1A39, 100, 10, 8, 1); rect(0x1D1A39, 108, 12, 6, 1)
        rect(0x3A3560, 140, 18, 1, 20); rect(0x3A3560, 141, 28, 6, 1)
        sprite(Sprites.petPixels(pet), width: 16, x: 116, y: 76, scale: 2)
        return PixelImage.make(width: width, height: height, pixels: pixels)
    }
}
