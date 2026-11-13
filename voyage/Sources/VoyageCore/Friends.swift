import Foundation

/// Written with the letter before care.json; replay never draws again or consults revised copy.
public struct FriendSettlement: Codable, Equatable, Sendable {
    public let threshold: Int
    public let friendId: String
    public let cityId: String?
    public let names: [String: String]
}

public enum FriendRules {
    public static func latestThreshold(companionDays: Int) -> Int? {
        companionDays < 6 ? nil : 6 + (companionDays - 6) / 21 * 21
    }

    public static func choose(unmetIDs: [String], seed: UInt32, threshold: Int) -> String? {
        let candidates = unmetIDs.sorted()
        guard !candidates.isEmpty else { return nil }
        var random = SplitMix64(seed: seed, stopCount: threshold, salt: .friend)
        return candidates[Int(random.next() % UInt64(candidates.count))]
    }

    /// A seeded starting note followed by one step per local date, independent of visits or scans.
    public static func noteIndex(seed: UInt32, friendId: String, date: String, count: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Int(DayKey.date(from: date, calendar: calendar)!.timeIntervalSince1970 / 86_400)
        var random = SplitMix64(seed: seed, stopCount: 0, salt: .friendNote)
        for byte in friendId.utf8 { random.state = (random.state ^ UInt64(byte)) &* 0x100_0000_01B3 }
        let offset = Int(random.next() % UInt64(count))
        return ((day % count + offset) % count + count) % count
    }
}

extension CareEngine {
    static func settleFriend(
        journey: inout JourneyState, care: inout CareState, catalog: CityCatalog,
        date: String, calendar: Calendar, deliveryTime: DeliveryTime, gate: JourneyGate
    ) {
        var met = care.metFriends ?? []
        var settled = care.settledFriendThresholds ?? []
        for letter in journey.letters.filter({ $0.kind == .adventure }).sorted(by: { $0.id < $1.id }) {
            guard let snapshot = letter.friendSettlement else { continue }
            if !settled.contains(snapshot.threshold) { settled.append(snapshot.threshold) }
            if !met.contains(where: { $0.id == snapshot.friendId }) {
                met.append(.init(id: snapshot.friendId, date: letter.date, cityId: snapshot.cityId, letterId: letter.id))
            }
        }
        // Leave absent fields absent on old saves until there is an actual meeting to remember.
        if !met.isEmpty { care.metFriends = met }
        if !settled.isEmpty { care.settledFriendThresholds = settled }
        guard journey.allowsNewMail(on: date, gate: gate, calendar: calendar),
              let threshold = FriendRules.latestThreshold(companionDays: care.companionDays.count),
              threshold > (settled.max() ?? 0),
              let id = FriendRules.choose(unmetIDs: catalog.friends.friends.map(\.id).filter { id in !met.contains { $0.id == id } },
                                          seed: journey.seed, threshold: threshold),
              let nextDay = DayKey.date(from: DayKey.next(date, calendar: calendar), calendar: calendar),
              let deliverAt = calendar.date(bySettingHour: deliveryTime.hour, minute: deliveryTime.minute, second: 0, of: nextDay) else { return }
        let friend = catalog.friends.friends.first { $0.id == id }!
        let cityId = journey.route.last
        var letter = Letter(id: journey.nextLetterID, kind: .adventure, date: date, pet: journey.pet,
                            cityId: cityId ?? journey.homeCityId, arrivals: [], newCountries: [], fuel: 0, vehicles: [],
                            isDeepVisit: false, deliverAt: deliverAt, enrichmentDone: true)
        letter.friendSettlement = FriendSettlement(threshold: threshold, friendId: id, cityId: cityId, names: friend.name)
        letter.storyVersion = catalog.friends.version
        letter.texts = friend.letters[cityId == nil ? "noCity" : "city"]!.reduce(into: [:]) { result, entry in
            let cityNames = cityId.map { catalog.city($0).names } ?? [:]
            result[entry.key] = StorySlots.render(entry.value, values: ["pet": care.petName,
                "city": cityNames[entry.key] ?? cityNames["en"] ?? cityNames["zh-Hans"] ?? ""])
        }
        journey.letters.append(letter)
        care.metFriends = met + [.init(id: id, date: date, cityId: cityId, letterId: letter.id)]
        // Only the latest passed threshold is consumed: legacy saves never receive a backlog.
        care.settledFriendThresholds = settled + [threshold]
    }
}
