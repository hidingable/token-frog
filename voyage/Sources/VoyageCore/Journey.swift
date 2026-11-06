import Foundation

public enum PetKind: String, Codable, CaseIterable, Sendable {
    case pigeon, snail, suitcase, letter

    public var displayName: String {
        switch self {
        case .pigeon: "阿鸽"
        case .snail: "壳壳"
        case .suitcase: "皮箱"
        case .letter: "小笺"
        }
    }
}

public struct VehicleShare: Codable, Equatable, Sendable {
    public var client: String
    public var percent: Int

    public init(client: String, percent: Int) {
        self.client = client
        self.percent = percent
    }
}

public struct Letter: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case departure, daily }

    public var id: Int
    public var kind: Kind
    public var date: String
    public var pet: PetKind
    public var cityId: String
    /// Set when no city was reached that day: the pet writes from the road towards this city.
    public var transitTargetId: String?
    public var arrivals: [String]
    public var newCountries: [String]
    public var fuel: Int
    public var compareToMedianPercent: Int?
    public var vehicles: [VehicleShare]
    public var isDeepVisit: Bool
    public var deliverAt: Date
    public var read = false

    public var enrichmentDone = false
    public var weather: String?
    public var placeTitle: String?
    public var placeSummary: String?
    public var placeURL: String?
    public var photoFile: String?

    /// The city the place card and photo describe.
    public var subjectCityId: String { transitTargetId ?? cityId }
}

public struct DayRecord: Codable, Equatable, Sendable {
    public var fuel = 0
    public var byClient: [String: Int] = [:]
    public var arrivals: [String] = []
    public var newCountries: [String] = []

    public init() {}
}

public struct Stamp: Codable, Equatable, Sendable {
    public var country: String
    public var cityId: String
    public var date: String
}

public struct DestinationCard: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable { case nearest, reachable, newCountry }

    public var city: City
    public var distanceFuel: Int
    public var reason: Reason
    public var id: String { city.id }
}

public struct JourneyState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var seed: UInt32
    public var pet: PetKind
    public var startDate: String
    public var currentCityId: String
    public var targetCityId: String
    public var legFuel = 0
    public var nextChoiceId: String?
    public var route: [String]
    public var stamps: [Stamp] = []
    public var openDate: String
    public var days: [String: DayRecord] = [:]
    public var letters: [Letter] = []
    public var totalFuel = 0

    public init(seed: UInt32, startCityId: String, pet: PetKind = .pigeon, date: String, now: Date = Date()) {
        let start = City.named(startCityId)
        self.seed = seed
        self.pet = pet
        startDate = date
        openDate = date
        currentCityId = start.id
        targetCityId = start.id
        route = [start.id]
        stamps = [Stamp(country: start.country, cityId: start.id, date: date)]
        targetCityId = autoPick(from: start)
        letters = [
            Letter(
                id: 0, kind: .departure, date: date, pet: pet, cityId: start.id, transitTargetId: nil, arrivals: [],
                newCountries: [], fuel: 0, compareToMedianPercent: nil, vehicles: [], isDeepVisit: false, deliverAt: now
            ),
        ]
    }

    public var current: City { City.named(currentCityId) }
    public var target: City { City.named(targetCityId) }
    public var legCost: Int { Self.cost(from: current, to: target) }
    public var legProgress: Double { Double(legFuel) / Double(legCost) }
    public var remainingFuel: Int { legCost - legFuel }
    public var nextChoice: City? { nextChoiceId.flatMap(City.find) }

    public var position: Coordinate {
        let from = current.coordinate
        let to = target.coordinate
        var dLon = to.lon - from.lon
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        var lon = from.lon + dLon * legProgress
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return Coordinate(lat: from.lat + (to.lat - from.lat) * legProgress, lon: lon)
    }

    public static func cost(from: City, to: City) -> Int {
        max(fuelPerKm, Int(from.coordinate.distanceKm(to: to.coordinate) * Double(fuelPerKm)))
    }

    public func fuel(on date: String) -> Int { days[date]?.fuel ?? 0 }

    /// Advances the journey. `finalized` must hold the final count of every day from `openDate` up to,
    /// but excluding, `today.date`; the caller skips this call when those counts could not be read.
    public mutating func sync(today: DayUsage, finalized: [DayUsage] = [], calendar: Calendar = .current) {
        guard today.date >= openDate else { return }
        let finals = Dictionary(finalized.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
        while openDate < today.date {
            apply(finals[openDate] ?? DayUsage(date: openDate))
            settle(openDate, calendar: calendar)
            openDate = DayKey.next(openDate, calendar: calendar)
        }
        apply(today)
    }

    public mutating func choose(next cityId: String?) {
        nextChoiceId = cityId
    }

    public mutating func markRead(_ letterId: Int) {
        guard let index = letters.firstIndex(where: { $0.id == letterId }) else { return }
        letters[index].read = true
    }

    public func deliveredLetters(now: Date) -> [Letter] {
        letters.filter { $0.deliverAt <= now }.sorted { $0.id > $1.id }
    }

    public func unreadCount(now: Date) -> Int {
        letters.filter { $0.deliverAt <= now && !$0.read }.count
    }

    /// Offers up to three stops after the current target, each priced in tokens.
    public func destinationCards() -> [DestinationCard] {
        let from = target
        let pool = candidatePool(excluding: [from.id, currentCityId])
            .map { (city: $0, cost: Self.cost(from: from, to: $0)) }
            .sorted { $0.cost < $1.cost }
        guard let nearest = pool.first else { return [] }

        var cards = [DestinationCard(city: nearest.city, distanceFuel: nearest.cost, reason: .nearest)]
        let reach = max(nearest.cost * 3 / 2, recentDailyFuel())
        if let reachable = pool.first(where: { $0.cost >= reach && $0.city.id != nearest.city.id }) {
            cards.append(DestinationCard(city: reachable.city, distanceFuel: reachable.cost, reason: .reachable))
        }
        let stamped = Set(stamps.map(\.country))
        if let fresh = pool.first(where: { entry in
            !stamped.contains(entry.city.country) && entry.city.country != from.country
                && !cards.contains { $0.city.id == entry.city.id }
        }) {
            cards.append(DestinationCard(city: fresh.city, distanceFuel: fresh.cost, reason: .newCountry))
        }
        return cards.sorted { $0.distanceFuel < $1.distanceFuel }
    }

    /// Median of the most recent active days, used to compare today against "usual".
    public func recentDailyFuel(before date: String? = nil, limit: Int = 14) -> Int {
        let values = days
            .filter { $0.value.fuel > 0 && (date == nil || $0.key < date!) }
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map(\.value.fuel)
            .sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }

    private func candidatePool(excluding excluded: Set<String>) -> [City] {
        let visited = Set(route)
        let unvisited = City.all.filter { !visited.contains($0.id) && !excluded.contains($0.id) }
        return unvisited.isEmpty ? City.all.filter { !excluded.contains($0.id) } : unvisited
    }

    private func autoPick(from city: City) -> String {
        let pool = candidatePool(excluding: [city.id])
            .sorted { Self.cost(from: city, to: $0) < Self.cost(from: city, to: $1) }
        let stamped = Set(stamps.map(\.country))
        let nearby = Array(pool.prefix(4))
        let preferred = nearby.filter { !stamped.contains($0.country) }
        let options = preferred.isEmpty ? nearby : preferred
        guard !options.isEmpty else { preconditionFailure("City catalog has no other destination") }
        return options[Int(mix(seed &+ UInt32(route.count)) % UInt32(options.count))].id
    }

    private mutating func apply(_ usage: DayUsage) {
        var record = days[usage.date] ?? DayRecord()
        let delta = usage.fuel - record.fuel
        for (client, fuel) in usage.byClient {
            record.byClient[client] = max(record.byClient[client] ?? 0, fuel)
        }
        if delta > 0 { record.fuel = usage.fuel }
        days[usage.date] = record
        if delta > 0 {
            totalFuel += delta
            advance(delta, date: usage.date)
        }
    }

    private mutating func advance(_ amount: Int, date: String) {
        var remaining = amount
        while remaining > 0 {
            let needed = remainingFuel
            guard remaining >= needed else {
                legFuel += remaining
                return
            }
            remaining -= needed
            arrive(date: date)
        }
    }

    private mutating func arrive(date: String) {
        let arrived = target
        currentCityId = arrived.id
        route.append(arrived.id)
        legFuel = 0
        days[date, default: DayRecord()].arrivals.append(arrived.id)
        if !stamps.contains(where: { $0.country == arrived.country }) {
            stamps.append(Stamp(country: arrived.country, cityId: arrived.id, date: date))
            days[date, default: DayRecord()].newCountries.append(arrived.country)
        }
        if let choice = nextChoiceId, choice != arrived.id, City.find(choice) != nil {
            targetCityId = choice
        } else {
            targetCityId = autoPick(from: arrived)
        }
        nextChoiceId = nil
    }

    private mutating func settle(_ date: String, calendar: Calendar) {
        guard let record = days[date], record.fuel > 0 else { return }
        let median = recentDailyFuel(before: date)
        let hasBaseline = days.filter { $0.value.fuel > 0 && $0.key < date }.count >= 3
        let total = record.byClient.values.reduce(0, +)
        let vehicles = record.byClient
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { VehicleShare(client: $0.key, percent: Int((Double($0.value) / Double(max(total, 1)) * 100).rounded())) }
            .filter { $0.percent > 0 }
        guard let day = DayKey.date(from: date, calendar: calendar),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let deliverAt = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay) else {
            preconditionFailure("Invalid settled date \(date)")
        }
        letters.append(
            Letter(
                id: (letters.map(\.id).max() ?? 0) + 1,
                kind: .daily,
                date: date,
                pet: pet,
                cityId: record.arrivals.last ?? currentCityId,
                transitTargetId: record.arrivals.isEmpty ? targetCityId : nil,
                arrivals: record.arrivals,
                newCountries: record.newCountries,
                fuel: record.fuel,
                compareToMedianPercent: hasBaseline && median > 0 ? Int(((Double(record.fuel) / Double(median) - 1) * 100).rounded()) : nil,
                vehicles: vehicles,
                isDeepVisit: hasBaseline && record.fuel * 2 < median,
                deliverAt: deliverAt
            )
        )
    }
}

extension JourneyState {
    private enum CodingKeys: String, CodingKey {
        case version, seed, pet, startDate, currentCityId, targetCityId, legFuel, nextChoiceId
        case route, stamps, openDate, days, letters, totalFuel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        seed = try values.decode(UInt32.self, forKey: .seed)
        pet = try values.decode(PetKind.self, forKey: .pet)
        startDate = try values.decode(String.self, forKey: .startDate)
        currentCityId = try values.decode(String.self, forKey: .currentCityId)
        targetCityId = try values.decode(String.self, forKey: .targetCityId)
        legFuel = try values.decode(Int.self, forKey: .legFuel, default: 0)
        nextChoiceId = try values.decodeIfPresent(String.self, forKey: .nextChoiceId)
        route = try values.decode([String].self, forKey: .route)
        stamps = try values.decode([Stamp].self, forKey: .stamps, default: [])
        openDate = try values.decode(String.self, forKey: .openDate)
        days = try values.decode([String: DayRecord].self, forKey: .days, default: [:])
        letters = try values.decode([Letter].self, forKey: .letters, default: [])
        totalFuel = try values.decode(Int.self, forKey: .totalFuel, default: 0)
    }
}

extension Letter {
    private enum CodingKeys: String, CodingKey {
        case id, kind, date, pet, cityId, transitTargetId, arrivals, newCountries, fuel
        case compareToMedianPercent, vehicles, isDeepVisit, deliverAt, read, enrichmentDone
        case weather, placeTitle, placeSummary, placeURL, photoFile
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        date = try values.decode(String.self, forKey: .date)
        pet = try values.decode(PetKind.self, forKey: .pet)
        cityId = try values.decode(String.self, forKey: .cityId)
        transitTargetId = try values.decodeIfPresent(String.self, forKey: .transitTargetId)
        arrivals = try values.decode([String].self, forKey: .arrivals)
        newCountries = try values.decode([String].self, forKey: .newCountries)
        fuel = try values.decode(Int.self, forKey: .fuel)
        compareToMedianPercent = try values.decodeIfPresent(Int.self, forKey: .compareToMedianPercent)
        vehicles = try values.decode([VehicleShare].self, forKey: .vehicles)
        isDeepVisit = try values.decode(Bool.self, forKey: .isDeepVisit)
        deliverAt = try values.decode(Date.self, forKey: .deliverAt)
        read = try values.decode(Bool.self, forKey: .read, default: false)
        enrichmentDone = try values.decode(Bool.self, forKey: .enrichmentDone, default: false)
        weather = try values.decodeIfPresent(String.self, forKey: .weather)
        placeTitle = try values.decodeIfPresent(String.self, forKey: .placeTitle)
        placeSummary = try values.decodeIfPresent(String.self, forKey: .placeSummary)
        placeURL = try values.decodeIfPresent(String.self, forKey: .placeURL)
        photoFile = try values.decodeIfPresent(String.self, forKey: .photoFile)
    }
}

extension DayRecord {
    private enum CodingKeys: String, CodingKey { case fuel, byClient, arrivals, newCountries }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fuel = try values.decode(Int.self, forKey: .fuel, default: 0)
        byClient = try values.decode([String: Int].self, forKey: .byClient, default: [:])
        arrivals = try values.decode([String].self, forKey: .arrivals, default: [])
        newCountries = try values.decode([String].self, forKey: .newCountries, default: [])
    }
}

private extension KeyedDecodingContainer {
    /// Only absent fields use defaults; explicit nulls and wrong types remain decoding errors.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) throws -> T {
        contains(key) ? try decode(type, forKey: key) : fallback
    }
}

private func mix(_ value: UInt32) -> UInt32 {
    var x = value &+ 0x9E37_79B9
    x = (x ^ (x >> 16)) &* 0x8504_7B6B
    x = (x ^ (x >> 13)) &* 0xC2B2_AE35
    return x ^ (x >> 16)
}
