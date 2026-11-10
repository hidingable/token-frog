import SwiftUI
import VoyageCore

@MainActor
enum PixelMap {
    private struct FrameKey: Equatable {
        let viewport: MapViewport
        let markers: MapMarkers
    }
    private static let land = WorldMapData.rows.map { Array($0.utf8) }
    private static var bases: [String: (viewport: MapViewport, pixels: [UInt32?])] = [:]
    // Keep the latest home choice and both blink frames per theme; movement never grows the cache.
    private static var homes: [String: (point: MapPoint, image: CGImage)] = [:]
    private static var frames: [String: (key: FrameKey, visible: CGImage, hidden: CGImage)] = [:]

    private static func base(viewport: MapViewport, theme: AppTheme) -> [UInt32?] {
        if let cached = bases[theme.id], cached.viewport == viewport { return cached.pixels }
        let sea = theme.rgb(.mapSea), ground = theme.rgb(.mapLand)
        let pixels: [UInt32?] = (0..<MapViewport.height).flatMap { y in
            (0..<MapViewport.width).map { x in
                let worldX = viewport.x + (Double(x) + 0.5) / Double(viewport.scale)
                let worldY = viewport.y + (Double(y) + 0.5) / Double(viewport.scale)
                let sourceX = Int(floor(worldX / Double(MapViewport.width) * Double(WorldMapData.width)))
                let wrappedX = (sourceX % WorldMapData.width + WorldMapData.width) % WorldMapData.width
                let sourceY = min(Int(worldY / Double(MapViewport.height) * Double(WorldMapData.height)), WorldMapData.height - 1)
                return land[sourceY][wrappedX] == 35 ? ground : sea
            }
        }
        bases[theme.id] = (viewport, pixels)
        return pixels
    }

    private static func plot(_ point: MapPoint, color: UInt32, wrapsLongitude: Bool, pixels: inout [UInt32?]) {
        let x = wrapsLongitude ? (point.x % MapViewport.width + MapViewport.width) % MapViewport.width : point.x
        guard (0..<MapViewport.width).contains(x), (0..<MapViewport.height).contains(point.y) else { return }
        pixels[point.y * MapViewport.width + x] = color
    }

    private static func house(_ point: MapPoint, theme: AppTheme, wrapsLongitude: Bool, pixels: inout [UInt32?]) {
        // 3×3 silhouette, matching the mockup: one roof pixel over two three-pixel rows.
        for (dx, dy) in [(0, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
            plot(MapPoint(x: point.x + dx, y: point.y + dy), color: theme.rgb(.mapMarker), wrapsLongitude: wrapsLongitude, pixels: &pixels)
        }
    }

    private static func make(_ pixels: [UInt32?]) -> CGImage {
        PixelImage.make(width: MapViewport.width, height: MapViewport.height, pixels: pixels)
    }

    static func homeImage(_ city: City, theme: AppTheme) -> CGImage {
        let point = MapViewport.world.point(city.coordinate)
        if let cached = homes[theme.id], cached.point == point { return cached.image }
        var pixels = base(viewport: .world, theme: theme)
        house(point, theme: theme, wrapsLongitude: true, pixels: &pixels)
        let image = make(pixels)
        homes[theme.id] = (point, image)
        return image
    }

    static func image(for state: JourneyState, catalog: CityCatalog, theme: AppTheme, currentVisible: Bool = true) -> CGImage {
        let viewport = MapViewport(journey: state, catalog: catalog)
        let markers = MapMarkers(journey: state, catalog: catalog, viewport: viewport)
        let key = FrameKey(viewport: viewport, markers: markers)
        if let cached = frames[theme.id], cached.key == key { return currentVisible ? cached.visible : cached.hidden }
        var pixels = base(viewport: viewport, theme: theme)
        for point in markers.stayed { plot(point, color: theme.rgb(.mapStayed), wrapsLongitude: viewport.isWorld, pixels: &pixels) }
        house(markers.home, theme: theme, wrapsLongitude: viewport.isWorld, pixels: &pixels)
        let hidden = make(pixels)
        if let current = markers.current {
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                plot(MapPoint(x: current.x + dx, y: current.y + dy), color: theme.rgb(.mapPosition), wrapsLongitude: viewport.isWorld, pixels: &pixels)
            }
        }
        let visible = markers.current == nil ? hidden : make(pixels)
        frames[theme.id] = (key, visible, hidden)
        return currentVisible ? visible : hidden
    }

    static func currentVisible(at date: Date) -> Bool {
        Int(floor(date.timeIntervalSinceReferenceDate / 0.7)) % 2 == 0
    }
}

/// Shared by the journey page and expanded notch. Snapshots always show the amber marker.
struct JourneyMapView: View {
    @Environment(\.theme) private var theme
    let state: JourneyState
    let catalog: CityCatalog
    let availableWidth: CGFloat
    let borderColor: Color
    var animate = true

    var body: some View {
        if animate && !state.petIsHome {
            TimelineView(.animation(minimumInterval: 0.7)) { context in
                map(currentVisible: PixelMap.currentVisible(at: context.date))
            }
        } else {
            map(currentVisible: true)
        }
    }

    private func map(currentVisible: Bool) -> some View {
        PixelMapView(image: PixelMap.image(for: state, catalog: catalog, theme: theme, currentVisible: currentVisible),
                     availableWidth: availableWidth, borderColor: borderColor)
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
