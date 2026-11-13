/// The passport and identity settlement share canonical city visits and the regular threshold.
public struct CityStays: Equatable, Identifiable, Sendable {
    public let id: String
    public let count: Int
    public var isRegular: Bool { count >= 3 }

    public static func all(journey: JourneyState, catalog: CityCatalog) -> [CityStays] {
        var counts: [String: Int] = [:]
        var recent: [String: Int] = [:]
        for (index, id) in journey.route.enumerated() {
            let city = catalog.find(id)?.id ?? id
            counts[city, default: 0] += 1
            recent[city] = index
        }
        return counts.keys.sorted { recent[$0]! > recent[$1]! }.map {
            CityStays(id: $0, count: counts[$0]!)
        }
    }
}
