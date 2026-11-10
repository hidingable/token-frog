import Foundation
import Testing
@testable import VoyageCore

private func decorCare(days: Int = 20) -> CareState {
    var care = CareState(petName: "Pip", species: .init(rawValue: "pigeon"), hatchedAt: "2026-10-01")
    care.companionDays = (1...max(1, days)).prefix(days).map { String(format: "2026-10-%02d", $0) }
    care.souvenirs = testCatalog.items.all.filter { $0.kind == "souvenir" }.prefix(8).map {
        .init(id: $0.id, letterId: nil, boxId: nil, shelved: false)
    }
    return care
}

@Suite struct PetMilestoneAndDecorTests {
    @Test func growthCardsOccurOnceAndSkippingIsAnAcknowledgement() throws {
        var care = decorCare(days: 4)
        #expect(PetMilestones.pending(in: care) == nil)
        care.companionDays.append("2026-10-05")
        #expect(PetMilestones.pending(in: care) == .juvenile)
        PetMilestones.acknowledge(.juvenile, care: &care)
        PetMilestones.acknowledge(.juvenile, care: &care)
        #expect(care.seenPetStages == ["juvenile"])
        #expect(PetMilestones.pending(in: care) == nil)
        care.companionDays = decorCare(days: 20).companionDays
        #expect(PetMilestones.pending(in: care) == .teen)
        PetMilestones.acknowledge(.teen, care: &care)
        care = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care))
        #expect(PetMilestones.pending(in: care) == nil)
        #expect(care.seenPetStages == ["juvenile", "teen"])
    }

    @Test(arguments: [4, 5, 19, 20])
    func oldSavesBaselineExistingStagesAndNeverBackfillCards(days: Int) throws {
        let original = decorCare(days: days)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "seenPetStages")
        json.removeValue(forKey: "roomPlacements")
        var care = try JSONDecoder().decode(CareState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(care.seenPetStages == nil && care.roomPlacements == nil)
        #expect(PetMilestones.pending(in: care) == nil)
        #expect(PetMilestones.establishBaseline(care: &care))
        #expect(!PetMilestones.establishBaseline(care: &care))
        #expect(PetMilestones.pending(in: care) == nil)
        #expect(care.seenPetStages == (days >= 20 ? ["juvenile", "teen"] : days >= 5 ? ["juvenile"] : []))
    }

    @Test(arguments: [0, 4, 5, 19, 20, 60, 170, 340])
    func arrangementUnlocksAtTeenAndRejectsUnownedOrNonSouvenirItems(days: Int) {
        var care = decorCare(days: days)
        let original = care
        let id = care.souvenirs[0].id
        #expect(RoomDecor.place(id, in: .windowsill, care: &care, library: testCatalog.items) == (days >= 20))
        if days < 20 { #expect(care == original) }
        #expect(!RoomDecor.place("unknown", in: .wall, care: &care, library: testCatalog.items))
        #expect(!RoomDecor.place("sketchbook", in: .wall, care: &care, library: testCatalog.items))
    }

    @Test func movingToAndFromShelfAndClearingKeepsOneCopyWithoutRewards() {
        var care = decorCare()
        let id = care.souvenirs[0].id
        #expect(CareEngine.setShelved(id: id, shelved: true, care: &care))
        #expect(RoomDecor.place(id, in: .windowsill, care: &care, library: testCatalog.items))
        #expect(care.souvenirs.allSatisfy { !$0.shelved })
        #expect(RoomDecor.place(id, in: .floor, care: &care, library: testCatalog.items))
        #expect(RoomDecor.item(in: .windowsill, care: care) == nil)
        #expect(care.roomPlacements?.count == 1)
        #expect(CareEngine.setShelved(id: id, shelved: true, care: &care))
        #expect(care.roomPlacements?.isEmpty == true)
        #expect(RoomDecor.place(id, in: .wall, care: &care, library: testCatalog.items))
        #expect(RoomDecor.place(nil, in: .wall, care: &care, library: testCatalog.items))
        #expect(care.roomPlacements?.isEmpty == true)
        var expected = decorCare()
        expected.roomPlacements = []
        #expect(care == expected)
    }

    @Test func fullShelfRefusesMoveWithoutLosingPlacement() {
        var care = decorCare()
        for id in care.souvenirs.prefix(4).map(\.id) { #expect(CareEngine.setShelved(id: id, shelved: true, care: &care)) }
        let id = care.souvenirs[4].id
        #expect(RoomDecor.place(id, in: .floor, care: &care, library: testCatalog.items))
        #expect(!CareEngine.setShelved(id: id, shelved: true, care: &care))
        #expect(RoomDecor.item(in: .floor, care: care) == id)
    }

    @Test func cleaningDropsUnknownSlotsUnknownItemsUnownedIDsAndDuplicateSlotsOrItems() throws {
        var care = decorCare()
        let ids = care.souvenirs.map(\.id)
        care.souvenirs[0].shelved = true
        care.souvenirs.append(care.souvenirs[0])
        care.souvenirs.append(.init(id: "unknown-owned", letterId: nil, boxId: nil, shelved: false))
        care.roomPlacements = [
            .init(slot: "future-slot", itemID: ids[1]), .init(slot: "wall", itemID: "unknown-owned"),
            .init(slot: "floor", itemID: "unknown"), .init(slot: "wall", itemID: ids[0]),
            .init(slot: "wall", itemID: ids[1]), .init(slot: "cabinet", itemID: ids[1]),
            .init(slot: "wall", itemID: ids[2]), .init(slot: "floor", itemID: ids[3]),
        ]
        care = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care))
        RoomDecor.clean(care: &care, library: testCatalog.items)
        #expect(care.souvenirs.filter(\.shelved).map(\.id) == [ids[0]])
        #expect(care.roomPlacements == [.init(slot: "wall", itemID: ids[1]), .init(slot: "floor", itemID: ids[3])])
        let cleaned = care
        RoomDecor.clean(care: &care, library: testCatalog.items)
        #expect(care == cleaned)
    }

    @Test func loadAndImportPersistCleaningAndOldSaveBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-decor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-10-01", catalog: testCatalog)
        var care = decorCare()
        care.seenPetStages = nil
        let id = care.souvenirs[0].id
        care.roomPlacements = [.init(slot: "wall", itemID: id), .init(slot: "floor", itemID: id), .init(slot: "cabinet", itemID: "unknown")]
        try JSONEncoder().encode(journey).write(to: directory.appendingPathComponent("journey.json"))
        try JSONEncoder().encode(care).write(to: directory.appendingPathComponent("care.json"))
        let store = SaveStore(directory: directory, pets: testCatalog.pets, items: testCatalog.items, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let loaded) = store.care else { Issue.record("Save did not load"); return }
        #expect(loaded.roomPlacements == [.init(slot: "wall", itemID: id)])
        #expect(loaded.seenPetStages == ["juvenile", "teen"])
        let archive = try JSONSerialization.data(withJSONObject: [
            "format": 1, "exportedAt": "2026-11-09T01:00:00Z", "appVersion": "1.0",
            "journey": JSONSerialization.jsonObject(with: JSONEncoder().encode(journey)),
            "care": JSONSerialization.jsonObject(with: JSONEncoder().encode(care)),
        ])
        let validated = try store.validateArchive(archive)
        #expect(validated.care.roomPlacements == care.roomPlacements)
        #expect(validated.care.seenPetStages == loaded.seenPetStages)
        try store.importArchive(validated)
        #expect(try JSONDecoder().decode(CareState.self, from: Data(contentsOf: directory.appendingPathComponent("care.json"))) == loaded)
    }

    @Test func doublingUsageNeverChangesFormOrDecor() {
        func simulate(_ multiplier: Int) -> CareState {
            var journey = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-10-01", catalog: testCatalog)
            var care = decorCare()
            _ = RoomDecor.place(care.souvenirs[0].id, in: .floor, care: &care, library: testCatalog.items)
            journey.sync(today: DayUsage(date: journey.openDate, fuel: 30_000 * multiplier), now: DayKey.date(from: (DayUsage(date: journey.openDate, fuel: 30_000 * multiplier)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
            CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
            return care
        }
        let one = simulate(1), two = simulate(2)
        #expect(PetForm.current(companionDays: one.companionDays.count) == PetForm.current(companionDays: two.companionDays.count))
        #expect(one.roomPlacements == two.roomPlacements)
        #expect(one == two)
    }

    @Test(arguments: ["missing-language", "duplicate", "bad-stage", "empty", "slot"])
    func momentCopyIsValidated(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("pet-moments.json") { json in
            var cards = json["cards"] as! [[String: Any]]
            switch failure {
            case "missing-language": cards[0]["title"] = ["en": "Growing"]
            case "duplicate": cards[1] = cards[0]
            case "bad-stage": cards[0]["stage"] = "traveler"
            case "empty": cards[0]["body"] = ["en": " ", "zh-Hans": " "]
            default: cards[0]["title"] = ["en": "{unsupported}", "zh-Hans": "{unsupported}"]
            }
            json["cards"] = cards
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "petMoments" })
    }
}
