import Foundation

/// A semantic introduction to the local usage history. These observations never become journey fuel.
public struct Logbook: Codable, Equatable, Sendable {
    public static let weekendQuietThreshold = 25

    public var workdayStartHour: Int?
    public var weekendActivePercent: Int?
    public var topClients: [String]

    public init(workdayStartHour: Int?, weekendActivePercent: Int?, topClients: [String]) {
        self.workdayStartHour = workdayStartHour
        self.weekendActivePercent = weekendActivePercent
        self.topClients = topClients
    }

    public var isWeekendQuiet: Bool? {
        weekendActivePercent.map { $0 <= Self.weekendQuietThreshold }
    }

    /// `days` includes inactive days at the ends of the requested range.
    public static func summarize(days: [DayDetail], hours: [HourUsage], calendar: Calendar) -> Logbook? {
        guard let start = days.map(\.date).min(), let end = days.map(\.date).max(),
              var date = DayKey.date(from: start, calendar: calendar),
              let lastDate = DayKey.date(from: end, calendar: calendar) else { return nil }

        let activeHours = hours.filter {
            $0.date >= start && $0.date <= end && (0..<24).contains($0.hour) && $0.tokens.total > 0
        }
        let activeDays = Set(days.filter { $0.rows.contains { $0.tokens.total > 0 } }.map(\.date))
            .union(activeHours.map(\.date))
        guard !activeDays.isEmpty else { return nil }

        var weekendDays = 0
        var activeWeekendDays = 0
        while date <= lastDate {
            if calendar.isDateInWeekend(date) {
                weekendDays += 1
                if activeDays.contains(DayKey.string(from: date, calendar: calendar)) { activeWeekendDays += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }

        var firstHours: [String: Int] = [:]
        for hour in activeHours {
            guard let day = DayKey.date(from: hour.date, calendar: calendar), !calendar.isDateInWeekend(day) else { continue }
            firstHours[hour.date] = min(firstHours[hour.date] ?? hour.hour, hour.hour)
        }
        let starts = firstHours.values.sorted()

        var fuelByClient: [String: Int] = [:]
        for day in days {
            for row in day.rows where row.tokens.fuel > 0 {
                fuelByClient[row.client, default: 0] += row.tokens.fuel
            }
        }
        let topClients = fuelByClient.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(2).map(\.key)

        return Logbook(
            workdayStartHour: starts.isEmpty ? nil : starts[starts.count / 2],
            weekendActivePercent: weekendDays == 0 ? nil : Int((Double(activeWeekendDays) / Double(weekendDays) * 100).rounded()),
            topClients: topClients
        )
    }
}
