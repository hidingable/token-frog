import Foundation

/// Optional presentation state: absent in older saves, and discarded on the next departure.
public struct Homecoming: Codable, Equatable, Sendable {
    public var tripNumber: Int
    public var cityId: String
    public var returnedAt: Date
    public var distanceKm: Double
    public var medianKm: Double
    public var openedParcelIDs: [String] = []

    public init(tripNumber: Int, cityId: String, returnedAt: Date, distanceKm: Double, medianKm: Double) {
        self.tripNumber = tripNumber
        self.cityId = cityId
        self.returnedAt = returnedAt
        self.distanceKm = distanceKm
        self.medianKm = medianKm
    }
}

public enum HomeFloor {
    public struct Parcel: Equatable, Identifiable, Sendable {
        public var itemID: String
        public var letterID: Int
        public var kind: String
        public var id: String { "\(letterID):\(kind):\(itemID)" }
    }

    /// Only actual acquisitions, including menus; duplicates converted to clues are not parcels.
    /// Rewards remain in care from settlement onwards, even if the parcel is never opened.
    public static func parcels(journey: JourneyState, care: CareState) -> [Parcel] {
        guard journey.petIsHome, let homecoming = journey.homecoming else { return [] }
        let letters = Set(journey.letters.filter { $0.kind == .daily && $0.tripNumber == homecoming.tripNumber }.map(\.id))
        return care.souvenirs.compactMap { item in
            item.letterId.flatMap { letters.contains($0) ? Parcel(itemID: item.id, letterID: $0, kind: "souvenir") : nil }
        } + care.menus.compactMap { item in
            letters.contains(item.letterId) ? Parcel(itemID: item.id, letterID: item.letterId, kind: "menu") : nil
        }
    }

    /// Independent salt: never advances a care, drop, or destination random stream.
    public static func looseBoardRoll(seed: UInt32, tripCount: Int) -> UInt64 {
        var random = SplitMix64(seed: seed, stopCount: tripCount, salt: .looseBoard)
        return random.next()
    }

    public static func rugColorIndex(cityID: String) -> Int {
        // FNV-1a, rather than Swift's process-randomized Hasher.
        let hash = cityID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Int(hash % 5)
    }

    @discardableResult
    public static func openParcel(_ id: String, journey: inout JourneyState, care: CareState) -> Bool {
        guard parcels(journey: journey, care: care).contains(where: { $0.id == id }),
              journey.homecoming?.openedParcelIDs.contains(id) == false else { return false }
        journey.homecoming?.openedParcelIDs.append(id)
        return true
    }
}
