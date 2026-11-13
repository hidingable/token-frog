import AppKit
import SwiftUI
import VoyageCore

enum Sprites {
    enum Frame: Hashable, CaseIterable { case rest, bob, stepLeft, stepRight }

    static func petPixels(_ pet: PetID, catalog: PetCatalog, form: PetForm = .hatchling, nightcap: Bool = false) -> [UInt32?] {
        var result = pixels(catalog.sprite(pet, form: form), catalog: catalog)
        for accessory in catalog.accessories(pet, form: form) {
            for (index, color) in pixels(accessory.sprite, catalog: catalog).enumerated() {
                if let color { result[index] = color }
            }
        }
        if nightcap { addNightcap(to: &result, width: catalog.sprite(pet, form: form).size[0],
                                  anchor: catalog.motion(pet, form: form).nightcapAnchor, catalog: catalog) }
        return result
    }
    /// A temporary overlay in the render buffer, positioned by each body's declared head anchor.
    private static func addNightcap(to pixels: inout [UInt32?], width: Int, anchor: [Int], catalog: PetCatalog, offset: Int = 0) {
        let rows = width == 16
            ? ["...ggggll...", "..gggggll...", ".gggggggll..", "llllllllllww"]
            : ["...ggggll.", "..gggggll.", ".gggggggll", "llllllllww"]
        for (y, row) in rows.enumerated() {
            for (x, symbol) in row.enumerated() where symbol != "." {
                pixels[(y + anchor[1] + offset) * width + x + anchor[0]] = catalog.palette[symbol]
            }
        }
    }
    static func itemPixels(_ icon: String, catalog: PetCatalog) -> [UInt32?] {
        pixels(catalog.icons[icon]!, catalog: catalog)
    }
    private static func pixels(_ sprite: PixelSprite, catalog: PetCatalog, recolor: [String: String] = [:]) -> [UInt32?] {
        sprite.rows.flatMap { row in row.map { symbol in
            catalog.palette[(recolor[String(symbol)] ?? String(symbol)).first!]
        } }
    }
    static func friend(_ friend: FriendContent.Entry, catalog: PetCatalog) -> CGImage {
        PixelImage.make(width: 16, height: 16, pixels: pixels(friend.sprite, catalog: catalog))
    }
    static func item(_ icon: String, catalog: PetCatalog) -> CGImage {
        let sprite = catalog.icons[icon]!
        return PixelImage.make(width: sprite.size[0], height: sprite.size[1], pixels: itemPixels(icon, catalog: catalog))
    }
    static func egg(_ pet: PetID, cracked: Bool = false, catalog: PetCatalog) -> CGImage {
        let sprite = cracked ? catalog.eggs.cracked : catalog.eggs.base
        let pixels = pixels(sprite, catalog: catalog, recolor: catalog.find(pet)?.egg.recolor ?? [:])
        return PixelImage.make(width: sprite.size[0], height: sprite.size[1], pixels: pixels)
    }

    @MainActor private static var cache: [String: CGImage] = [:]
    @MainActor private static var cachedCatalog: PetCatalog?

    /// One spare row lets either body bob without moving its feet off the ground.
    @MainActor static func image(_ pet: PetID, _ frame: Frame, catalog: PetCatalog, form: PetForm = .hatchling, nightcap: Bool = false) -> CGImage {
        if cachedCatalog !== catalog {
            cache.removeAll()
            cachedCatalog = catalog
        }
        let key = "\(pet.rawValue)-\(form.rawValue)-\(frame)-\(nightcap)"
        if let cached = cache[key] { return cached }
        let body = catalog.sprite(pet, form: form)
        let width = body.size[0], height = body.size[1] + 1
        let motion = catalog.motion(pet, form: form)
        let source = petPixels(pet, catalog: catalog, form: form)
        var pixels = [UInt32?](repeating: nil, count: width * height)
        for (index, color) in source.enumerated() {
            guard let color else { continue }
            let x = index % width, y = index / width
            let isFoot = (motion.footRows[0]...motion.footRows[1]).contains(y)
            let lift = !isFoot && frame != .rest ? 0 : 1
            let shift = isFoot ? (frame == .stepLeft ? -1 : frame == .stepRight ? 1 : 0) : 0
            let targetX = x + shift
            if (0..<width).contains(targetX) { pixels[(y + lift) * width + targetX] = color }
        }
        if nightcap { addNightcap(to: &pixels, width: width, anchor: motion.nightcapAnchor,
                                  catalog: catalog, offset: frame == .rest ? 1 : 0) }
        let image = PixelImage.make(width: width, height: height, pixels: pixels)
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

    var catalog: PetCatalog? {
        didSet { if catalog !== oldValue { needsDisplay = true } }
    }
    var pet: PetID? {
        didSet { if pet != oldValue { needsDisplay = true } }
    }

    var form: PetForm = .hatchling {
        didSet { if form != oldValue { needsDisplay = true } }
    }
    var moving = false {
        didSet { if moving != oldValue { restartTimer() } }
    }
    var nightcap = false {
        didSet { if nightcap != oldValue { needsDisplay = true } }
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
        guard let context = NSGraphicsContext.current?.cgContext, let pet, let catalog else { return }
        let even = frameIndex % 2 == 0
        let frame: Sprites.Frame = moving ? (even ? .stepLeft : .stepRight) : (even ? .rest : .bob)
        context.interpolationQuality = .none
        context.draw(Sprites.image(pet, frame, catalog: catalog, form: form, nightcap: nightcap), in: bounds)
    }
}

struct SpriteView: NSViewRepresentable {
    @Environment(\.petCatalog) private var catalog
    var pet: PetID
    var scale: CGFloat
    var form: PetForm = .hatchling
    var moving = false
    var nightcap = false

    func makeNSView(context: Context) -> SpriteNSView { SpriteNSView() }

    func updateNSView(_ view: SpriteNSView, context: Context) {
        view.catalog = catalog
        view.pet = pet
        view.form = form
        view.moving = moving
        view.nightcap = nightcap
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpriteNSView, context: Context) -> CGSize? {
        let size = catalog?.sprite(pet, form: form).size ?? [16, 16]
        return CGSize(width: CGFloat(size[0]) * scale, height: CGFloat(size[1] + 1) * scale)
    }
}

private struct PetCatalogKey: EnvironmentKey {
    static let defaultValue: PetCatalog? = nil
}
extension EnvironmentValues {
    var petCatalog: PetCatalog? {
        get { self[PetCatalogKey.self] }
        set { self[PetCatalogKey.self] = newValue }
    }
}
