import Foundation
import VoyageCore

/// The route records stays, including those that did not produce a daily letter.
struct PassportDisplay {
    struct CityStay: Equatable, Identifiable {
        let id: String
        let countryCode: String
        let count: Int
        let letterID: Int?
        var isRegular: Bool { count >= 3 }

        func summary(l10n: L10n) -> String {
            let stays = l10n(count == 1 ? "footprints.stay" : "footprints.stays", Format.grouped(count))
            return isRegular ? l10n("passport.regularStay", stays) : stays
        }
    }

    let cities: [CityStay]

    init(journey: JourneyState, catalog: CityCatalog, now: Date) {
        func canonical(_ id: String) -> String { catalog.find(id)?.id ?? id }
        var counts: [String: Int] = [:]
        var recent: [String: Int] = [:]
        for (index, id) in journey.route.enumerated() {
            let city = canonical(id)
            counts[city, default: 0] += 1
            recent[city] = index
        }
        cities = counts.keys.sorted { recent[$0]! > recent[$1]! }.map { id in
            let letter = journey.letters.filter {
                $0.deliverAt <= now && (canonical($0.cityId) == id || $0.arrivals.contains { canonical($0) == id })
            }.max { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            return CityStay(id: id, countryCode: catalog.city(id).countryCode, count: counts[id]!, letterID: letter?.id)
        }
    }
}
