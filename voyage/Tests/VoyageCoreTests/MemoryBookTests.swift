import Foundation
import Testing
@testable import VoyageCore

@Suite struct MemoryBookTests {
    @Test func oldCareDecodesAndBackfillsWithoutChangingProgressOrRewards() throws {
        let fixture = try #require(Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures"))
        var care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture))
        #expect(care.specialDays.isEmpty)
        #expect(care.memories.first?.replyId == "ask-next-time")
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: care.hatchedAt,
                                   now: .distantPast, catalog: testCatalog)
        journey.letters.append(engineLetter(1, date: "2026-11-07"))
        let original = care
        let originalJourney = journey
        MemoryBook.backfill(journey: journey, care: &care)
        #expect(care.specialDays.map(\.kind) == [.hatched, .firstLetter])
        #expect(care.specialDays.map(\.letterId) == [0, 1])
        #expect(care.specialDays.map(\.date) == ["2026-11-06", "2026-11-07"])
        let complete = care
        for _ in 0..<3 { MemoryBook.backfill(journey: journey, care: &care) }
        #expect(care == complete && journey == originalJourney)
        care.specialDays = []
        #expect(care == original)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(complete)) == complete)
    }

    @Test func hundredthCompanionDayUsesTheRecordedDayAndDoesNotIssueRewards() {
        let (journey, initial) = engineState()
        var care = initial
        var date = care.hatchedAt
        for _ in 0..<99 {
            CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar)
            date = DayKey.next(date, calendar: careCalendar)
        }
        #expect(care.specialDays.isEmpty)
        CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar)
        let milestone = care.specialDays.first
        #expect(milestone?.kind == .hundredDays && milestone?.date == date && milestone?.letterId == nil)
        let before = care
        MemoryBook.backfill(journey: journey, care: &care)
        #expect(care.specialDays.filter { $0.kind == .hundredDays }.count == 1)
        care.specialDays = before.specialDays
        #expect(care == before)
        // An existing 100-day save gets the same date, without re-marking days or boxes.
        care.specialDays = []
        MemoryBook.backfill(journey: journey, care: &care)
        #expect(care.specialDays.first { $0.kind == .hundredDays } == milestone)
        care.specialDays = before.specialDays
        #expect(care == before)
    }

    @Test func processingAlreadySettledLettersOnlyBackfillsReferences() throws {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        let originalJourney = journey
        care.specialDays = []
        let original = care
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        let complete = care
        #expect(complete.specialDays.count == 2)
        CareEngine.process(journey: &journey, care: &care, stories: .init(stories: []), catalog: testCatalog)
        #expect(care == complete && journey == originalJourney)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(care)) as? [String: Any])
        let records = try #require(json["specialDays"] as? [[String: Any]])
        #expect(records.allSatisfy { Set($0.keys).isSubset(of: ["kind", "date", "letterId"]) })
        care.specialDays = []
        #expect(care == original)
    }
}
