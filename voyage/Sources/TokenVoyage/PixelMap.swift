import SwiftUI
import VoyageCore

@MainActor
enum PixelMap {
    private struct Point: Hashable { let x: Int; let y: Int }
    private struct HomeKey: Hashable { let themeID: String; let point: Point }
    private struct RouteKey: Equatable {
        let stops: [Point]
        let here: Point
        let origin: Point
        let target: Point
    }
    private static var bases: [String: [UInt32?]] = [:]
    private static var homes: [HomeKey: CGImage] = [:]
    // Only the latest route frame is retained for each theme; moving never grows the cache.
    private static var routes: [String: (key: RouteKey, image: CGImage)] = [:]

    private static func base(theme: AppTheme) -> [UInt32?] {
        if let pixels = bases[theme.id] { return pixels }
        let pixels: [UInt32?] = WorldMapData.rows.flatMap { row in
            row.map { theme.rgb($0 == "#" ? .mapLand : .mapSea) }
        }
        bases[theme.id] = pixels
        return pixels
    }

    private static func project(_ point: Coordinate) -> Point {
        let width = Double(WorldMapData.width)
        let height = Double(WorldMapData.height)
        let x = Int((point.lon + 180) / 360 * width)
        let y = Int((WorldMapData.latTop - point.lat) / (WorldMapData.latTop - WorldMapData.latBottom) * height)
        return Point(x: min(max(x, 0), WorldMapData.width - 1), y: min(max(y, 0), WorldMapData.height - 1))
    }

    static func homeImage(_ city: City, theme: AppTheme) -> CGImage {
        let point = project(city.coordinate)
        let key = HomeKey(themeID: theme.id, point: point)
        if let image = homes[key] { return image }
        var pixels = base(theme: theme)
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(max(point.x + dx, 0), WorldMapData.width - 1)
                let y = min(max(point.y + dy, 0), WorldMapData.height - 1)
                pixels[y * WorldMapData.width + x] = dx == 0 && dy == 0 ? theme.rgb(.mapPosition) : theme.rgb(.mapMarker)
            }
        }
        let image = PixelImage.make(width: WorldMapData.width, height: WorldMapData.height, pixels: pixels)
        homes[key] = image
        return image
    }

    static func image(for state: JourneyState, catalog: CityCatalog, theme: AppTheme) -> CGImage {
        let key = RouteKey(stops: state.route.compactMap { catalog.find($0) }.map { project($0.coordinate) },
                           here: project(state.position), origin: project(state.legFrom), target: project(state.legTo))
        if let cached = routes[theme.id], cached.key == key { return cached.image }
        var pixels = base(theme: theme)
        let width = WorldMapData.width
        let height = WorldMapData.height

        func plot(_ x: Int, _ y: Int, _ color: UInt32) {
            let wrapped = (x % width + width) % width
            guard (0..<height).contains(y) else { return }
            pixels[y * width + wrapped] = color
        }

        func line(_ from: Point, _ to: Point, _ color: UInt32, dotted: Bool = false) {
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

        let stops = key.stops
        for (from, to) in zip(stops, stops.dropFirst()) { line(from, to, theme.rgb(.mapRoute)) }
        let here = key.here
        let origin = key.origin
        let target = key.target
        line(here, target, theme.rgb(.mapMarker), dotted: true)
        line(origin, here, theme.rgb(.mapRoute))
        for stop in stops { plot(stop.x, stop.y, theme.rgb(.mapMarker)) }
        plot(target.x, target.y, theme.rgb(.mapDestination))
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { plot(here.x + dx, here.y + dy, theme.rgb(.mapPosition)) }
        let image = PixelImage.make(width: width, height: height, pixels: pixels)
        routes[theme.id] = (key, image)
        return image
    }
}

struct PixelMapView: View {
    var image: CGImage
    var availableWidth: CGFloat
    var borderColor: Color

    var scale: Int { RoomLayout.scale(availableWidth: availableWidth, pixelWidth: image.width) }
    var size: CGSize { CGSize(width: image.width * scale, height: image.height * scale) }
    var leadingInset: CGFloat { floor((availableWidth - size.width) / 2) }

    var body: some View {
        PixelArtView(image: image, scale: scale)
            .frame(width: size.width, height: size.height).fixedSize()
            .pixelBorder(borderColor)
            .padding(.leading, leadingInset)
            .frame(width: availableWidth, alignment: .leading)
    }
}
