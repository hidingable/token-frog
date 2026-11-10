import Foundation
import Testing
@testable import VoyageCore

private func encounterPhoto(city: String = "quanzhou", date: String = "2026-11-01") -> EncounterPhoto {
    .init(cityId: city, partner: .init(species: "snail", stage: "juvenile"), localDate: date,
          own: .init(species: "pigeon", stage: "teen"))
}

@Suite struct EncounterTests {
    @Test func nextSettlementCreatesOneSnapshotAtNormalDeliveryEvenWithoutUsageOrWindowOpen() throws {
        var (journey, care) = engineState()
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let initialCare = care
        journey.recordEncounter(encounterPhoto())
        #expect(journey.letters.allSatisfy { $0.encounter == nil })
        journey.sync(today: DayUsage(date: "2026-11-02"), now: DayKey.date(from: "2026-11-02", calendar: careCalendar)!,
                     calendar: careCalendar, catalog: testCatalog, deliveryTime: .standard)
        let letter = try #require(journey.letters.first { $0.encounter != nil })
        #expect(letter.kind == .postcard && letter.date == "2026-11-01")
        #expect(letter.cityId == "quanzhou" && letter.encounter == encounterPhoto())
        #expect(careCalendar.component(.hour, from: letter.deliverAt) == DeliveryTime.standard.hour)
        #expect(DayKey.string(from: letter.deliverAt, calendar: careCalendar) == "2026-11-02")
        #expect(Set(letter.texts?.keys.map { $0 } ?? []) == ["zh-Hans", "en"])
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(care == initialCare)
        #expect(letter.rewards == StoryRewards() && letter.rewardItems.isEmpty)
        let replay = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        #expect(replay == journey && replay.version == 8)
        journey.recordEncounter(encounterPhoto())
        journey.sync(today: DayUsage(date: "2026-11-03"), now: DayKey.date(from: "2026-11-03", calendar: careCalendar)!,
                     calendar: careCalendar, catalog: testCatalog)
        #expect(journey.letters.filter { $0.encounter != nil } == [letter])
    }

    @Test func firstDayHomeReplayPreservesPhotosRegistrationAndDailySyncAttempt() {
        var (journey, _) = engineState()
        journey.recordEncounter(encounterPhoto())
        journey.lastEncounterSyncDay = journey.openDate
        journey.encounterStaysByTrip = [1: EncounterStay(stayId: UUID().uuidString, cityId: "quanzhou", day: journey.openDate,
            endsAt: DayKey.date(from: journey.openDate)!.addingTimeInterval(6 * 3600),
            appearance: .init(species: "pigeon", stage: "teen"))]
        let before = journey
        journey.setStart("hangzhou", now: DayKey.date(from: journey.openDate)!, catalog: testCatalog)
        #expect(journey.homeCityId == "hangzhou")
        #expect(journey.encounterStaysByTrip == before.encounterStaysByTrip)
        #expect(journey.encounterPhotos == before.encounterPhotos)
        #expect(journey.lastEncounterSyncDay == before.lastEncounterSyncDay)
    }

    @Test func oldVersionEightSavesReadWithoutNewFields() throws {
        var (journey, _) = engineState()
        let data = try JSONEncoder().encode(journey)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["encounterPhotos", "encounterStaysByTrip", "lastEncounterSyncDay"] { object.removeValue(forKey: key) }
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(journey.version == 8 && journey.encounterPhotos == nil && journey.encounterStaysByTrip == nil)
        #expect(journey.letters.allSatisfy { $0.encounter == nil })
    }

    @Test func contentDrawIsStableBySeedAndCityAndRejectsMissingTranslationsAndMarkup() throws {
        let original = testCatalog.encounterPostcards.draw(seed: 17, cityID: "quanzhou")
        var reversed = testCatalog.encounterPostcards
        reversed.lines.reverse()
        #expect(reversed.draw(seed: 17, cityID: "quanzhou") == original)
        let sandbox = try ContentSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.edit("encounter-postcards.json") { object in
            var lines = object["lines"] as! [[String: Any]]
            lines[0]["texts"] = ["zh-Hans": "<script>坏文字</script>"]
            object["lines"] = lines
        }
        #expect(ContentValidator.validate(directory: sandbox.directory).contains { $0.rule == "encounterPostcards" })
    }

    @Test func catchUpAndReplaysKeepSavedTextWithoutChangingEarlierSettlements() throws {
        var (journey, _) = engineState()
        journey.recordEncounter(encounterPhoto(date: "2026-11-03"))
        journey.sync(today: DayUsage(date: "2026-11-05"), now: DayKey.date(from: "2026-11-05", calendar: careCalendar)!,
                     calendar: careCalendar, catalog: testCatalog)
        let photo = try #require(journey.letters.first { $0.encounter != nil })
        #expect(photo.date == "2026-11-03")
        let before = journey
        journey.sync(today: DayUsage(date: "2026-11-05"), now: DayKey.date(from: "2026-11-05", calendar: careCalendar)!,
                     calendar: careCalendar, catalog: testCatalog)
        #expect(journey == before)
    }
}
