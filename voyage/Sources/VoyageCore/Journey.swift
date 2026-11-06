import Foundation

public struct VehicleShare: Codable, Equatable, Sendable {
    public var client: String
    public var percent: Int

    public init(client: String, percent: Int) {
        self.client = client
        self.percent = percent
    }
}

public struct Letter: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case departure, daily, logbook }

    public var id: Int
    public var kind: Kind
    public var date: String
    public var pet: PetID
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
    public var logbook: Logbook?

    public var enrichmentDone = false
    public var storyId: String?
    public var storyVersion: Int?
    /// nil is a legacy/template letter; an empty dictionary is a newly settled, uncomposed letter.
    public var texts: [String: String]? = [:]
    public var leadTexts: [String: String] = [:]
    public var learnedTexts: [String: String] = [:]
    public var replyOptions: [StoryReply] = []
    public var selectedReplyId: String?
    public var fulfilledReplyId: String?
    public var carriedItem: String?
    /// Records the item habit bonus; fulfillment letters and items without a habit never grant it.
    public var itemTriggered: Bool?
    public var facts: [FactSnapshot] = []
    public var rewards = StoryRewards()
    public var weatherCode: Int?
    public var temperatureC: Int?
    public var place: [String: Place] = [:]

    public struct FactSnapshot: Codable, Equatable, Sendable {
        public var id: String
        public var names: [String: String]
        public var sources: [String]
        public var summary: [String: String]? = nil
    }

    public struct Place: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String
        public var url: String?

        public init(title: String, summary: String, url: String?) {
            self.title = title
            self.summary = summary
            self.url = url
        }
    }
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
    public var countryCode: String
    public var cityId: String
    public var date: String
}

public struct JourneyState: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    public var version = currentVersion
    public var seed: UInt32
    public var pet: PetID
    public var startDate: String
    public var currentCityId: String
    public var targetCityId: String
    public var legCost: Int
    public var legFrom: Coordinate
    public var legTo: Coordinate
    public var targetCountryCode: String?
    public var legFuel = 0
    public var route: [String]
    public var stamps: [Stamp] = []
    public var openDate: String
    public var days: [String: DayRecord] = [:]
    public var letters: [Letter] = []
    public var totalFuel = 0

    public init(seed: UInt32, startCityId: String, pet: PetID? = nil, date: String, now: Date = Date(), logbook: Logbook? = nil, catalog: CityCatalog) {
        let pet = pet ?? catalog.pets.defaultID
        let start = catalog.city(startCityId)
        self.seed = seed
        self.pet = pet
        startDate = date
        openDate = date
        currentCityId = start.id
        targetCityId = start.id
        route = [start.id]
        stamps = start.isPlaceholder ? [] : [Stamp(countryCode: start.countryCode, cityId: start.id, date: date)]
        legFrom = start.coordinate
        legTo = start.coordinate
        legCost = fuelPerKm
        let first = DestinationPicker.first(
            from: start.coordinate, currentCityId: start.id, route: route,
            stampedCountries: Set(stamps.map(\.countryCode)), catalog: catalog, seed: seed
        )
        setTarget(first, from: start.coordinate, catalog: catalog)
        letters = [
            Letter(
                id: 0, kind: .logbook, date: date, pet: pet, cityId: start.id, transitTargetId: nil, arrivals: [],
                newCountries: [], fuel: 0, compareToMedianPercent: nil, vehicles: [], isDeepVisit: false, deliverAt: now,
                read: true, logbook: logbook, enrichmentDone: true, texts: nil
            ),
        ]
    }

    public var legProgress: Double { Double(legFuel) / Double(legCost) }
    public var remainingFuel: Int { legCost - legFuel }

    public var position: Coordinate {
        let from = legFrom
        let to = legTo
        var dLon = to.lon - from.lon
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        var lon = from.lon + dLon * legProgress
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return Coordinate(lat: from.lat + (to.lat - from.lat) * legProgress, lon: lon)
    }

    public static func cost(from: City, to: City) -> Int {
        Self.cost(from: from.coordinate, to: to.coordinate)
    }

    static func cost(from: Coordinate, to: Coordinate) -> Int {
        max(fuelPerKm, Int(from.distanceKm(to: to) * Double(fuelPerKm)))
    }

    public func fuel(on date: String) -> Int { days[date]?.fuel ?? 0 }

    /// Replays the first day's credited usage from a new home while keeping its original letter.
    public mutating func setStart(_ cityId: String, calendar: Calendar = .current, catalog: CityCatalog) {
        guard startDate == openDate, catalog.find(cityId)?.status == "active", cityId != route.first else { return }
        let firstLetter = letters.first { $0.id == 0 }
        let record = days[openDate] ?? DayRecord()
        var replacement = JourneyState(seed: seed, startCityId: cityId, pet: pet, date: startDate, catalog: catalog)
        replacement.sync(today: DayUsage(date: openDate, fuel: record.fuel, byClient: record.byClient), calendar: calendar, catalog: catalog)
        if var firstLetter {
            firstLetter.cityId = cityId
            replacement.letters = [firstLetter]
        }
        self = replacement
    }

    /// Advances the journey. `finalized` must hold the final count of every day from `openDate` up to,
    /// but excluding, `today.date`; the caller skips this call when those counts could not be read.
    public mutating func sync(today: DayUsage, finalized: [DayUsage] = [], calendar: Calendar = .current, catalog: CityCatalog, wishTags: Set<String> = []) {
        guard today.date >= openDate else { return }
        let finals = Dictionary(finalized.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
        while openDate < today.date {
            apply(finals[openDate] ?? DayUsage(date: openDate), catalog: catalog, wishTags: wishTags)
            settle(openDate, calendar: calendar)
            openDate = DayKey.next(openDate, calendar: calendar)
        }
        apply(today, catalog: catalog, wishTags: wishTags)
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

    private mutating func apply(_ usage: DayUsage, catalog: CityCatalog, wishTags: Set<String>) {
        var record = days[usage.date] ?? DayRecord()
        let delta = usage.fuel - record.fuel
        for (client, fuel) in usage.byClient {
            record.byClient[client] = max(record.byClient[client] ?? 0, fuel)
        }
        if delta > 0 { record.fuel = usage.fuel }
        days[usage.date] = record
        if delta > 0 {
            totalFuel += delta
            advance(delta, date: usage.date, catalog: catalog, wishTags: wishTags)
        }
    }

    private mutating func advance(_ amount: Int, date: String, catalog: CityCatalog, wishTags: Set<String>) {
        var remaining = amount
        while remaining > 0 {
            let needed = remainingFuel
            guard remaining >= needed else {
                legFuel += remaining
                return
            }
            remaining -= needed
            arrive(date: date, catalog: catalog, wishTags: wishTags)
        }
    }

    private mutating func setTarget(_ cityId: String, from coordinate: Coordinate, catalog: CityCatalog) {
        let target = catalog.city(cityId)
        targetCityId = cityId
        legFrom = coordinate
        legTo = target.coordinate
        legCost = Self.cost(from: legFrom, to: legTo)
        targetCountryCode = target.isPlaceholder ? nil : target.countryCode
    }

    private mutating func arrive(date: String, catalog: CityCatalog, wishTags: Set<String>) {
        let arrivedId = targetCityId
        let arrivedCoordinate = legTo
        currentCityId = arrivedId
        route.append(arrivedId)
        legFuel = 0
        days[date, default: DayRecord()].arrivals.append(arrivedId)
        if let countryCode = targetCountryCode, !stamps.contains(where: { $0.countryCode == countryCode }) {
            stamps.append(Stamp(countryCode: countryCode, cityId: arrivedId, date: date))
            days[date, default: DayRecord()].newCountries.append(countryCode)
        }
        let next = DestinationPicker.pick(
            from: arrivedCoordinate, currentCityId: arrivedId, route: route,
            stampedCountries: Set(stamps.map(\.countryCode)),
            medianFuel: recentDailyFuel(before: date, limit: DestinationPicker.configuration.recentActiveDays),
            wishTags: wishTags, catalog: catalog, seed: seed
        )
        setTarget(next, from: arrivedCoordinate, catalog: catalog)
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
        case version, seed, pet, startDate, currentCityId, targetCityId, legFuel
        case route, stamps, openDate, days, letters, totalFuel, legCost, legFrom, legTo, targetCountryCode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        seed = try values.decode(UInt32.self, forKey: .seed)
        pet = try values.decode(PetID.self, forKey: .pet)
        startDate = try values.decode(String.self, forKey: .startDate)
        currentCityId = try values.decode(String.self, forKey: .currentCityId)
        targetCityId = try values.decode(String.self, forKey: .targetCityId)
        legCost = try values.decode(Int.self, forKey: .legCost)
        guard legCost >= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .legCost, in: values, debugDescription: "Leg cost must be positive")
        }
        legFrom = try values.decode(Coordinate.self, forKey: .legFrom)
        legTo = try values.decode(Coordinate.self, forKey: .legTo)
        targetCountryCode = try values.decodeIfPresent(String.self, forKey: .targetCountryCode)
        legFuel = try values.decode(Int.self, forKey: .legFuel, default: 0)
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
        case compareToMedianPercent, vehicles, isDeepVisit, deliverAt, read, logbook, enrichmentDone
        case storyId, storyVersion, texts, leadTexts, learnedTexts, replyOptions, selectedReplyId, fulfilledReplyId
        case carriedItem, itemTriggered
        case facts, rewards, weatherCode, temperatureC, place, photoFile
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        date = try values.decode(String.self, forKey: .date)
        pet = try values.decode(PetID.self, forKey: .pet)
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
        logbook = try values.decodeIfPresent(Logbook.self, forKey: .logbook)
        enrichmentDone = try values.decode(Bool.self, forKey: .enrichmentDone, default: false)
        storyId = try values.decodeIfPresent(String.self, forKey: .storyId)
        storyVersion = try values.decodeIfPresent(Int.self, forKey: .storyVersion)
        texts = try values.decodeIfPresent([String: String].self, forKey: .texts)
        leadTexts = try values.decode([String: String].self, forKey: .leadTexts, default: [:])
        learnedTexts = try values.decode([String: String].self, forKey: .learnedTexts, default: [:])
        replyOptions = try values.decode([StoryReply].self, forKey: .replyOptions, default: [])
        selectedReplyId = try values.decodeIfPresent(String.self, forKey: .selectedReplyId)
        fulfilledReplyId = try values.decodeIfPresent(String.self, forKey: .fulfilledReplyId)
        carriedItem = try values.decodeIfPresent(String.self, forKey: .carriedItem)
        itemTriggered = try values.decodeIfPresent(Bool.self, forKey: .itemTriggered)
        facts = try values.decode([FactSnapshot].self, forKey: .facts, default: [])
        rewards = try values.decode(StoryRewards.self, forKey: .rewards, default: StoryRewards())
        weatherCode = try values.decodeIfPresent(Int.self, forKey: .weatherCode)
        temperatureC = try values.decodeIfPresent(Int.self, forKey: .temperatureC)
        place = try values.decode([String: Place].self, forKey: .place, default: [:])
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
