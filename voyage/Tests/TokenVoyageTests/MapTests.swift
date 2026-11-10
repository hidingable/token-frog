import CoreGraphics
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@Suite struct MapViewportTests {
    @Test func padsEachSideByTwentyPercentAndChoosesTheLargestFittingInteger() throws {
        // In the 120×50 world presentation these endpoints are (10,10) and (30,20).
        let viewport = MapViewport(home: Coordinate(lat: 55.2, lon: -150), destination: Coordinate(lat: 26.4, lon: -90))
        let bounds = try #require(viewport.tripBounds)
        #expect(abs(bounds.x - 6) < 0.000001)
        #expect(abs(bounds.y - 8) < 0.000001)
        #expect(abs(bounds.width - 28) < 0.000001)
        #expect(abs(bounds.height - 14) < 0.000001)
        #expect(viewport.scale == 3)
        #expect(bounds.width * Double(viewport.scale) <= 120 && bounds.height * Double(viewport.scale) <= 50)
        #expect(bounds.height * Double(viewport.scale + 1) > 50)
        #expect(viewport.x <= bounds.x && viewport.x + 120 / Double(viewport.scale) >= bounds.x + bounds.width)
        #expect(viewport.y <= bounds.y && viewport.y + 50 / Double(viewport.scale) >= bounds.y + bounds.height)
    }

    @Test func zoomCapsAtEightAndHandlesCoincidentOrAlignedEndpoints() {
        let home = Coordinate(lat: 31.23, lon: 121.47)
        for destination in [home, Coordinate(lat: home.lat, lon: 121.5), Coordinate(lat: 31.25, lon: home.lon)] {
            let viewport = MapViewport(home: home, destination: destination)
            #expect(viewport.scale == 8 && !viewport.isWorld)
            #expect((0..<120).contains(viewport.point(home).x) && (0..<50).contains(viewport.point(home).y))
        }
        let far = MapViewport(home: Coordinate(lat: 75, lon: -100), destination: Coordinate(lat: -50, lon: 70))
        #expect(far.scale == 1)
    }

    @Test func antimeridianUsesTheShortIntervalAndWrapsMarkersIntoTheSameCrop() throws {
        let home = Coordinate(lat: 30, lon: 179), destination = Coordinate(lat: 29, lon: -179)
        let viewport = MapViewport(home: home, destination: destination)
        #expect(try #require(viewport.tripBounds).width < 1)
        #expect(viewport.scale == 8)
        let a = viewport.point(home), b = viewport.point(destination)
        #expect(abs(a.x - b.x) <= 6)
        #expect((0..<120).contains(a.x) && (0..<120).contains(b.x))
    }

    @Test func regionIsFixedThroughMovementStayReturnAndPersistedHomeAndPending() throws {
        let catalog = localizationCatalog
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", catalog: catalog)
        journey.targetCityId = "jingdezhen"
        journey.legTo = catalog.city("jingdezhen").coordinate
        journey.legCost = JourneyState.cost(from: catalog.city("shanghai"), to: catalog.city("jingdezhen"))
        let region = MapViewport(journey: journey, catalog: catalog)
        for fuel in [0, journey.legCost / 2, journey.legCost] {
            journey.legFuel = fuel
            #expect(MapViewport(journey: journey, catalog: catalog) == region)
        }
        journey.phase = .staying
        journey.currentCityId = journey.targetCityId
        journey.route.append(journey.currentCityId)
        #expect(MapViewport(journey: journey, catalog: catalog) == region)
        journey.phase = .returning
        journey.legFrom = journey.legTo
        journey.legTo = journey.homeCoordinate
        journey.targetCityId = journey.homeCityId
        #expect(MapViewport(journey: journey, catalog: catalog) == region)
        journey.legFuel = journey.legCost / 3
        #expect(MapViewport(journey: journey, catalog: catalog) == region)
        for phase in [JourneyState.Phase.home, .pending] {
            journey.phase = phase
            journey.currentCityId = journey.homeCityId
            journey.targetCityId = "beijing"
            journey.legFrom = journey.homeCoordinate
            journey.legTo = catalog.city("beijing").coordinate
            journey.legFuel = 0
            let restored = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
            #expect(MapViewport(journey: restored, catalog: catalog) == region)
        }
        journey.phase = .outbound
        #expect(MapViewport(journey: journey, catalog: catalog) != region)
    }

    @Test func beforeAnyTripHomeAndPendingUseWorldDespiteAnAlreadyDrawnDestination() {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", catalog: localizationCatalog)
        for phase in [JourneyState.Phase.home, .pending] {
            journey.phase = phase
            #expect(journey.route.isEmpty)
            #expect(MapViewport(journey: journey, catalog: localizationCatalog) == .world)
        }
        journey.phase = .outbound
        #expect(!MapViewport(journey: journey, catalog: localizationCatalog).isWorld)
    }
}

@Suite @MainActor struct MapMarkerTests {
    private func journey() -> JourneyState {
        var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", catalog: localizationCatalog)
        state.targetCityId = "tokyo"
        state.legTo = localizationCatalog.city("tokyo").coordinate
        state.legCost = JourneyState.cost(from: localizationCatalog.city("shanghai"), to: localizationCatalog.city("tokyo"))
        return state
    }

    private func colors(_ image: CGImage) throws -> [UInt32] {
        let data = try #require(image.dataProvider?.data) as Data
        return stride(from: 0, to: data.count, by: 4).map {
            UInt32(data[$0]) << 16 | UInt32(data[$0 + 1]) << 8 | UInt32(data[$0 + 2])
        }
    }

    private func color(_ image: CGImage, at point: MapPoint) throws -> UInt32 {
        try colors(image)[point.y * image.width + point.x]
    }

    @Test(arguments: [ThemeScheme.dark, .light])
    func onlyStaysHomeAndCurrentArePaintedWithSemanticColors(scheme: ThemeScheme) throws {
        let theme = AppTheme(testThemes.standard(scheme))
        var state = journey()
        state.legFuel = state.legCost / 2
        state.route = ["hangzhou", "suzhou", "hangzhou"]
        let viewport = MapViewport(journey: state, catalog: localizationCatalog)
        let markers = MapMarkers(journey: state, catalog: localizationCatalog, viewport: viewport)
        #expect(markers.stayed == state.route.map { viewport.point(localizationCatalog.city($0).coordinate) })
        #expect(markers.current == viewport.point(state.position))
        #expect(!markers.stayed.contains(viewport.point(state.legTo)))
        let image = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme)
        let pixels = try colors(image)
        #expect(pixels.filter { $0 == theme.rgb(.mapPosition) }.count == 4)
        #expect(pixels.filter { $0 == theme.rgb(.mapMarker) }.count == 7)
        #expect(try color(image, at: viewport.point(state.legTo)) != theme.rgb(.mapStayed))
        #expect(try color(image, at: viewport.point(localizationCatalog.city("fukuoka").coordinate)) != theme.rgb(.mapStayed))
        #expect(try color(image, at: markers.home) == theme.rgb(.paper))
        #expect(theme.rgb(.mapPosition) == 0xF4B63F && theme.rgb(.mapStayed) == 0x7FD1C7)
        let mint = Set(pixels.enumerated().filter { $0.element == theme.rgb(.mapStayed) }.map(\.offset))
        let stayed = Set(markers.stayed.map { $0.y * 120 + $0.x })
        #expect(mint == stayed)
        #expect(Set(pixels).isSubset(of: [theme.rgb(.mapSea), theme.rgb(.mapLand), theme.rgb(.mapMarker), theme.rgb(.mapPosition), theme.rgb(.mapStayed)]))
    }

    @Test(arguments: [ThemeScheme.dark, .light])
    func currentCoversHomeHomeCoversStaysAndBlinkRevealsUnderlyingMarkers(scheme: ThemeScheme) throws {
        let theme = AppTheme(testThemes.standard(scheme))
        var state = journey()
        state.route = [state.homeCityId]
        let viewport = MapViewport(journey: state, catalog: localizationCatalog)
        let home = viewport.point(state.homeCoordinate)
        let on = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme)
        let off = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme, currentVisible: false)
        #expect(try color(on, at: home) == theme.rgb(.mapPosition))
        #expect(try color(off, at: home) == theme.rgb(.mapMarker))
        #expect(try colors(off).filter { $0 == theme.rgb(.mapMarker) }.count == 7)
        #expect(try !colors(off).contains(theme.rgb(.mapStayed)))
        #expect(on === PixelMap.image(for: state, catalog: localizationCatalog, theme: theme))
        #expect(off === PixelMap.image(for: state, catalog: localizationCatalog, theme: theme, currentVisible: false))
        for phase in [JourneyState.Phase.home, .pending] {
            state.phase = phase
            let markers = MapMarkers(journey: state, catalog: localizationCatalog, viewport: viewport)
            #expect(markers.current == nil)
            let image = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme)
            #expect(try !colors(image).contains(theme.rgb(.mapPosition)))
        }
        state.phase = .staying
        state.currentCityId = state.targetCityId
        state.route = [state.targetCityId]
        state.legFuel = state.legCost
        let atStay = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme)
        let blinkOff = PixelMap.image(for: state, catalog: localizationCatalog, theme: theme, currentVisible: false)
        let destination = viewport.point(state.legTo)
        #expect(try color(atStay, at: destination) == theme.rgb(.mapPosition))
        #expect(try color(blinkOff, at: destination) == theme.rgb(.mapStayed))
    }

    @Test func homePickerAlwaysKeepsWorldPresentationAndCurrentBlinks() {
        let city = localizationCatalog.city("shanghai")
        let theme = AppTheme(testThemes.standard(.dark))
        let image = PixelMap.homeImage(city, theme: theme)
        #expect(image.width == 120 && image.height == 50)
        #expect(WorldMapData.width == 480 && WorldMapData.height == 200)
        #expect(WorldMapData.rows.count == WorldMapData.height)
        #expect(WorldMapData.rows.allSatisfy { $0.count == WorldMapData.width && Set($0).isSubset(of: ["#", "."]) })
        #expect(PixelMap.currentVisible(at: Date(timeIntervalSinceReferenceDate: 0.1)))
        #expect(!PixelMap.currentVisible(at: Date(timeIntervalSinceReferenceDate: 0.8)))
        #expect(PixelMap.currentVisible(at: Date(timeIntervalSinceReferenceDate: 1.5)))
    }

    @Test func homeOnTheWorldSeamKeepsAllSevenHousePixels() throws {
        var city = localizationCatalog.city("shanghai")
        city.lon = 179.9
        let theme = AppTheme(testThemes.standard(.dark))
        let image = PixelMap.homeImage(city, theme: theme)
        #expect(try colors(image).filter { $0 == theme.rgb(.mapMarker) }.count == 7)
        #expect(MapViewport.world.point(city.coordinate).x == 0)
    }
}
