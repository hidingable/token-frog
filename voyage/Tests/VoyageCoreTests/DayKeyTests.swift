import Foundation
import Testing
import VoyageCore

private func referenceDayFormatter(_ calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}

@Test(arguments: ["UTC", "America/Los_Angeles", "Europe/Berlin", "America/Sao_Paulo", "Pacific/Apia"])
func dayKeysMatchDateFormatterAcrossThousandsOfDates(timeZone: String) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    let formatter = referenceDayFormatter(calendar)
    let first = try #require(formatter.date(from: "2016-01-01"))
    for offset in 0..<4_000 {
        let date = try #require(calendar.date(byAdding: .day, value: offset, to: first))
        let key = formatter.string(from: date)
        let parsed = try #require(formatter.date(from: key))
        #expect(DayKey.string(from: date, calendar: calendar) == key)
        #expect(DayKey.date(from: key, calendar: calendar) == parsed)
        let ordinal = try #require(DayKey.ordinal(from: key, calendar: calendar))
        #expect(DayKey.ordinal(from: date, calendar: calendar) == ordinal)
        #expect(DayKey.date(forOrdinal: ordinal, calendar: calendar) == parsed)
        #expect(DayKey.string(forOrdinal: ordinal, calendar: calendar) == key)
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: parsed))
        #expect(DayKey.next(key, calendar: calendar) == formatter.string(from: next))
        #expect(DayKey.string(forOrdinal: ordinal + 1, calendar: calendar) == formatter.string(from: next))
        // Test formatting instants as well as local midnight, including both sides of DST changes.
        for hours in [-2.0, 12, 25] {
            let instant = date.addingTimeInterval(hours * 3_600)
            #expect(DayKey.string(from: instant, calendar: calendar) == formatter.string(from: instant))
        }
    }
}

@Test func dayKeysRejectMalformedAndImpossibleDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    for key in ["", "2026-1-01", "2026-01-1", " 2026-01-01", "2026-01-01 ", "2026/01/01", "2026-01-01T00:00:00Z", "２０２６-01-01", "202a-01-01", "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32", "2026-04-31", "2023-02-29", "1900-02-29", "0000-01-01", "-001-01-01"] {
        #expect(DayKey.date(from: key, calendar: calendar) == nil, "Accepted invalid day key: \(key)")
        #expect(DayKey.ordinal(from: key, calendar: calendar) == nil)
    }
    let formatter = referenceDayFormatter(calendar)
    for key in ["0001-01-01", "1900-02-28", "2000-02-29", "2024-02-29", "9999-12-31"] {
        let expected = try #require(formatter.date(from: key))
        #expect(DayKey.date(from: key, calendar: calendar) == expected)
        #expect(DayKey.string(from: expected, calendar: calendar) == key)
    }
    calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Apia"))
    #expect(DayKey.date(from: "2011-12-30", calendar: calendar) == nil)
    #expect(DayKey.next("2011-12-29", calendar: calendar) == "2011-12-31")
    let beforeSkip = try #require(DayKey.ordinal(from: "2011-12-29", calendar: calendar))
    #expect(DayKey.string(forOrdinal: beforeSkip + 1, calendar: calendar) == "2011-12-31")
}

@Test(arguments: [Calendar.Identifier.iso8601, .buddhist, .japanese, .persian, .hebrew])
func dayKeysPreserveTheSuppliedCalendar(identifier: Calendar.Identifier) throws {
    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let formatter = referenceDayFormatter(calendar)
    let first = Date(timeIntervalSince1970: 1_577_836_800)
    for offset in stride(from: 0, to: 3_000, by: 13) {
        let date = try #require(calendar.date(byAdding: .day, value: offset, to: first))
        let key = formatter.string(from: date)
        #expect(DayKey.string(from: date, calendar: calendar) == key)
        #expect(DayKey.date(from: key, calendar: calendar) == formatter.date(from: key))
    }
}

@Test(arguments: [("America/Sao_Paulo", "2018-10-25"), ("Pacific/Apia", "2011-12-24"), ("UTC", "0001-01-01"), ("UTC", "1582-10-01")])
func dayOrdinalsRemainConsecutiveAcrossCalendarBoundaries(timeZone: String, start: String) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    let formatter = referenceDayFormatter(calendar)
    var date = try #require(formatter.date(from: start))
    var ordinal = DayKey.ordinal(from: date, calendar: calendar)
    for _ in 0..<30 {
        let key = formatter.string(from: date)
        #expect(DayKey.date(from: key, calendar: calendar) == date)
        #expect(DayKey.date(forOrdinal: ordinal, calendar: calendar) == date)
        #expect(DayKey.ordinal(from: date, calendar: calendar) == ordinal)
        #expect(DayKey.string(forOrdinal: ordinal, calendar: calendar) == key)
        // Adding from the day itself avoids Foundation's non-invertible large day offsets near a date-line jump.
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: date))
        date = try #require(formatter.date(from: formatter.string(from: next)))
        ordinal += 1
    }
}

@Test func dayOrdinalRangeArithmeticMatchesCalendarAcrossADateLineJump() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Apia"))
    for (firstKey, lastKey) in [("2011-12-24", "2011-12-31"), ("2011-12-28", "2011-12-29"), ("2011-12-29", "2011-12-31"), ("2011-12-28", "2012-01-01"), ("2011-12-24", "2012-01-07")] {
        let first = try #require(DayKey.date(from: firstKey, calendar: calendar))
        let last = try #require(DayKey.date(from: lastKey, calendar: calendar))
        let firstOrdinal = DayKey.ordinal(from: first, calendar: calendar)
        let lastOrdinal = DayKey.ordinal(from: last, calendar: calendar)
        let count = lastOrdinal - firstOrdinal + 1
        #expect(count == calendar.dateComponents([.day], from: first, to: last).day! + 1)
        let previous = try #require(calendar.date(byAdding: .day, value: -count, to: first))
        #expect(DayKey.date(forOrdinal: firstOrdinal - count, calendar: calendar) == previous)
        let back = (calendar.component(.weekday, from: last) + 5) % 7
        let monday = try #require(calendar.date(byAdding: .day, value: -back, to: last))
        #expect(DayKey.date(forOrdinal: lastOrdinal - back, calendar: calendar) == monday)
    }
}
