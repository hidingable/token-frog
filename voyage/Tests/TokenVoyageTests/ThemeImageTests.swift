import CoreGraphics
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private func pixels(_ image: CGImage) throws -> Data { try #require(image.dataProvider?.data) as Data }
private func rgb(_ image: CGImage, x: Int, y: Int) throws -> UInt32 {
    let bytes = try pixels(image)
    let offset = (y * image.width + x) * 4
    return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
}

@MainActor
@Test func mapHomeAndRouteCachesArePartitionedByThemeAndRefreshTheirInputs() throws {
    let night = AppTheme(testThemes.standard(.dark)), day = AppTheme(testThemes.standard(.light))
    let city = localizationCatalog.city("shanghai")
    let home = PixelMap.homeImage(city, theme: night)
    let lightHome = PixelMap.homeImage(city, theme: day)
    #expect(home === PixelMap.homeImage(city, theme: night))
    #expect(lightHome === PixelMap.homeImage(city, theme: day))
    #expect(home !== lightHome)
    #expect(try pixels(home) != pixels(lightHome))
    #expect(try rgb(home, x: 0, y: 0) == night.rgb(.mapSea))
    #expect(try rgb(lightHome, x: 0, y: 0) == day.rgb(.mapSea))
    #expect(PixelMap.homeImage(localizationCatalog.city("beijing"), theme: night) !== home)

    var state = JourneyState(seed: 7, startCityId: city.id, date: "2026-11-01", catalog: localizationCatalog)
    let route = PixelMap.image(for: state, catalog: localizationCatalog, theme: night)
    let lightRoute = PixelMap.image(for: state, catalog: localizationCatalog, theme: day)
    #expect(route === PixelMap.image(for: state, catalog: localizationCatalog, theme: night))
    #expect(route !== lightRoute)
    #expect(try pixels(route) != pixels(lightRoute))
    state.legFuel = state.legCost / 2
    #expect(PixelMap.image(for: state, catalog: localizationCatalog, theme: night) !== route)
}

@MainActor
@Test func roomCacheChangesThemeWithoutRecoloringTheCharacter() throws {
    let night = AppTheme(testThemes.standard(.dark)), day = AppTheme(testThemes.standard(.light))
    for pet in localizationCatalog.pets.all.map(\.id) {
        let darkRoom = RoomArt.image(pet: pet, shelf: [], theme: night, catalog: localizationCatalog.pets)
        let lightRoom = RoomArt.image(pet: pet, shelf: [], theme: day, catalog: localizationCatalog.pets)
        #expect(darkRoom === RoomArt.image(pet: pet, shelf: [], theme: night, catalog: localizationCatalog.pets))
        #expect(lightRoom === RoomArt.image(pet: pet, shelf: [], theme: day, catalog: localizationCatalog.pets))
        #expect(darkRoom !== lightRoom)
        #expect(try rgb(darkRoom, x: 0, y: 0) == night.rgb(.roomWallLine))
        #expect(try rgb(lightRoom, x: 0, y: 0) == day.rgb(.roomWallLine))
        #expect(try rgb(darkRoom, x: 24, y: 26) == night.rgb(.roomStar))
        #expect(try rgb(lightRoom, x: 24, y: 26) == day.rgb(.roomWindowBack))
        for (index, color) in Sprites.petPixels(pet, catalog: localizationCatalog.pets).enumerated() {
            guard let color else { continue }
            #expect(try rgb(lightRoom, x: 116 + index % 16 * 2, y: 76 + index / 16 * 2) == color)
        }
    }
    let item = try #require(localizationCatalog.items.find("box.tea-paper"))
    let empty = RoomArt.image(pet: PetID(rawValue: "pigeon"), shelf: [], theme: day, catalog: localizationCatalog.pets)
    let full = RoomArt.image(pet: PetID(rawValue: "pigeon"), shelf: [item], theme: day, catalog: localizationCatalog.pets)
    #expect(empty !== full)
    #expect(try pixels(empty) != pixels(full))
}
