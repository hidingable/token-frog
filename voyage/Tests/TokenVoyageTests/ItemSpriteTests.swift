import Foundation
import Testing
@testable import TokenVoyage

@Test func everyCatalogItemIconHasNonemptyPixelArt() throws {
    let icons = Set(localizationCatalog.items.all.map(\.icon))
    #expect(!icons.isEmpty)
    try #require(icons.isSubset(of: Set(localizationCatalog.pets.icons.keys)))
    for icon in icons {
        let image = Sprites.item(icon, catalog: localizationCatalog.pets)
        #expect(image.width == 12)
        #expect(image.height == 12)
        #expect(!image.shouldInterpolate)
        let data = try #require(image.dataProvider?.data) as Data
        let opaquePixels = stride(from: 3, to: data.count, by: 4).filter { data[$0] == 255 }
        #expect(!opaquePixels.isEmpty, "\(icon) must contain actual pixels")
        #expect(opaquePixels.count < image.width * image.height, "\(icon) retains its transparent surround")
    }
}
