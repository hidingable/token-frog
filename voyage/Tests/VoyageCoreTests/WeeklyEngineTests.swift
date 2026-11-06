import Foundation
import Testing
@testable import VoyageCore

private let weeklyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.firstWeekday = 1 // The locale's week preference must not override Monday.
    return calendar
}()

private func weeklyCare() -> CareState {
    CareState(petName: "Pip", species: .pigeon, hatchedAt: "2026-11-02", calendar: weeklyCalendar)
}

@Suite struct WeeklyEngineTests {
    @Test(arguments: [
        (0, Stage.egg, Stage.hatchling, 1), (1, .hatchling, .juvenile, 4),
        (4, .hatchling, .juvenile, 1), (5, .juvenile, .teen, 15),
        (19, .juvenile, .teen, 1), (20, .teen, .traveler, 40),
        (59, .teen, .traveler, 1), (60, .traveler, .veteran, 110),
        (169, .traveler, .veteran, 1), (170, .veteran, .legend, 170),
        (339, .veteran, .legend, 1),
    ])
    func stageBoundaries(days: Int, current: Stage, next: Stage, remaining: Int) {
        #expect(Stage.current(companionDays: days) == current)
        #expect(Stage.next(companionDays: days) == next)
        #expect(Stage.daysUntilNext(companionDays: days) == remaining)
    }

    @Test(arguments: [340, 500])
    func legendHasNoNextStage(days: Int) {
        #expect(Stage.current(companionDays: days) == .legend)
        #expect(Stage.next(companionDays: days) == nil)
        #expect(Stage.daysUntilNext(companionDays: days) == nil)
    }

    @Test(arguments: [(0, Habit.Band.none), (1, .emerging), (29, .emerging), (30, .growing), (59, .growing), (60, .established), (100, .established)])
    func habitBandsAreIndependentOfDisplayWording(value: Int, band: Habit.Band) {
        var habits = CareState.Habits()
        habits.talkative = value
        habits.observant = value
        #expect(Habit.talkative.band(in: habits) == band)
        #expect(Habit.observant.band(in: habits) == band)
    }

    @Test func exactlyFourAndSixStampsGrantBoxesAndSameDayNeverChangesAnything() {
        var care = weeklyCare()
        for day in 2...8 {
            let key = String(format: "2026-11-%02d", day)
            CareEngine.markCompanion(date: key, care: &care, calendar: weeklyCalendar)
            let count = day - 1
            #expect(care.weekly.stamps.count == count)
            let expected = count < 4 ? [] : count < 6 ? ["2026-11-02#4"] : ["2026-11-02#4", "2026-11-02#6"]
            #expect(care.weekly.boxes == expected)
            let saved = care
            CareEngine.markCompanion(date: key, care: &care, calendar: weeklyCalendar)
            #expect(care == saved)
        }
        // Removing an opened box must not let a repeated stamp recreate it.
        care.weekly.boxes = []
        let saved = care
        CareEngine.markCompanion(date: "2026-11-08", care: &care, calendar: weeklyCalendar)
        #expect(care == saved)
    }

    @Test func localSundayAndMondayResetOnlyStampsAndKeepUnopenedBoxes() throws {
        var care = weeklyCare()
        for day in 2...7 {
            CareEngine.markCompanion(date: String(format: "2026-11-%02d", day), care: &care, calendar: weeklyCalendar)
        }
        let sunday = try #require(ISO8601DateFormatter().date(from: "2026-11-09T04:59:59Z"))
        CareEngine.markCompanion(date: sunday, care: &care, calendar: weeklyCalendar)
        #expect(care.weekly.weekStart == "2026-11-02" && care.weekly.stamps.count == 7)
        let oldBoxes = care.weekly.boxes
        let oldDays = care.companionDays
        CareEngine.markCompanion(date: sunday.addingTimeInterval(1), care: &care, calendar: weeklyCalendar)
        #expect(care.weekly.weekStart == "2026-11-09")
        #expect(care.weekly.stamps == ["2026-11-09"])
        #expect(care.companionDays == oldDays + ["2026-11-09"])
        #expect(care.weekly.boxes == oldBoxes)
        CareEngine.markCompanion(date: "2026-11-23", care: &care, calendar: weeklyCalendar)
        #expect(care.weekly.stamps == ["2026-11-23"] && care.weekly.boxes == oldBoxes)
        #expect(care.companionDays.count == 9)
    }

    @Test func clockRollbackAndInvalidDatesDoNothing() {
        var care = weeklyCare()
        CareEngine.markCompanion(date: "2026-11-05", care: &care, calendar: weeklyCalendar)
        let saved = care
        for date in ["2026-11-04", "2026-11-01", "2026-10-01", "invalid", "2026-02-30"] {
            CareEngine.markCompanion(date: date, care: &care, calendar: weeklyCalendar)
            #expect(care == saved)
        }
        CareEngine.markCompanion(date: "2026-11-09", care: &care, calendar: weeklyCalendar)
        let monday = care
        CareEngine.markCompanion(date: "2026-11-08", care: &care, calendar: weeklyCalendar)
        #expect(care == monday)
    }

    @Test func firstCompanionDayUsesTheSameStampPath() {
        var care = weeklyCare()
        CareEngine.markCompanion(date: care.hatchedAt, care: &care, calendar: weeklyCalendar)
        #expect(care.companionDays == ["2026-11-02"])
        #expect(care.weekly.stamps == care.companionDays)
        #expect(Stage.current(companionDays: care.companionDays.count) == .hatchling)
    }

    @Test func openingFollowsSouvenirOrderRemovesBoxesAndRejectsUnknownIds() throws {
        var care = weeklyCare()
        let (journey, _) = engineState()
        let unknown = care
        #expect(CareEngine.openBox(id: "2026-11-02#6", care: &care, library: testCatalog.items, date: "2026-11-08", journey: journey) == nil)
        #expect(care == unknown)
        for (index, id) in testCatalog.items.boxes.souvenirIds.enumerated() {
            let monday = try #require(weeklyCalendar.date(byAdding: .day, value: index * 7, to: DayKey.date(from: "2026-11-02", calendar: weeklyCalendar)!))
            let boxId = "\(DayKey.string(from: monday, calendar: weeklyCalendar))#6"
            care.weekly.boxes.append(boxId)
            let result = CareEngine.openBox(id: boxId, care: &care, library: testCatalog.items, date: "2027-11-02", journey: journey, calendar: weeklyCalendar)
            #expect(result == .item(id: id, kind: "souvenir"))
            #expect(!care.weekly.boxes.contains(boxId))
            #expect(care.souvenirs.last == .init(id: id, letterId: nil, boxId: boxId, shelved: false))
            #expect(care.boxesOpened == index + 1 && care.boxItemIndex == index + 1)
            let after = care
            #expect(CareEngine.openBox(id: boxId, care: &care, library: testCatalog.items, date: "2027-11-02", journey: journey) == nil)
            #expect(care == after)
        }
        #expect(Set(care.souvenirs.map(\.id)).count == care.souvenirs.count)
        // Last letter by ID, even when the persisted array has a different order.
        var withLetters = journey
        withLetters.letters = [engineLetter(10), engineLetter(3)]
        withLetters.letters[0].cityId = "tokyo"
        care.weekly.boxes = ["2027-03-01#6", "2027-03-08#6"]
        #expect(CareEngine.openBox(id: "2027-03-01#6", care: &care, library: testCatalog.items, date: "2027-03-09", journey: withLetters) == .clue(cityId: "tokyo"))
        #expect(care.trailClues["tokyo"] == 1)
        withLetters.letters = []
        withLetters.currentCityId = "xian"
        #expect(CareEngine.openBox(id: "2027-03-08#6", care: &care, library: testCatalog.items, date: "2027-03-09", journey: withLetters) == .clue(cityId: "xian"))
        #expect(care.trailClues["xian"] == 1)
        #expect(care.boxesOpened == testCatalog.items.boxes.souvenirIds.count + 2)
    }

    @Test func fourthAndEighthWeeksGrantBagsTwelfthFallsBackAndSixthStampsNeverGrantBags() {
        var care = weeklyCare()
        let (journey, _) = engineState()
        // Hatch on Sunday: week number still counts from that week's Monday.
        care.hatchedAt = "2026-11-08"
        let ids = ["2026-11-16#4", "2026-11-23#6", "2026-11-23#4", "2026-12-21#6", "2026-12-21#4", "2027-01-18#4"]
        care.weekly.boxes = ids
        let souvenirs = testCatalog.items.boxes.souvenirIds
        let expected: [BoxResult] = [
            .item(id: souvenirs[0], kind: "souvenir"), .item(id: souvenirs[1], kind: "souvenir"),
            .item(id: "old-camera", kind: "bag"), .item(id: souvenirs[2], kind: "souvenir"),
            .item(id: "lunchbox", kind: "bag"), .item(id: souvenirs[3], kind: "souvenir"),
        ]
        for (id, result) in zip(ids, expected) {
            #expect(CareEngine.openBox(id: id, care: &care, library: testCatalog.items, date: "2027-05-01", journey: journey, calendar: weeklyCalendar) == result)
        }
        #expect(care.bag.owned.suffix(2) == ["old-camera", "lunchbox"])
        #expect(care.boxesOpened == 6 && care.boxItemIndex == 4)
        #expect(care.weekly.boxes.isEmpty)
    }

    @Test func boxInventorySkipsAlreadyOwnedBagsAndSouvenirs() {
        var care = weeklyCare()
        let (journey, _) = engineState()
        care.bag.owned.append("old-camera")
        let first = testCatalog.items.boxes.souvenirIds[0]
        care.souvenirs = [.init(id: first, letterId: nil, boxId: "2026-11-02#6", shelved: false)]
        care.weekly.boxes = ["2026-11-23#4", "2026-11-23#6"]
        #expect(CareEngine.openBox(id: "2026-11-23#4", care: &care, library: testCatalog.items, date: "2026-11-29", journey: journey) == .item(id: "lunchbox", kind: "bag"))
        #expect(CareEngine.openBox(id: "2026-11-23#6", care: &care, library: testCatalog.items, date: "2026-11-29", journey: journey) == .item(id: testCatalog.items.boxes.souvenirIds[1], kind: "souvenir"))
        #expect(care.boxItemIndex == 2)
    }

    @Test func shelfCapacityFailureLeavesEverythingUnchangedAndUnshelvingFreesSpace() {
        var care = weeklyCare()
        care.souvenirs = (0..<5).map { (index: Int) in .init(id: "item.\(index)", letterId: index, shelved: false) }
        for index in 0..<4 { #expect(CareEngine.setShelved(id: "item.\(index)", shelved: true, care: &care)) }
        let full = care
        #expect(!CareEngine.setShelved(id: "item.4", shelved: true, care: &care))
        #expect(care == full)
        #expect(CareEngine.setShelved(id: "item.0", shelved: true, care: &care))
        #expect(care == full)
        #expect(CareEngine.setShelved(id: "item.0", shelved: false, care: &care))
        #expect(CareEngine.setShelved(id: "item.4", shelved: true, care: &care))
        #expect(care.souvenirs.filter(\.shelved).count == 4)
        #expect(CareEngine.setShelved(id: "missing", shelved: false, care: &care))
        #expect(!CareEngine.setShelved(id: "missing", shelved: true, care: &care))
    }
}
