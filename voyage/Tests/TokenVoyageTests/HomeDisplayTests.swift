import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let floorNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!

@MainActor @Test(arguments: [Language.zhHans, .en])
func homeStatusUsesTheActualPhase(language: Language) throws {
    let l10n = L10n(language: language)
    for phase in [JourneyState.Phase.home, .pending, .outbound, .staying, .returning] {
        let example = Snapshots.homePhaseExample(phase: phase, catalog: localizationCatalog, now: floorNow, petName: "Ginkgo")
        let display = HomeStatusDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: l10n)
        switch phase {
        case .home:
            #expect(display.title == (language == .zhHans ? "在家 · 刚从景德镇回来" : "At home · Just back from Jingdezhen"))
            #expect(display.detail == l10n("home.status.brought", 2))
            #expect(display.fund == l10n("home.status.fund", "46 km"))
        case .pending:
            #expect(display.title == l10n("home.status.pending", l10n.cityName(localizationCatalog.city("jingdezhen"))))
            #expect(display.detail == l10n("home.status.departure", 28, l10n.itemName(try #require(localizationCatalog.items.find("sketchbook")))))
            #expect(display.fund == nil)
        case .outbound:
            #expect(display.title == l10n("home.status.outbound", l10n.cityName(localizationCatalog.city("jingdezhen"))))
            #expect(display.detail == l10n("journey.remaining", Format.km(example.journey.remainingKm)))
        case .staying:
            #expect(display.title == (language == .zhHans ? "在景德镇 · 还停 4 时 20 分" : "In Jingdezhen · Staying 4 h 20 min more"))
            #expect(display.detail == l10n("home.status.fund", "46 km"))
        case .returning:
            #expect(display.title == l10n("home.status.returning", Format.km(example.journey.remainingKm)))
            #expect(display.detail == l10n("home.status.fund", "46 km"))
        }
        #expect(example.journey.petIsHome == (phase == .home || phase == .pending))
    }
}

@MainActor @Test func floorParcelsAreCappedAndOpeningRevealsTheNextWithoutGrantingAnything() throws {
    var example = Snapshots.homePhaseExample(phase: .home, catalog: localizationCatalog, now: floorNow, petName: "Ginkgo")
    let letterID = try #require(example.journey.letters.first { $0.tripNumber == example.journey.tripCount }?.id)
    let items = localizationCatalog.items.all.filter { $0.kind == "souvenir" }.prefix(5)
    example.care.souvenirs = items.map { .init(id: $0.id, letterId: letterID, shelved: false) }
    let originalCare = example.care
    func display() -> HomeFloorDisplay { HomeFloorDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en)) }
    #expect(HomeFloor.parcels(journey: example.journey, care: example.care).count == 5)
    #expect(display().parcels.count == 3)
    var opened: Set<String> = []
    while let parcel = display().parcels.first {
        #expect(opened.insert(parcel.id).inserted)
        #expect(HomeFloor.openParcel(parcel.id, journey: &example.journey, care: example.care))
        #expect(!HomeFloor.openParcel(parcel.id, journey: &example.journey, care: example.care))
        #expect(display().parcels.count <= 3)
    }
    #expect(opened.count == 5 && originalCare == example.care)
    example.journey.phase = .pending
    #expect(display().footprintLevel > 0)
    example.journey.departNow(now: floorNow, catalog: localizationCatalog)
    #expect(example.journey.homecoming == nil && display().parcels.isEmpty && display().footprintLevel == 0)
    #expect(originalCare == example.care)
}

@MainActor @Test func footprintsUseFrozenOneWayDistanceAndAwayOnlyKeepsRugAndCrate() {
    var example = Snapshots.homePhaseExample(phase: .home, catalog: localizationCatalog, now: floorNow, petName: "Ginkgo")
    for (km, level) in [(100.0, 1), (240, 1), (241, 2), (600, 2), (601, 3)] {
        example.journey.homecoming?.medianKm = 300
        example.journey.homecoming?.distanceKm = km
        let display = HomeFloorDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en))
        #expect(display.footprintLevel == level)
    }
    for phase in [JourneyState.Phase.outbound, .staying, .returning] {
        example.journey.phase = phase
        let display = HomeFloorDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en))
        #expect(display.parcels.isEmpty && display.footprintLevel == 0 && display.looseBoard == nil)
        #expect(!display.patches.isEmpty && display.crate == .nailed(stampsNeeded: 1))
    }
}

@Test func rugKeepsFirstStayOrderWithLatestEightDistinctCitiesAndStableColors() {
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-10-01", catalog: localizationCatalog)
    let care = CareState(petName: "Ginkgo", species: journey.pet, hatchedAt: journey.startDate)
    let ids = Array(localizationCatalog.active.prefix(12).map(\.id))
    journey.route = ids + [ids[0], ids[4]]
    for (index, id) in ids.enumerated() {
        journey.days[String(format: "2026-10-%02d", index + 1), default: DayRecord()].arrivals = [id]
    }
    journey.days["2026-11-01", default: DayRecord()].arrivals = [ids[0]]
    let first = HomeFloorDisplay(journey: journey, care: care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en))
    let second = HomeFloorDisplay(journey: journey, care: care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .zhHans))
    #expect(first.patches.map(\.id) == Array(ids.suffix(8)))
    #expect(first.patches.first?.firstStay == "2026-10-05")
    #expect(first.patches == second.patches)
    #expect(first.patches.allSatisfy { (0..<5).contains($0.colorIndex) })
    #expect(HomeFloor.rugColorIndex(cityID: "shanghai") == 3)
    #expect(HomeFloor.rugColorIndex(cityID: "杭州") == HomeFloor.rugColorIndex(cityID: "杭州"))
}

@MainActor @Test func looseBoardUsesAnIndependentOneInFiveRollAndRequiresOldContent() {
    var example = Snapshots.homePhaseExample(phase: .home, catalog: localizationCatalog, now: floorNow, petName: "Ginkgo")
    let display = HomeFloorDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en))
    #expect(display.looseBoard != nil)
    let hits = (1...10_000).filter { HomeFloor.looseBoardRoll(seed: 42, tripCount: $0) % 5 == 0 }.count
    #expect((1800...2200).contains(hits))
    example.care.memories = []
    example.care.specialDays = []
    example.journey.letters = []
    let empty = HomeFloorDisplay(journey: example.journey, care: example.care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en))
    #expect(empty.looseBoard == nil)
}

@Test func weeklyCrateKeepsPendingOldBoxesAndUsesFourAndSixStamps() {
    let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-02", catalog: localizationCatalog)
    var care = CareState(petName: "Ginkgo", species: journey.pet, hatchedAt: journey.startDate)
    func crate() -> HomeFloorDisplay.Crate { HomeFloorDisplay(journey: journey, care: care, now: floorNow, catalog: localizationCatalog, l10n: L10n(language: .en)).crate }
    #expect(crate() == .nailed(stampsNeeded: 4))
    care.weekly.stamps = (2...5).map { "2026-11-0\($0)" }
    #expect(crate() == .nailed(stampsNeeded: 2))
    care.weekly.boxes = ["2026-10-26#4"]
    #expect(crate() == .ready)
    care.weekly.boxes = []
    care.weekly.stamps += ["2026-11-06", "2026-11-07"]
    #expect(crate() == .opened)
}

@Test func floorHitAreasAvoidPetDoorDecorAndEachOther() {
    let interactive = [RoomLayout.crate, RoomLayout.looseBoard] + (0..<3).map(RoomLayout.parcel) + (0..<8).map(RoomLayout.rugPatch)
    let blocked = [RoomLayout.petBounds(form: .teen).insetBy(dx: -2, dy: -2),
                   CGRect(x: 202, y: 52, width: 28, height: 44), RoomLayout.slotBounds(.floor).insetBy(dx: -1, dy: -1)]
    for (index, area) in interactive.enumerated() {
        #expect(CGRect(x: 0, y: 0, width: RoomLayout.width, height: RoomLayout.height + RoomLayout.floorMinRows).contains(area))
        #expect(blocked.allSatisfy { !$0.intersects(area) })
        #expect(interactive.dropFirst(index + 1).allSatisfy { !$0.intersects(area) })
    }
}

@MainActor @Test func roomArtRemovesThePetAndChangesTheDoorWhenAwayWithoutStaleCache() throws {
    for scheme in [ThemeScheme.dark, .light] {
        let theme = AppTheme(testThemes.standard(scheme))
        for form in [PetForm.hatchling, .juvenile, .teen] {
            let pet = localizationCatalog.pets.defaultID
            let home = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: localizationCatalog.pets, form: form)
            let away = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: localizationCatalog.pets, form: form, petIsHome: false)
            let returned = RoomArt.image(pet: pet, shelf: [], theme: theme, catalog: localizationCatalog.pets, form: form)
            let homeData = try #require(home.dataProvider?.data) as Data
            let awayData = try #require(away.dataProvider?.data) as Data
            #expect(homeData != awayData)
            #expect(homeData == (try #require(returned.dataProvider?.data) as Data))
            let petBounds = RoomLayout.petBounds(form: form)
            let door = CGRect(x: 202, y: 52, width: 28, height: 44)
            for y in 0..<RoomLayout.height {
                for x in 0..<RoomLayout.width where !petBounds.contains(CGPoint(x: x, y: y)) && !door.contains(CGPoint(x: x, y: y)) {
                    let offset = (y * RoomLayout.width + x) * 4
                    #expect(homeData[offset..<(offset + 4)] == awayData[offset..<(offset + 4)])
                }
            }
        }
    }
}
