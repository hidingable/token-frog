import Foundation
import Testing
@testable import VoyageCore

@Suite struct HomeFloorTests {
    @Test func homecomingCapturesTheTripAndSurvivesPendingUntilTheNextDeparture() throws {
        let start = DayKey.date(from: "2026-11-01", calendar: careCalendar)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: start, catalog: testCatalog)
        let destination = journey.targetCityId
        let distance = journey.homeCoordinate.distanceKm(to: journey.legTo)
        let outward = journey.legCost
        let returning = max(returnTokensPerKm, Int(distance * Double(returnTokensPerKm)))
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward), now: start, calendar: careCalendar, catalog: testCatalog)
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward + returning),
                     now: start.addingTimeInterval(6 * 3600), calendar: careCalendar, catalog: testCatalog)
        let homecoming = try #require(journey.homecoming)
        #expect(journey.phase == .home && journey.tripCount == 1)
        #expect(homecoming.cityId == destination && homecoming.tripNumber == 1)
        #expect(homecoming.distanceKm == distance && homecoming.medianKm == 300)
        #expect(journey.days[journey.openDate]?.tripNumber == 1)
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward + returning + 1),
                     now: start.addingTimeInterval(7 * 3600), calendar: careCalendar, catalog: testCatalog)
        #expect(journey.phase == .pending && journey.homecoming == homecoming)
        journey.departNow(now: start.addingTimeInterval(7 * 3600), calendar: careCalendar, catalog: testCatalog)
        #expect(journey.homecoming == nil)
    }

    @Test func laterPendingUsageKeepsRewardsWithTheLastStayOfTheDay() throws {
        let start = DayKey.date(from: "2026-11-01", calendar: careCalendar)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: start, catalog: testCatalog)
        let outward = journey.legCost
        let returning = max(returnTokensPerKm, Int(journey.legTo.distanceKm(to: journey.homeCoordinate) * Double(returnTokensPerKm)))
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward), now: start, calendar: careCalendar, catalog: testCatalog)
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward + returning),
                     now: start.addingTimeInterval(6 * 3600), calendar: careCalendar, catalog: testCatalog)
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: outward + returning + 1),
                     now: start.addingTimeInterval(7 * 3600), calendar: careCalendar, catalog: testCatalog)
        #expect(journey.phase == .pending && journey.days[journey.openDate]?.tripNumber == 1)
        journey.sync(today: DayUsage(date: "2026-11-02"),
                     finalized: [DayUsage(date: "2026-11-01", observedTokens: outward + returning + 1)],
                     now: start.addingTimeInterval(86400), calendar: careCalendar, catalog: testCatalog)
        let letter = try #require(journey.letters.last)
        #expect(letter.kind == .daily && letter.tripNumber == 1 && !letter.arrivals.isEmpty)
    }

    @Test func optionalFloorFieldsLoadOldSavesAndOpenedParcelsRoundTrip() throws {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
        journey.homecoming = Homecoming(tripNumber: 1, cityId: "hangzhou", returnedAt: journey.phaseSince, distanceKm: 170, medianKm: 300)
        journey.homecoming?.openedParcelIDs = ["1:souvenir:test"]
        journey.days[journey.openDate] = DayRecord()
        journey.days[journey.openDate]?.tripNumber = 1
        let saved = try JSONEncoder().encode(journey)
        #expect(try JSONDecoder().decode(JourneyState.self, from: saved) == journey)
        var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "homecoming")
        var days = object["days"] as! [String: [String: Any]]
        days[journey.openDate]?.removeValue(forKey: "tripNumber")
        object["days"] = days
        let old = try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.version == JourneyState.currentVersion && old.homecoming == nil)
        #expect(old.days[journey.openDate]?.tripNumber == nil && old.letters.allSatisfy { $0.tripNumber == nil })
    }

    @Test func settledLettersRetainTripProvenanceAndDuplicateCluesHaveNoParcel() throws {
        let start = DayKey.date(from: "2026-11-01", calendar: careCalendar)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: start, catalog: testCatalog)
        journey.sync(today: DayUsage(date: journey.openDate, observedTokens: 1), now: start, calendar: careCalendar, catalog: testCatalog)
        journey.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01", observedTokens: 1)],
                     now: start.addingTimeInterval(86400), calendar: careCalendar, catalog: testCatalog)
        let letter = try #require(journey.letters.last)
        #expect(letter.kind == .daily && letter.tripNumber == 1)
        journey.phase = .home
        journey.homecoming = Homecoming(tripNumber: 1, cityId: "hangzhou", returnedAt: start, distanceKm: 170, medianKm: 300)
        var care = CareState(petName: "Ginkgo", species: journey.pet, hatchedAt: journey.startDate)
        care.trailClues["hangzhou"] = 1
        #expect(HomeFloor.parcels(journey: journey, care: care).isEmpty)
        care.souvenirs = [.init(id: "old-item", letterId: 0, shelved: false), .init(id: "new-item", letterId: letter.id, shelved: false)]
        #expect(HomeFloor.parcels(journey: journey, care: care).map(\.itemID) == ["new-item"])
        #expect(!HomeFloor.openParcel("unknown", journey: &journey, care: care))
    }
}
