import Foundation
import VoyageCore

struct MapPoint: Equatable, Hashable {
    let x: Int
    let y: Int
}

enum JourneyMapScope: String, CaseIterable {
    case region, world

    func viewport(region: MapViewport) -> MapViewport {
        self == .world ? .world : region
    }
}

/// Zoom is relative to the original 120×50 world presentation, independent of coastline resolution.
struct MapViewport: Equatable {
    static let width = 120
    static let height = 50

    struct Bounds: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let tripBounds: Bounds?
    let scale: Int
    let x: Double
    let y: Double
    var isWorld: Bool { tripBounds == nil }
    static let world = MapViewport(home: Coordinate(lat: 0, lon: 0), destination: nil)

    init(journey: JourneyState, catalog: CityCatalog) {
        let destination: Coordinate?
        switch journey.phase {
        case .home, .pending:
            destination = journey.route.last.flatMap(catalog.find)?.coordinate
        case .outbound, .staying:
            destination = journey.legTo
        case .returning:
            destination = journey.legFrom
        }
        self.init(home: journey.homeCoordinate, destination: destination)
    }

    init(home: Coordinate, destination: Coordinate?) {
        guard let destination else {
            tripBounds = nil
            scale = 1
            x = 0
            y = 0
            return
        }
        let a = Self.project(home)
        let b = Self.project(destination)
        // Use the same short longitude interval as JourneyState.position, including across ±180°.
        let bx = Self.nearestX(b.x, to: a.x)
        let dx = abs(bx - a.x), dy = abs(b.y - a.y)
        let top = max(0, min(a.y, b.y) - dy * 0.2)
        let bottom = min(Double(Self.height), max(a.y, b.y) + dy * 0.2)
        let bounds = Bounds(x: min(a.x, bx) - dx * 0.2, y: top, width: dx * 1.4, height: bottom - top)
        tripBounds = bounds
        let fitX = bounds.width > 0 ? Double(Self.width) / bounds.width : 8
        let fitY = bounds.height > 0 ? Double(Self.height) / bounds.height : 8
        scale = min(8, max(1, Int(min(fitX, fitY).rounded(.down))))
        x = bounds.x + bounds.width / 2 - Double(Self.width) / Double(scale) / 2
        // Fill the fixed canvas around the padded bounds; only the poles limit the padding.
        y = min(max(bounds.y + bounds.height / 2 - Double(Self.height) / Double(scale) / 2, 0),
                Double(Self.height) - Double(Self.height) / Double(scale))
    }

    private static func project(_ coordinate: Coordinate) -> (x: Double, y: Double) {
        (x: (coordinate.lon + 180) / 360 * Double(width),
         y: min(max((WorldMapData.latTop - coordinate.lat) / (WorldMapData.latTop - WorldMapData.latBottom)
                    * Double(height), 0), Double(height - 1)))
    }

    private static func nearestX(_ x: Double, to center: Double) -> Double {
        x + ((center - x) / Double(width)).rounded() * Double(width)
    }

    func point(_ coordinate: Coordinate) -> MapPoint {
        let projected = Self.project(coordinate)
        let px = isWorld ? projected.x : Self.nearestX(projected.x, to: x + Double(Self.width) / Double(scale) / 2)
        let pixelX = Int(((px - x) * Double(scale)).rounded())
        return MapPoint(x: isWorld ? (pixelX % Self.width + Self.width) % Self.width : pixelX,
                        y: Int(((projected.y - y) * Double(scale)).rounded()))
    }
}

struct MapMarkers: Equatable {
    let home: MapPoint
    let current: MapPoint?
    let stayed: [MapPoint]

    init(journey: JourneyState, catalog: CityCatalog, viewport: MapViewport) {
        home = viewport.point(journey.homeCoordinate)
        current = journey.petIsHome ? nil : viewport.point(journey.position)
        stayed = journey.route.compactMap(catalog.find).map { viewport.point($0.coordinate) }
    }
}
