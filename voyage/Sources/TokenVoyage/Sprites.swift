import AppKit
import SwiftUI
import VoyageCore

enum Sprites {
    enum Frame: Hashable, CaseIterable { case rest, bob, stepLeft, stepRight }

    private static let colors: [Character: UInt32] = [
        "k": Palette.ink, "w": Palette.paper, "g": Palette.dusk, "l": 0xC9C3DE, "r": Palette.red,
        "y": Palette.amber, "o": 0xC9852B, "b": Palette.sea, "c": Palette.mint, "n": 0x8A5A3C,
        "d": 0x5E3B2A, "p": 0xEFA0A8,
    ]

    private static let art: [PetKind: [String]] = [
        .pigeon: [
            "................", "......kkkkk.....", ".....krrrrrk....", "....krrrrrrrk...",
            "....kkkkkkkkkk..", "....klllllllk...", "....kllkklllkyy.", "....klllllllkkk.",
            "..kkkwwwlllk....", ".kgggkwwwwllk...", ".kgggggwnnnnlk..", "..kggggwnyynlk..",
            "...kgggwnnnnlk..", "....kkkkkkkkk...", ".....ky...ky....", "....kyy..kyy....",
        ],
        .snail: [
            "................", ".............k..", "...........k.k..", "...........k.k..",
            "....kkkkk..kkkk.", "...kyyyyyk.kccck", "..kyyoooyykkckck", "..kyoyyyoykkccck",
            "..kyoyoyoykkccck", "..kyoyooyykkcck.", "..kyyoyyyykkcck.", "...kyyyyyk.kcck.",
            "..kkkkkkkkkkcck.", ".kccccccccccck..", "kcccccccccccck..", ".kkkkkkkkkkkk...",
        ],
        .suitcase: [
            "................", "......kkkk......", ".....kyyyyk.....", ".....ky..yk.....",
            "..kkkkkkkkkkkk..", ".knnnnnnnnnnnnk.", ".kndddddddddnnk.", ".knnnnnnnnnnnnk.",
            ".knnkknnnnkknnk.", ".knnkknnnnkknnk.", ".knnnnnnnnnnnnk.", ".knnnrrnnwwwnnk.",
            ".knnnrrnnwbwnnk.", ".kddddddddddddk.", "..kkkkkkkkkkkk..", "...ky......ky...",
        ],
        .letter: [
            "................", "................", ".kkkkkkkkkkkkkk.", ".kwkwwwwwwwwkwk.",
            ".kwwkwwwwwwkwwk.", ".kwwwkwwwwkwwwk.", ".kwwwwkrrkwwwwk.", ".kwwwwwrrwwwwwk.",
            ".kwwwwwwwwwwwwk.", ".kwwkkwwwwkkwwk.", ".kwwkkwwwwkkwwk.", ".kwpwwwkkwwwpwk.",
            ".kwwwwwwwwwwwwk.", ".kkkkkkkkkkkkkk.", "...kr......kr...", "...krr.....krr..",
        ],
    ]

    @MainActor private static var cache: [String: CGImage] = [:]

    /// eggA and the three exact recolorings from the first-launch mockup.
    static let eggRows = [
        "................", "................", "......kkkk......", ".....kwwwwk.....",
        "....kwwwwwwk....", "....kwwlwwwk....", "...kwwllwwwwk...", "...kwwwwwwlwk...",
        "...kwwwwwwwwk...", "...kwlwwwwwwk...", "...kwwwwwllwk...", "....kwwwwwwk....",
        "....kwwwwwwk....", ".....kkkkkk.....", "................", "................",
    ]

    static func egg(_ pet: PetKind, cracked: Bool = false) -> CGImage {
        let recolor: [Character: Character]
        switch pet {
        case .pigeon: recolor = [:]
        case .snail: recolor = ["w": "y", "l": "o"]
        case .suitcase: recolor = ["w": "n", "l": "d"]
        case .letter: recolor = ["w": "w", "l": "r"]
        }
        var pixels: [UInt32?] = eggRows.flatMap { row in row.map { colors[recolor[$0] ?? $0] } }
        if cracked {
            for (x, y) in [(7, 4), (8, 5), (7, 6), (8, 7), (7, 8), (8, 9)] { pixels[y * 16 + x] = Palette.ink }
        }
        return PixelImage.make(width: 16, height: 16, pixels: pixels)
    }

    /// Frames are 16x17: one spare row lets the body bob without clipping.
    @MainActor static func image(_ pet: PetKind, _ frame: Frame) -> CGImage {
        let key = "\(pet.rawValue)-\(frame)"
        if let cached = cache[key] { return cached }
        guard let rows = art[pet] else { preconditionFailure("Missing art for \(pet)") }
        var pixels = [UInt32?](repeating: nil, count: 16 * 17)
        for (y, row) in rows.enumerated() {
            let isFoot = y >= 14
            let lift = !isFoot && (frame == .bob || frame == .stepLeft || frame == .stepRight) ? 0 : 1
            let shift = isFoot ? (frame == .stepLeft ? -1 : frame == .stepRight ? 1 : 0) : 0
            for (x, symbol) in row.enumerated() where symbol != "." {
                let targetX = x + shift
                let targetY = y + lift
                guard (0..<16).contains(targetX), (0..<17).contains(targetY) else { continue }
                pixels[targetY * 16 + targetX] = colors[symbol]
            }
        }
        let image = PixelImage.make(width: 16, height: 17, pixels: pixels)
        cache[key] = image
        return image
    }
}

final class PixelArtNSView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }
}

struct PixelArtView: NSViewRepresentable {
    var image: CGImage
    var scale: Int

    func makeNSView(context: Context) -> PixelArtNSView { PixelArtNSView() }

    func updateNSView(_ view: PixelArtNSView, context: Context) { view.image = image }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PixelArtNSView, context: Context) -> CGSize? {
        CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Draws the sprite directly in AppKit. A SwiftUI TimelineView cost about 12% of a core to animate these few pixels.
final class SpriteNSView: NSView {
    private var frameIndex = 0
    private var timer: Timer?

    var pet: PetKind = .pigeon {
        didSet { if pet != oldValue { needsDisplay = true } }
    }

    var moving = false {
        didSet { if moving != oldValue { restartTimer() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: moving ? 0.4 : 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameIndex &+= 1
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let even = frameIndex % 2 == 0
        let frame: Sprites.Frame = moving ? (even ? .stepLeft : .stepRight) : (even ? .rest : .bob)
        context.interpolationQuality = .none
        context.draw(Sprites.image(pet, frame), in: bounds)
    }
}

struct SpriteView: NSViewRepresentable {
    var pet: PetKind
    var scale: CGFloat
    var moving = false

    func makeNSView(context: Context) -> SpriteNSView { SpriteNSView() }

    func updateNSView(_ view: SpriteNSView, context: Context) {
        view.pet = pet
        view.moving = moving
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpriteNSView, context: Context) -> CGSize? {
        CGSize(width: 16 * scale, height: 17 * scale)
    }
}
