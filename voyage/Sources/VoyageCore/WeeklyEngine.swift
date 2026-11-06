import Foundation

enum WeeklyEngine {
    static func weekStart(for key: String, calendar: Calendar) -> String? {
        guard let date = DayKey.date(from: key, calendar: calendar),
              DayKey.string(from: date, calendar: calendar) == key else { return nil }
        let daysSinceMonday = (calendar.component(.weekday, from: date) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: date) else { return nil }
        return DayKey.string(from: monday, calendar: calendar)
    }

    static func isBagWeek(_ weekStart: String, hatchedAt: String, calendar: Calendar) -> Bool {
        guard let hatchWeek = self.weekStart(for: hatchedAt, calendar: calendar),
              let hatch = DayKey.date(from: hatchWeek, calendar: calendar),
              let week = DayKey.date(from: weekStart, calendar: calendar),
              let days = calendar.dateComponents([.day], from: hatch, to: week).day else { return false }
        return days >= 21 && (days / 7) % 4 == 3
    }
}

public enum BoxResult: Equatable, Sendable {
    case item(id: String, kind: String)
    case clue(cityId: String)
}

extension CareEngine {
    public static func markCompanion(date: String, care: inout CareState, calendar: Calendar = .current) {
        guard let weekStart = WeeklyEngine.weekStart(for: date, calendar: calendar),
              date >= care.hatchedAt, date >= care.weekly.weekStart,
              date >= (care.companionDays.max() ?? care.hatchedAt),
              !care.companionDays.contains(date) else { return }
        if care.weekly.weekStart != weekStart {
            care.weekly.weekStart = weekStart
            care.weekly.stamps = []
        }
        care.companionDays.append(date)
        care.weekly.stamps.append(date)
        if [4, 6].contains(care.weekly.stamps.count) {
            let id = "\(weekStart)#\(care.weekly.stamps.count)"
            if !care.weekly.boxes.contains(id) { care.weekly.boxes.append(id) }
        }
    }

    public static func markCompanion(date: Date, care: inout CareState, calendar: Calendar = .current) {
        markCompanion(date: DayKey.string(from: date, calendar: calendar), care: &care, calendar: calendar)
    }

    /// Entitlement belongs to the stamped week, so opening later cannot change its reward.
    public static func openBox(
        id: String, care: inout CareState, library: ItemLibrary, date _: String,
        journey: JourneyState, calendar: Calendar = .current
    ) -> BoxResult? {
        guard let index = care.weekly.boxes.firstIndex(of: id) else { return nil }
        let parts = id.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, ["4", "6"].contains(parts[1]),
              let weekStart = WeeklyEngine.weekStart(for: String(parts[0]), calendar: calendar),
              weekStart == parts[0] else { return nil }

        let result: BoxResult
        if parts[1] == "4", WeeklyEngine.isBagWeek(weekStart, hatchedAt: care.hatchedAt, calendar: calendar),
           let bag = library.boxes.bagItemIds.first(where: { !care.bag.owned.contains($0) }) {
            care.bag.owned.append(bag)
            result = .item(id: bag, kind: "bag")
        } else {
            // Skip already owned entries as well as the persisted cursor: rewards never repeat.
            while care.boxItemIndex < library.boxes.souvenirIds.count,
                  care.souvenirs.contains(where: { $0.id == library.boxes.souvenirIds[care.boxItemIndex] }) {
                care.boxItemIndex += 1
            }
            if care.boxItemIndex < library.boxes.souvenirIds.count {
                let item = library.boxes.souvenirIds[care.boxItemIndex]
                care.souvenirs.append(.init(id: item, letterId: nil, boxId: id, shelved: false))
                care.boxItemIndex += 1
                result = .item(id: item, kind: "souvenir")
            } else {
                let city = journey.letters.max { $0.id < $1.id }?.cityId ?? journey.currentCityId
                care.trailClues[city, default: 0] += 1
                result = .clue(cityId: city)
            }
        }
        care.weekly.boxes.remove(at: index)
        care.boxesOpened += 1
        return result
    }

    @discardableResult
    public static func setShelved(id: String, shelved: Bool, care: inout CareState) -> Bool {
        guard let index = care.souvenirs.firstIndex(where: { $0.id == id }) else { return !shelved }
        if shelved && !care.souvenirs[index].shelved
            && care.souvenirs.filter(\.shelved).count >= CareRules.shelfCapacity { return false }
        care.souvenirs[index].shelved = shelved
        return true
    }
}
