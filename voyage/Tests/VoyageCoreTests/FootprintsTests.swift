import Foundation
import Testing
@testable import VoyageCore

@Suite struct FootprintsTests {
    private func footprints(_ journey: JourneyState, _ care: CareState? = nil, catalog: CityCatalog = testCatalog) -> Footprints {
        Footprints(journey: journey, care: care, catalog: catalog, now: .distantFuture)
    }

    @Test func emptyStateUsesHomeAndDoesNotWriteAnything() throws {
        let (journey, care) = engineState()
        let original = try JSONEncoder().encode(journey)
        let result = footprints(journey, care)
        #expect(result.mostVisited.cityId == "shanghai" && result.mostVisited.count == 0)
        #expect(result.farthest == nil && result.mostMemorable == nil)
        #expect(footprints(journey, care) == result)
        #expect(try JSONDecoder().decode(JourneyState.self, from: original) == journey)
    }

    @Test func stopsAreSelectedDailyCitiesRatherThanPassThroughsTransitOrCompanionMail() {
        var (journey, _) = engineState()
        journey.route = ["shanghai", "xian", "xian", "xian", "quanzhou", "quanzhou", "fukuoka"]
        journey.letters = [engineLetter(1, arrivals: ["xian", "quanzhou"], date: "2026-11-02", cityId: "quanzhou"),
                           engineLetter(2, date: "2026-11-03", cityId: "quanzhou"),
                           engineLetter(3, date: "2026-11-04", cityId: "fukuoka"),
                           engineLetter(4, arrivals: [], cityId: "xian")]
        var postcard = engineLetter(5, cityId: "xian"); postcard.kind = .postcard
        journey.letters += [postcard, postcard, journey.letters[0]]
        let result = footprints(journey)
        #expect(result.mostVisited.cityId == "quanzhou" && result.mostVisited.count == 2)
        let expected = ["xian", "quanzhou", "fukuoka"].max {
            testCatalog.city("shanghai").coordinate.distanceKm(to: testCatalog.city($0).coordinate)
                < testCatalog.city("shanghai").coordinate.distanceKm(to: testCatalog.city($1).coordinate)
        }
        #expect(result.farthest?.cityId == expected)
    }

    @Test func equalVisitCountsUseLatestDateThenLetterIdRegardlessOfArrayOrder() {
        var (journey, _) = engineState()
        journey.letters = [engineLetter(9, date: "2026-11-02", cityId: "quanzhou"),
                           engineLetter(2, date: "2026-11-03", cityId: "fukuoka")]
        #expect(footprints(journey).mostVisited.cityId == "fukuoka")
        journey.letters[0].date = "2026-11-03"
        #expect(footprints(journey).mostVisited.cityId == "quanzhou")
        let result = footprints(journey)
        journey.letters.reverse()
        #expect(footprints(journey) == result)
    }

    @Test func memoryBookCountsRepliesFulfillmentsAndLocatedSpecialDaysWithRecentTieBreak() {
        var (journey, care) = engineState()
        journey.letters = [engineLetter(1, cityId: "xian"), engineLetter(2, cityId: "quanzhou")]
        care.memories = [.init(kind: "reply", date: "2026-11-02", letterId: 1, replyId: "ask-next-time"),
                         .init(kind: "fulfilled", date: "2026-11-03", letterId: 1, replyId: "ask-next-time"),
                         .init(kind: "reply", date: "2026-11-04", letterId: 2, replyId: "look-closer"),
                         .init(kind: "future-kind", date: "2026-11-05", letterId: 2),
                         .init(kind: "reply", date: "2026-11-05", letterId: 999)]
        #expect(footprints(journey, care).mostMemorable == .init(cityId: "xian", count: 2))
        care.specialDays = [.init(kind: .firstLetter, date: "2026-11-04", letterId: 2),
                            .init(kind: .hundredDays, date: "2026-11-06")]
        #expect(footprints(journey, care).mostMemorable == .init(cityId: "quanzhou", count: 2))
        let result = footprints(journey, care)
        care.memories.reverse(); care.specialDays.reverse(); journey.letters.reverse()
        #expect(footprints(journey, care) == result)
        // Undelivered references do not yet appear in the memory book.
        journey.letters[0].deliverAt = .distantFuture
        let visible = Footprints(journey: journey, care: care, catalog: testCatalog, now: .distantPast)
        #expect(visible.mostMemorable == nil)
    }

    @Test func unknownCitiesRemainInCountsButNeverUsePlaceholderCoordinates() {
        var (journey, care) = engineState()
        journey.route += ["missing-city"]
        journey.letters = [engineLetter(1, cityId: "missing-city"), engineLetter(1, cityId: "xian")]
        care.memories = [.init(kind: "reply", date: "2026-11-02", letterId: 1)]
        let result = footprints(journey, care)
        #expect(result.mostVisited.cityId == "missing-city")
        #expect(result.mostMemorable?.cityId == "missing-city")
        #expect(testCatalog.city(result.mostVisited.cityId).isPlaceholder)
        #expect(result.farthest == nil)
        journey.route[0] = "missing-home"
        journey.route.append("xian")
        #expect(footprints(journey).farthest == nil)
    }

    @Test func retiredCitiesAndAliasesStillParticipate() throws {
        let box = try ContentSandbox(); defer { box.cleanUp() }
        try box.edit("cities/xian.json") { $0["status"] = "retired" }
        let catalog = try CityCatalog.load(directory: box.directory)
        var (journey, care) = engineState()
        let alias = try #require(catalog.city("xian").wikidata)
        journey.route += [alias, "xian"]
        journey.letters = [engineLetter(1, cityId: alias), engineLetter(2, cityId: "xian")]
        care.memories = [.init(kind: "reply", date: "2026-11-02", letterId: 1)]
        let result = footprints(journey, care, catalog: catalog)
        #expect(result.mostVisited == .init(cityId: "xian", count: 2))
        #expect(result.farthest?.cityId == "xian" && result.farthest!.km > 0)
        #expect(result.mostMemorable?.cityId == "xian")
    }
}
