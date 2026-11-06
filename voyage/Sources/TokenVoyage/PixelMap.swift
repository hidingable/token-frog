import SwiftUI
import VoyageCore

enum PixelMap {
    private static let base: [UInt32?] = {
        WorldMapData.rows.flatMap { row in row.map { $0 == "#" ? Palette.land : Palette.sea } }
    }()

    private static func project(_ point: Coordinate) -> (x: Int, y: Int) {
        let width = Double(WorldMapData.width)
        let height = Double(WorldMapData.height)
        let x = Int((point.lon + 180) / 360 * width)
        let y = Int((WorldMapData.latTop - point.lat) / (WorldMapData.latTop - WorldMapData.latBottom) * height)
        return (min(max(x, 0), WorldMapData.width - 1), min(max(y, 0), WorldMapData.height - 1))
    }

    static func image(for state: JourneyState) -> CGImage {
        var pixels = base
        let width = WorldMapData.width
        let height = WorldMapData.height

        func plot(_ x: Int, _ y: Int, _ color: UInt32) {
            let wrapped = (x % width + width) % width
            guard (0..<height).contains(y) else { return }
            pixels[y * width + wrapped] = color
        }

        func line(_ from: (x: Int, y: Int), _ to: (x: Int, y: Int), _ color: UInt32, dotted: Bool = false) {
            var endX = to.x
            if endX - from.x > width / 2 { endX -= width }
            if from.x - endX > width / 2 { endX += width }
            let steps = max(abs(endX - from.x), abs(to.y - from.y), 1)
            for step in 0...steps where !dotted || step % 2 == 0 {
                let x = from.x + (endX - from.x) * step / steps
                let y = from.y + (to.y - from.y) * step / steps
                plot(x, y, color)
            }
        }

        let stops = state.route.compactMap(City.find).map { project($0.coordinate) }
        for (from, to) in zip(stops, stops.dropFirst()) { line(from, to, Palette.amber) }
        let here = project(state.position)
        let origin = project(state.current.coordinate)
        let target = project(state.target.coordinate)
        line(here, target, Palette.paper, dotted: true)
        line(origin, here, Palette.amber)
        for stop in stops { plot(stop.x, stop.y, Palette.paper) }
        plot(target.x, target.y, Palette.mint)
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { plot(here.x + dx, here.y + dy, Palette.ink) }
        return PixelImage.make(width: width, height: height, pixels: pixels)
    }
}

struct PixelMapView: View {
    @Environment(\.l10n) private var l10n
    var state: JourneyState
    var scale: CGFloat

    var body: some View {
        Image(decorative: PixelMap.image(for: state), scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(WorldMapData.width) * scale, height: CGFloat(WorldMapData.height) * scale)
            .accessibilityLabel(l10n("map.description", state.current.name, state.target.name))
    }
}
