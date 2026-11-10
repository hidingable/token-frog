import Foundation

/// Derived entirely from the journey and memory book; never persisted.
public struct Footprints: Equatable, Sendable {
    public struct Count: Equatable, Sendable {
        public let cityId: String
        public let count: Int
    }
    public struct Distance: Equatable, Sendable {
        public let cityId: String
        public let km: Double
    }
    public let mostVisited: Count
    public let farthest: Distance?
    public let mostMemorable: Count?

    public init(journey: JourneyState, care: CareState?, catalog: CityCatalog, now: Date) {
        func canonical(_ id: String) -> String { catalog.find(id)?.id ?? id }
        let home = canonical(journey.homeCityId)
        // Imported letter IDs need not be unique. Resolve them the same way as the memory book.
        let letters = Dictionary(journey.letters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visits: [String: Int] = [:]
        var memories: [String: Int] = [:]
        var lastVisit: [String: String] = [:]
        var lastMemory: [String: String] = [:]
        func recency(date: String, letterId: Int) -> String {
            date + String(format: ":%020lld", Int64(letterId))
        }
        for (index, id) in journey.route.enumerated() {
            let city = canonical(id)
            visits[city, default: 0] += 1
            lastVisit[city] = String(format: "%020lld", Int64(index))
        }
        func addMemory(date: String, letterId: Int?) {
            guard let letterId, let letter = letters[letterId], letter.deliverAt <= now else { return }
            let city = canonical(letter.cityId)
            memories[city, default: 0] += 1
            lastMemory[city] = max(lastMemory[city] ?? "", recency(date: date, letterId: letterId))
        }
        if let care {
            for memory in care.memories where ["reply", "fulfilled"].contains(memory.kind) {
                addMemory(date: memory.date, letterId: memory.letterId)
            }
            for day in care.specialDays { addMemory(date: day.date, letterId: day.letterId) }
        }
        func winner(_ counts: [String: Int], recent: [String: String]) -> Count? {
            counts.keys.sorted {
                if counts[$0] != counts[$1] { return counts[$0]! > counts[$1]! }
                if recent[$0] != recent[$1] { return recent[$0]! > recent[$1]! }
                return $0 < $1
            }.first.map { Count(cityId: $0, count: counts[$0]!) }
        }
        mostVisited = winner(visits, recent: lastVisit) ?? Count(cityId: home, count: 0)
        mostMemorable = winner(memories, recent: lastMemory)

        // Unknown cities have no usable coordinates; a placeholder's (0, 0) is not a real location.
        var distant: Distance?
        if catalog.find(home) != nil {
            for id in journey.route {
                guard let city = catalog.find(id), city.id != home else { continue }
                let km = journey.homeCoordinate.distanceKm(to: city.coordinate)
                // Route order breaks equal distances in favour of the most recent arrival.
                if km > 0, km >= (distant?.km ?? 0) { distant = Distance(cityId: city.id, km: km) }
            }
        }
        farthest = distant
    }
}
