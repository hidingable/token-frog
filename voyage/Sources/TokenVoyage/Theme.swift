import AppKit
import CoreText
import SwiftUI
import VoyageCore

enum Theme {
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

/// A validated theme, or system colors used only by the damaged-content recovery screen.
struct AppTheme: Equatable, Sendable {
    let definition: ThemeDefinition?
    let scheme: ThemeScheme
    var id: String { definition?.id ?? "content-recovery" }

    init(_ definition: ThemeDefinition) { self.definition = definition; scheme = definition.scheme }
    init(recoveryScheme: ThemeScheme) { definition = nil; scheme = recoveryScheme }

    func rgb(_ token: ThemeToken) -> UInt32 { definition!.color(token) }
    private func color(_ token: ThemeToken) -> Color {
        if let definition { return Color(hex: definition.color(token)) }
        switch token {
        case .background, .surface: return Color(nsColor: .windowBackgroundColor)
        case .surfaceRaised: return Color(nsColor: .controlBackgroundColor)
        case .text: return Color(nsColor: .labelColor)
        case .textMuted: return Color(nsColor: .secondaryLabelColor)
        default: return Color(nsColor: .separatorColor)
        }
    }
    var actionFill: Color { color(.actionFill) }
    var actionText: Color { color(.actionText) }
    var background: Color { color(.background) }
    var surface: Color { color(.surface) }
    var surfaceRaised: Color { color(.surfaceRaised) }
    var border: Color { color(.border) }
    var borderMuted: Color { color(.borderMuted) }
    var text: Color { color(.text) }
    var textMuted: Color { color(.textMuted) }
    var selectedFill: Color { color(.selectedFill) }
    var selectedText: Color { color(.selectedText) }
    var controlOff: Color { color(.controlOff) }
    var paper: Color { color(.paper) }
    var paperText: Color { color(.paperText) }
    var paperMuted: Color { color(.paperMuted) }
    var paperRule: Color { color(.paperRule) }
    var paperBorder: Color { color(.paperBorder) }
    var paperLink: Color { color(.paperLink) }
    var paperCompanionText: Color { color(.paperCompanionText) }
    var mileageFill: Color { color(.mileageFill) }
    var mileageText: Color { color(.mileageText) }
    var newMailFill: Color { color(.newMailFill) }
    var newMailText: Color { color(.newMailText) }
    var onNewMail: Color { color(.onNewMail) }
    var newPlaceFill: Color { color(.newPlaceFill) }
    var newPlaceText: Color { color(.newPlaceText) }
    var onNewPlace: Color { color(.onNewPlace) }
    var companionFill: Color { color(.companionFill) }
    var companionOnFill: Color { color(.companionOnFill) }
    var companionText: Color { color(.companionText) }
    var onCompanion: Color { color(.onCompanion) }
    var quotaLowText: Color { color(.quotaLowText) }
    var quotaLowFill: Color { color(.quotaLowFill) }
    var quotaFill: Color { color(.quotaFill) }
    var mapSea: Color { color(.mapSea) }
    var mapLand: Color { color(.mapLand) }
    var mapBorder: Color { color(.mapBorder) }
    var mapRoute: Color { color(.mapRoute) }
    var mapMarker: Color { color(.mapMarker) }
    var mapPosition: Color { color(.mapPosition) }
    var mapDestination: Color { color(.mapDestination) }
    var roomWall: Color { color(.roomWall) }
    var roomWallLine: Color { color(.roomWallLine) }
    var roomFloor: Color { color(.roomFloor) }
    var roomFloorLine: Color { color(.roomFloorLine) }
    var roomWood: Color { color(.roomWood) }
    var roomWoodDark: Color { color(.roomWoodDark) }
    var roomWindowBack: Color { color(.roomWindowBack) }
    var roomWindowFrame: Color { color(.roomWindowFrame) }
    var roomStar: Color { color(.roomStar) }
    var roomDoor: Color { color(.roomDoor) }
    var roomDoorDark: Color { color(.roomDoorDark) }
    var roomCabinet: Color { color(.roomCabinet) }
    var roomShadow: Color { color(.roomShadow) }
    var roomLight: Color { color(.roomLight) }
    var roomMail: Color { color(.roomMail) }
    var roomPaper: Color { color(.roomPaper) }
    var notchBackground: Color { color(.notchBackground) }
    var notchText: Color { color(.notchText) }
    var notchTextMuted: Color { color(.notchTextMuted) }
    var notchMileageText: Color { color(.notchMileageText) }
    var notchControlOff: Color { color(.notchControlOff) }
    var seriesOther: Color { color(.seriesOther) }
    var series: [Color] { definition!.series.map { Color(hex: $0) } }
    var heat: [Color] { definition!.heat.map { Color(hex: $0) } }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(recoveryScheme: .light)
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
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
    @Environment(\.theme) private var theme
    var color: Color? = nil
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content.overlay(Rectangle().strokeBorder(color ?? theme.paperBorder, lineWidth: width))
    }
}

extension View {
    func pixelBorder(_ color: Color? = nil, width: CGFloat = 2) -> some View {
        modifier(PixelBorder(color: color, width: width))
    }
}

struct BlockProgress: View {
    @Environment(\.theme) private var theme
    var progress: Double
    var blocks = 10
    var size: CGFloat = 6
    var inactiveColor: Color?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<blocks, id: \.self) { index in
                Rectangle()
                    .fill(Double(index) < progress * Double(blocks) ? theme.mileageFill : (inactiveColor ?? theme.controlOff))
                    .frame(width: size, height: size)
            }
        }
    }
}
