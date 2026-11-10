import Foundation
import Testing
@testable import VoyageCore

private let deliveryCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

@Test func deliveryTimePreferencesAcceptOnlyWholeOrHalfHours() {
    #expect(DeliveryTime.standard.rawValue == "09:00")
    #expect(DeliveryTime.allCases.count == 48)
    #expect(DeliveryTime(rawValue: "08:30") == DeliveryTime(hour: 8, minute: 30))
    for invalid in ["24:00", "09:15", "8:30", "-1:00", "09:60", "", "09:00:00"] {
        #expect(DeliveryTime(rawValue: invalid) == nil)
    }
}

@Test func configuredDeliveryTimeOnlyChangesLettersSettledAfterPreferenceChange() throws {
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: .distantPast, catalog: testCatalog)
    state.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01", fuel: 100)], now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: deliveryCalendar)!.addingTimeInterval(12 * 3600),
               calendar: deliveryCalendar, catalog: testCatalog)
    let oldLetter = try #require(state.letters.last)
    #expect(deliveryCalendar.component(.hour, from: oldLetter.deliverAt) == 9)
    #expect(deliveryCalendar.component(.minute, from: oldLetter.deliverAt) == 0)
    state.sync(today: DayUsage(date: "2026-11-03"), finalized: [DayUsage(date: "2026-11-02", fuel: 100)], now: DayKey.date(from: (DayUsage(date: "2026-11-03")).date, calendar: deliveryCalendar)!.addingTimeInterval(12 * 3600),
               calendar: deliveryCalendar, catalog: testCatalog, deliveryTime: DeliveryTime(rawValue: "08:30")!)
    let newLetter = try #require(state.letters.last)
    #expect(newLetter.id > oldLetter.id)
    #expect(DayKey.string(from: newLetter.deliverAt, calendar: deliveryCalendar) == "2026-11-03")
    #expect(deliveryCalendar.component(.hour, from: newLetter.deliverAt) == 8)
    #expect(deliveryCalendar.component(.minute, from: newLetter.deliverAt) == 30)
    #expect(state.letters.first(where: { $0.id == oldLetter.id }) == oldLetter)
}

@Test func deliveryTimeRemainsLocalAcrossDaylightSavingTransitions() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-10-31", now: .distantPast, catalog: testCatalog)
    state.sync(today: DayUsage(date: "2026-11-02"), finalized: [
        DayUsage(date: "2026-10-31", fuel: 100), DayUsage(date: "2026-11-01", fuel: 100),
    ], now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: calendar)!.addingTimeInterval(12 * 3600), calendar: calendar, catalog: testCatalog, deliveryTime: DeliveryTime(rawValue: "08:30")!)
    let deliveries = state.letters.filter { $0.kind == .daily }.map(\.deliverAt)
    #expect(deliveries.count == 2)
    #expect(deliveries.allSatisfy { calendar.component(.hour, from: $0) == 8 && calendar.component(.minute, from: $0) == 30 })
}
