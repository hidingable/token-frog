import AppKit
import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class FormDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}
private func formBytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

@Suite @MainActor struct PetFormDisplayTests {
    @Test func spriteAndRoomCachesRefreshAtBothFormBoundariesAndPlacementChanges() throws {
        let catalog = localizationCatalog.pets
        for pet in catalog.all.map(\.id) {
            let images = [4, 5, 19, 20].map { Sprites.image(pet, .rest, catalog: catalog, form: .current(companionDays: $0)) }
            #expect(images.map(\.width) == [16, 20, 20, 20])
            #expect(images[1] === images[2])
            #expect(formBytes(images[2]) != formBytes(images[3]))
            #expect(images[3] === Sprites.image(pet, .rest, catalog: catalog, form: .teen))
            let theme = AppTheme(testThemes.standard(.dark))
            let hatch = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: catalog)
            let young = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: catalog, form: .juvenile)
            let teen = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: catalog, form: .teen)
            #expect(formBytes(hatch) != formBytes(young) && formBytes(young) != formBytes(teen))
            let item = try #require(localizationCatalog.items.all.first { $0.kind == "souvenir" })
            let decorated = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: catalog, form: .teen, placements: [.wall: item])
            #expect(formBytes(decorated) != formBytes(teen))
            #expect(formBytes(RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: catalog, form: .teen)) == formBytes(teen))
        }
    }

    @Test func sleepCapsUseEveryBodyAnchorAndAnimationHasTheDeclaredSize() {
        let catalog = localizationCatalog.pets
        for pet in catalog.all.map(\.id) { for form in PetForm.allCases {
            let sprite = catalog.sprite(pet, form: form)
            let rows = sprite.size[0] == 16
                ? ["...ggggll...", "..gggggll...", ".gggggggll..", "llllllllllww"]
                : ["...ggggll.", "..gggggll.", ".gggggggll", "llllllllww"]
            let anchor = catalog.motion(pet, form: form).nightcapAnchor
            let capped = Sprites.petPixels(pet, catalog: catalog, form: form, nightcap: true)
            #expect(capped != Sprites.petPixels(pet, catalog: catalog, form: form))
            for (y, row) in rows.enumerated() { for (x, symbol) in row.enumerated() where symbol != "." {
                #expect(capped[(y + anchor[1]) * sprite.size[0] + x + anchor[0]] == catalog.palette[symbol])
            } }
            let rest = formBytes(Sprites.image(pet, .rest, catalog: catalog, form: form))
            let bob = formBytes(Sprites.image(pet, .bob, catalog: catalog, form: form))
            let motion = catalog.motion(pet, form: form)
            let footStart = (motion.footRows[0] + 1) * sprite.size[0] * 4
            #expect(rest[footStart...] == bob[footStart...]) // Bobbing never lifts the feet.
            #expect(rest != bob)
            for frame in Sprites.Frame.allCases {
                let image = Sprites.image(pet, frame, catalog: catalog, form: form, nightcap: true)
                #expect(image.width == sprite.size[0] && image.height == sprite.size[1] + 1 && !image.shouldInterpolate)
            }
            #expect(RoomLayout.petBounds(form: form).maxY == 108 && RoomLayout.petBounds(form: form).midX == 132)
        } }
    }

    @Test func hatchlingNightcapPixelsMatchTheExistingGoldenWithTheOriginalOverlay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let file = root.appendingPathComponent("Fixtures/pet-pixels-before.json")
        let golden = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))
        let catalog = localizationCatalog.pets
        let originalCap = [".....ggggll.....", "....gggggll.....", "...gggggggll....", "..llllllllllww.."]
        for pet in catalog.all.map(\.id) { for frame in Sprites.Frame.allCases {
            var expected = [UInt8](try #require(Data(base64Encoded: golden["pet/\(pet.rawValue)/\(frame)"]!["rgba"]!)))
            for (y, row) in originalCap.enumerated() { for (x, symbol) in row.enumerated() where symbol != "." {
                let color = catalog.palette[symbol]!
                let index = ((y + (frame == .rest ? 1 : 0)) * 16 + x) * 4
                expected[index] = UInt8((color >> 16) & 255)
                expected[index + 1] = UInt8((color >> 8) & 255)
                expected[index + 2] = UInt8(color & 255)
                expected[index + 3] = 255
            } }
            #expect(formBytes(Sprites.image(pet, frame, catalog: catalog, nightcap: true)) == Data(expected))
        } }
    }

    @Test func placementHitsStayClearOfDoorWindowShelfPetAndBubbles() {
        let obstacles = [CGRect(x: 202, y: 44, width: 28, height: 52), CGRect(x: 14, y: 16, width: 48, height: 44),
                         CGRect(x: 78, y: 37, width: 78, height: 18), RoomLayout.petBounds(form: .teen).insetBy(dx: -2, dy: -2),
                         RoomLayout.bubbleRegion(scale: 1, souvenir: true, form: .teen)]
        let hits = RoomSlot.allCases.map { RoomLayout.slotBounds($0).insetBy(dx: -1, dy: -1) }
        for hit in hits { for obstacle in obstacles { #expect(!hit.intersects(obstacle)) } }
        for i in hits.indices { for j in hits.indices where i != j { #expect(!hits[i].intersects(hits[j])) } }
        #expect(FloatingLayout.normalSize(form: .juvenile).height >= 21 * 2 + 12)
    }

    @Test(arguments: [false, true])
    func cardsWaitForRitualsBoxesAndMainWindowAndNeverRepeatAfterSkipOrDisplay(acknowledgeOnDisplay: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-form-display-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: now, catalog: localizationCatalog)
        for index in journey.letters.indices { journey.letters[index].deliverAt = now; journey.letters[index].read = false }
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: "2026-11-01")
        care.companionDays = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"]
        care.weekly.boxes = ["2026-11-02#4"]
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
        func model() -> AppModel {
            AppModel(defaults: FormDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                     now: { now }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
        }
        let first = model()
        first.setMainWindowPresented(true)
        first.activateHomeAction()
        #expect(first.care?.companionDays.count == 5 && first.petForm == .juvenile)
        #expect(first.ritualLetter != nil && first.petMoment == nil)
        first.showBoxes()
        #expect(first.petMoment == nil && first.presentedBoxID != nil)
        #expect(first.openPresentedBox() != nil)
        first.finishBox()
        #expect(first.petMoment == .juvenile)
        first.setMainWindowPresented(false)
        first.postOfficeDidDisplay(surface: .floating)
        first.postOfficeDidDisplay(surface: .notch)
        #expect(first.petMoment == nil && first.care?.seenPetStages == [])
        first.setMainWindowPresented(true)
        if acknowledgeOnDisplay {
            first.petMomentDidDisplay(.juvenile)
            #expect(first.petMoment == .juvenile) // Persisting acknowledgement must not dismiss the visible card.
            first.setMainWindowPresented(false)
        } else { first.dismissPetMoment() }
        let reloaded = model()
        reloaded.setMainWindowPresented(true)
        #expect(reloaded.petMoment == nil && reloaded.care?.seenPetStages == ["juvenile"])
        #expect(!reloaded.canArrangeRoom)
        reloaded.showRoomArrangement()
        #expect(reloaded.homePage == .room)
    }
}
