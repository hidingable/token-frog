import AppKit
import CoreText
import SwiftUI

enum Palette {
    static let ink: UInt32 = 0x1D1A39
    static let paper: UInt32 = 0xF7EBD0
    static let amber: UInt32 = 0xF4B63F
    static let red: UInt32 = 0xE5533D
    static let sea: UInt32 = 0x2B6C8F
    static let land: UInt32 = 0x3F7F5F
    static let mint: UInt32 = 0x7FD1C7
    static let dusk: UInt32 = 0x8E86B8
    static let rose: UInt32 = 0xEFA0A8
}

enum Theme {
    static let ink = Color(hex: Palette.ink)
    static let inkRaised = Color(hex: 0x2C2850)
    static let paper = Color(hex: Palette.paper)
    static let amber = Color(hex: Palette.amber)
    static let red = Color(hex: Palette.red)
    static let sea = Color(hex: Palette.sea)
    static let mint = Color(hex: Palette.mint)
    static let dusk = Color(hex: Palette.dusk)
    static let brown = Color(hex: 0x5E3B2A)
    static let blockOff = Color(hex: 0x3A3560)
    static let coral = Color(hex: 0xE8873A)
    static let rose = Color(hex: Palette.rose)
    /// Companion and habit text on the light letter paper.
    static let paperRose = Color(hex: 0xA8434F)
    /// Chart-only colors, checked against the ink surface. Tools keep their color across every filter.
    static let series = [Color(hex: 0x3987E5), Color(hex: 0xD95926), Color(hex: 0x199E70), Color(hex: 0xC98500)]
    static let seriesOther = Color(hex: 0x6B678F)
    /// Heat steps from no use to the busiest quarter of days.
    static let heat = [Color(hex: 0x2C2850), Color(hex: 0x4F4A80), Color(hex: 0x8E86B8), Color(hex: 0xC9C3DE), Color(hex: 0xF7EBD0)]

    static let pixelFontName = "Fusion-Pixel-12px-Prop-zh-Hans-Regular"

    /// The font is drawn on a 12 px grid, so only multiples of 12 stay crisp.
    static func pixel(_ size: CGFloat = 12) -> Font { .custom(pixelFontName, fixedSize: size) }

    static func registerFonts() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "otf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum PixelImage {
    /// `pixels` holds 0xRRGGBB values in reading order; nil is transparent.
    static func make(width: Int, height: Int, pixels: [UInt32?]) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, pixel) in pixels.enumerated() {
            guard let pixel else { continue }
            bytes[index * 4] = UInt8((pixel >> 16) & 0xFF)
            bytes[index * 4 + 1] = UInt8((pixel >> 8) & 0xFF)
            bytes[index * 4 + 2] = UInt8(pixel & 0xFF)
            bytes[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            preconditionFailure("Could not build a \(width)x\(height) pixel image")
        }
        return image
    }
}

struct PixelBorder: ViewModifier {
    var color: Color = Theme.ink
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content.overlay(Rectangle().strokeBorder(color, lineWidth: width))
    }
}

extension View {
    func pixelBorder(_ color: Color = Theme.ink, width: CGFloat = 2) -> some View {
        modifier(PixelBorder(color: color, width: width))
    }
}

struct BlockProgress: View {
    var progress: Double
    var blocks = 10
    var size: CGFloat = 6
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<blocks, id: \.self) { index in
                Rectangle()
                    .fill(Double(index) < progress * Double(blocks) ? Theme.amber : Theme.blockOff)
                    .frame(width: size, height: size)
            }
        }
    }
}
