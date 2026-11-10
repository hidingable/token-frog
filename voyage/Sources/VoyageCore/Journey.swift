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
    public enum Kind: String, Codable, Sendable { case departure, daily, logbook, postcard, reunion, weekly }

    public var id: Int
    public var kind: Kind
    public var date: String
    public var pet: PetID
    public var cityId: String
    /// Set when no city was reached that day: the pet writes from the road towards this city.
    public var transitTargetId: String?
    public var arrivals: [String]
    /// Presentation provenance only; daily rewards belong to the last stay, or the active transit trip.
    public var tripNumber: Int?
    public var newCountries: [String]
    public var fuel: Int
    /// Absent on legacy letters, whose fuel used the old mileage rate.
    public var tokens: Int?
    public var km: Double { Double(tokens ?? fuel) / Double(tokens == nil ? legacyTokensPerKm : outboundTokensPerKm) }
    public var compareToMedianPercent: Int?
    public var vehicles: [VehicleShare]
    public var isDeepVisit: Bool
    public var deliverAt: Date
    public var read = false
    public var logbook: Logbook?

    public var enrichmentDone = false
    public var storyId: String?
    public var storyVersion: Int?
    public struct ArrivalStory: Codable, Equatable, Sendable {
        public var cityId: String
        public var storyId: String
        public var storyVersion: Int
        public var isRevisit: Bool
        public var texts: [String: String]
    }
    /// One story snapshot per stay; rewards and care effects still belong to the enclosing letter.
    public var arrivalStories: [ArrivalStory] = []
    /// Snapshot the marker so content updates and interrupted care writes cannot change it.
    public var isRevisit: Bool?
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
    public var rewardItems: [Item] = []
    public var memoryReference: CareState.Memory?
    public var weeklySummary: WeeklyMailSummary?
    /// Identifies the saved wish whose one-time explanation is included in this text snapshot.
    public var wishExplanationAt: Date?
    public var usageEventNotes: [UsageEventNote]?
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
    /// All-token high-water mark. Missing in old saves until a successful history scan.
    public var tokens: Int? = 0
    public var km: Double { Double(tokens ?? fuel) / Double(tokens == nil ? legacyTokensPerKm : outboundTokensPerKm) }
    /// Only an actual main-window open sets this; old records default to false.
    public var mainWindowOpened = false
    public var byClient: [String: Int] = [:]
    public var arrivals: [String] = []
    public var tripNumber: Int?
    public var newCountries: [String] = []
    public var roadClueDecision: RoadClueDecision?
    /// Final scan value, separate from mileage's monotonic high-water mark.
    public var finalUsageFuel: Int?
    public var lastObservedAt: Date?

    public init() {}
}

public struct Stamp: Codable, Equatable, Sendable {
    public var countryCode: String
    public var cityId: String
    public var date: String
}

public struct JourneyState: Codable, Equatable, Sendable {
    public static let currentVersion = 8
    public var version = currentVersion
    public var seed: UInt32
    public var pet: PetID
    public var startDate: String
    public enum Phase: String, Codable, Sendable { case home, pending, outbound, staying, returning }
    public var homeCityId: String
    public var homeCoordinate: Coordinate
    public var phase: Phase = .outbound
    public var phaseSince: Date
    public var travelFund = 0
    public var tripCount = 0
    public var homecoming: Homecoming?
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
    /// Legacy uncached counter; mileage displays and progression use totalKm instead.
    public var totalFuel = 0
    public var totalKm = 0.0
    /// Main-window opens only; absent on pre-M2 saves, so upgrade starts a fresh baseline.
    public var lastOpenedDate: String?
    /// Missing on older saves; activation starts at the next local Sunday without catch-up.
    public var weeklyMailEligibleFrom: String?
    public var lastWeeklyMailSunday: String?
    public var roadCluesEligibleFrom: String?
    public var usageEvents: UsageEvents?

    public init(seed: UInt32, startCityId: String, pet: PetID? = nil, date: String, now: Date? = nil, logbook: Logbook? = nil, catalog: CityCatalog) {
        let now = now ?? DayKey.date(from: date)!
        let pet = pet ?? catalog.pets.defaultID
        let start = catalog.city(startCityId)
        self.seed = seed
        self.pet = pet
        startDate = date
        weeklyMailEligibleFrom = date
        roadCluesEligibleFrom = date
        usageEvents = UsageEvents(eligibleFrom: date)
        openDate = date
        homeCityId = start.id
        homeCoordinate = start.coordinate
        phaseSince = now
        currentCityId = start.id
        targetCityId = start.id
        route = []
        stamps = start.isPlaceholder ? [] : [Stamp(countryCode: start.countryCode, cityId: start.id, date: date)]
        legFrom = start.coordinate
        legTo = start.coordinate
        legCost = outboundTokensPerKm
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

    public var petIsHome: Bool { phase == .home || phase == .pending }

    public var tokensPerKm: Int { phase == .returning ? returnTokensPerKm : outboundTokensPerKm }
    public var travelFundKm: Double { Double(travelFund) / Double(outboundTokensPerKm) }
    public var legProgress: Double { phase == .pending || phase == .home ? 0 : Double(legFuel) / Double(legCost) }
    public var remainingFuel: Int { phase == .pending || phase == .home ? legCost : legCost - legFuel }
    public var remainingKm: Double { Double(remainingFuel) / Double(tokensPerKm) }
    public var legKm: Double { Double(legCost) / Double(tokensPerKm) }

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
        max(outboundTokensPerKm, Int(from.distanceKm(to: to) * Double(outboundTokensPerKm)))
    }

    public func fuel(on date: String) -> Int { days[date]?.fuel ?? 0 }

    /// Replays the first day's credited usage from a new home while keeping its original letter.
    public mutating func setStart(_ cityId: String, now: Date, calendar: Calendar = .current, catalog: CityCatalog) {
        guard startDate == openDate, catalog.find(cityId)?.status == "active", cityId != homeCityId else { return }
        let firstLetter = letters.first { $0.id == 0 }
        let record = days[openDate] ?? DayRecord()
        var replacement = JourneyState(seed: seed, startCityId: cityId, pet: pet, date: startDate, now: letters.first?.deliverAt ?? phaseSince, catalog: catalog)
        replacement.sync(today: DayUsage(date: openDate, fuel: record.fuel, byClient: record.byClient, observedTokens: record.tokens ?? 0), now: now, calendar: calendar, catalog: catalog)
        replacement.days[openDate]?.mainWindowOpened = record.mainWindowOpened
        replacement.lastOpenedDate = lastOpenedDate
        replacement.weeklyMailEligibleFrom = weeklyMailEligibleFrom
        replacement.lastWeeklyMailSunday = lastWeeklyMailSunday
        replacement.roadCluesEligibleFrom = roadCluesEligibleFrom
        replacement.days[openDate]?.roadClueDecision = record.roadClueDecision
        replacement.usageEvents = usageEvents
        if var firstLetter {
            firstLetter.cityId = cityId
            replacement.letters = [firstLetter]
        }
        self = replacement
    }

    /// Advances the journey. `finalized` must hold the final count of every day from `openDate` up to,
    /// but excluding, `today.date`; the caller skips this call when those counts could not be read.
    public mutating func sync(today: DayUsage, finalized: [DayUsage] = [], hourly: [String: [HourUsage]] = [:], now: Date, calendar: Calendar = .current, catalog: CityCatalog, wishTags: Set<String> = [], revisitCities: Set<String> = [], deliveryTime: DeliveryTime = .standard) {
        guard today.date >= openDate else { return }
        enableRoadClues(on: today.date)
        enableUsageEvents(on: today.date)
        let finals = Dictionary(finalized.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
        while openDate < today.date {
            let date = openDate
            let final = finals[date] ?? DayUsage(date: date)
            let start = DayKey.date(from: date, calendar: calendar)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            // A whole idle day after the stay ended takes the free night mail, without charging the fund.
            let stayEnded = phase == .staying ? phaseSince.addingTimeInterval(6 * 3600) : phaseSince
            if final.observedTokens == 0, (phase == .staying || phase == .returning), stayEnded <= start {
                arriveHome(at: end, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
            }
            apply(final, at: end.addingTimeInterval(-59), hourly: hourly[date], calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
            checkTime(at: end, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
            settleUsageEvents(final, content: catalog.usageEvents)
            settle(date, calendar: calendar, deliveryTime: deliveryTime)
            openDate = DayKey.next(date, calendar: calendar)
        }
        apply(today, at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
    }

    /// Pending usage and saved fund begin the outbound leg at the explicit input time.
    public mutating func departNow(now: Date, calendar: Calendar = .current, catalog: CityCatalog, wishTags: Set<String> = [], revisitCities: Set<String> = []) {
        guard phase == .pending else { return }
        let pending = legFuel
        legFuel = 0
        phase = .outbound
        phaseSince = now
        homecoming = nil
        advance(pending, at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
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
    public func recentDailyKm(before date: String? = nil, limit: Int = 14) -> Double {
        Double(recentDailyTokens(before: date, limit: limit)) / Double(outboundTokensPerKm)
    }

    private func recentDailyTokens(before date: String? = nil, limit: Int = 14) -> Int {
        let values = days
            .filter { ($0.value.tokens ?? 0) > 0 && (date == nil || $0.key < date!) }
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map { $0.value.tokens! }
            .sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }

    /// Fill missing observations without replaying already credited mileage or rewriting settled mail.
    public mutating func backfillTokens(_ history: [DayUsage]) {
        for usage in history where days[usage.date] != nil && days[usage.date]?.tokens == nil {
            days[usage.date]?.tokens = usage.observedTokens
        }
    }

    private mutating func apply(_ usage: DayUsage, at now: Date, hourly: [HourUsage]? = nil, calendar: Calendar, catalog: CityCatalog, wishTags: Set<String>, revisitCities: Set<String>) {
        recordFirstVoyages(usage, content: catalog.usageEvents)
        var record = days[usage.date] ?? DayRecord()
        let delta = max(0, usage.observedTokens - (record.tokens ?? 0))
        let lastObserved = record.lastObservedAt
        for (client, fuel) in usage.byClient {
            record.byClient[client] = max(record.byClient[client] ?? 0, fuel)
        }
        totalFuel += max(0, usage.fuel - record.fuel)
        record.fuel = max(record.fuel, usage.fuel)
        record.tokens = max(record.tokens ?? 0, usage.observedTokens)
        if record.tokens! > 0, usage.date >= roadCluesEligibleFrom!, record.roadClueDecision == nil {
            record.roadClueDecision = catalog.roadClues.draw(seed: seed, date: usage.date)
        }
        record.lastObservedAt = max(lastObserved ?? now, now)
        days[usage.date] = record
        // Finalized usage is allocated proportionally only over unobserved hour ends.
        if let hourly, delta > 0 {
            let start = DayKey.date(from: usage.date, calendar: calendar)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            var weights: [Date: Int] = [:]
            for row in hourly where row.date == usage.date && (0..<24).contains(row.hour) && row.tokens.total > 0 {
                let hour = calendar.date(bySettingHour: row.hour, minute: 0, second: 0, of: start)!
                let end = min(hour.addingTimeInterval(3600), dayEnd)
                if lastObserved == nil || end > lastObserved! { weights[end, default: 0] += row.tokens.total }
            }
            let total = weights.values.reduce(0, +)
            if total > 0 {
                var allocated = 0
                var cumulative = 0
                for end in weights.keys.sorted() {
                    cumulative += weights[end]!
                    // Cumulative rounding preserves every integer token, including the last remainder.
                    let share = cumulative == total ? delta : total.dividingFullWidth(delta.multipliedFullWidth(by: cumulative)).quotient
                    checkTime(at: end, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
                    advance(share - allocated, at: end, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
                    allocated = share
                }
                return
            }
        }
        // No usable hourly rows (including a failed/old report): use the supplied day-end timestamp.
        checkTime(at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
        advance(delta, at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
    }

    private mutating func checkTime(at now: Date, calendar: Calendar, catalog: CityCatalog, wishTags: Set<String>, revisitCities: Set<String>) {
        if phase == .pending, now >= phaseSince.addingTimeInterval(30 * 60) {
            departNow(now: phaseSince.addingTimeInterval(30 * 60), calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
        }
        if phase == .staying, now >= phaseSince.addingTimeInterval(6 * 3600) {
            let ended = phaseSince.addingTimeInterval(6 * 3600)
            phase = .returning
            phaseSince = ended
            legFrom = legTo
            legTo = homeCoordinate
            targetCityId = homeCityId
            targetCountryCode = nil
            legCost = max(returnTokensPerKm, Int(legFrom.distanceKm(to: legTo) * Double(returnTokensPerKm)))
            legFuel = 0
            advance(0, at: ended, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
        }
    }

    private mutating func addKm(tokens: Int, rate: Int) {
        // Both rates divide the outbound rate: round at that token resolution for stable sliced scans.
        totalKm = (totalKm * Double(outboundTokensPerKm) + Double(tokens) * Double(outboundTokensPerKm / rate)).rounded() / Double(outboundTokensPerKm)
    }

    private mutating func saveFund(_ amount: Int, on date: String) {
        // Completed active days keep the cap stable throughout the current day.
        let cap = recentDailyTokens(before: date)
        let previousOverflow = max(0, travelFund - cap)
        travelFund -= previousOverflow
        let available = cap - travelFund
        let saved = min(amount, available)
        travelFund += saved
        addKm(tokens: previousOverflow, rate: outboundTokensPerKm)
        addKm(tokens: amount - saved, rate: outboundTokensPerKm)
    }

    private mutating func advance(_ amount: Int, at now: Date, calendar: Calendar, catalog: CityCatalog, wishTags: Set<String>, revisitCities: Set<String>) {
        let date = DayKey.string(from: now, calendar: calendar)
        saveFund(0, on: date)
        if amount > 0, days[date, default: DayRecord()].arrivals.isEmpty {
            days[date, default: DayRecord()].tripNumber = tripCount + 1
        }
        switch phase {
        case .home:
            if amount > 0 { phase = .pending; phaseSince = now; legFuel = amount }
        case .pending:
            legFuel += amount
        case .staying:
            saveFund(amount, on: date)
        case .outbound, .returning:
            let funded = min(travelFund, remainingFuel)
            travelFund -= funded
            let spent = min(amount, remainingFuel - funded)
            legFuel += funded + spent
            addKm(tokens: funded + spent, rate: tokensPerKm)
            let surplus = amount - spent
            guard remainingFuel == 0 else { return }
            if phase == .outbound {
                currentCityId = targetCityId
                route.append(currentCityId)
                days[date, default: DayRecord()].tripNumber = tripCount + 1
                days[date, default: DayRecord()].arrivals.append(currentCityId)
                if let country = targetCountryCode, !stamps.contains(where: { $0.countryCode == country }) {
                    stamps.append(Stamp(countryCode: country, cityId: currentCityId, date: date))
                    days[date, default: DayRecord()].newCountries.append(country)
                }
                phase = .staying
                phaseSince = now
                saveFund(surplus, on: date)
            } else {
                arriveHome(at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
                advance(surplus, at: now, calendar: calendar, catalog: catalog, wishTags: wishTags, revisitCities: revisitCities)
            }
        }
    }

    private mutating func setTarget(_ cityId: String, from coordinate: Coordinate, catalog: CityCatalog) {
        let target = catalog.city(cityId)
        targetCityId = cityId
        legFrom = coordinate
        legTo = target.coordinate
        legCost = Self.cost(from: legFrom, to: legTo)
        legFuel = 0
        targetCountryCode = target.isPlaceholder ? nil : target.countryCode
    }

    private mutating func arriveHome(at now: Date, calendar: Calendar, catalog: CityCatalog, wishTags: Set<String>, revisitCities: Set<String>) {
        homecoming = Homecoming(tripNumber: tripCount + 1, cityId: currentCityId, returnedAt: now,
                                distanceKm: homeCoordinate.distanceKm(to: catalog.city(currentCityId).coordinate),
                                medianKm: max(DestinationPicker.configuration.minimumMedianKm,
                                              recentDailyKm(before: DayKey.string(from: now, calendar: calendar))))
        phase = .home
        phaseSince = now
        currentCityId = homeCityId
        tripCount += 1
        let next = DestinationPicker.pick(
            from: homeCoordinate, currentCityId: homeCityId, route: route,
            stampedCountries: Set(stamps.map(\.countryCode)),
            medianKm: recentDailyKm(before: DayKey.string(from: now, calendar: calendar), limit: DestinationPicker.configuration.recentActiveDays),
            wishTags: wishTags, revisitCities: revisitCities, catalog: catalog, seed: seed, tripCount: tripCount
        )
        setTarget(next, from: homeCoordinate, catalog: catalog)
    }

    private mutating func settle(_ date: String, calendar: Calendar, deliveryTime: DeliveryTime) {
        guard let record = days[date], (record.tokens ?? 0) > 0 || record.mainWindowOpened else { return }
        let median = recentDailyKm(before: date)
        let hasBaseline = days.filter { ($0.value.tokens ?? 0) > 0 && $0.key < date }.count >= 3
        let total = record.byClient.values.reduce(0, +)
        let vehicles = record.byClient
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { VehicleShare(client: $0.key, percent: Int((Double($0.value) / Double(max(total, 1)) * 100).rounded())) }
            .filter { $0.percent > 0 }
        guard let day = DayKey.date(from: date, calendar: calendar),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let deliverAt = calendar.date(bySettingHour: deliveryTime.hour, minute: deliveryTime.minute, second: 0, of: nextDay) else {
            preconditionFailure("Invalid settled date \(date)")
        }
        if (record.tokens ?? 0) == 0 {
            letters.append(Letter(
                id: (letters.map(\.id).max() ?? 0) + 1, kind: .postcard, date: date,
                pet: pet, cityId: currentCityId, arrivals: [], newCountries: [], fuel: 0,
                vehicles: [], isDeepVisit: false, deliverAt: deliverAt, enrichmentDone: true
            ))
            return
        }
        letters.append(
            Letter(
                id: (letters.map(\.id).max() ?? 0) + 1,
                kind: .daily,
                date: date,
                pet: pet,
                cityId: record.arrivals.last ?? route.last ?? homeCityId,
                transitTargetId: record.arrivals.isEmpty ? targetCityId : nil,
                arrivals: record.arrivals,
                tripNumber: record.tripNumber,
                newCountries: record.newCountries,
                fuel: record.fuel,
                tokens: record.tokens,
                compareToMedianPercent: hasBaseline && median > 0 ? Int(((record.km / median - 1) * 100).rounded()) : nil,
                vehicles: vehicles,
                isDeepVisit: hasBaseline && record.km * 2 < median,
                deliverAt: deliverAt, usageEventNotes: takeUsageEventNotes()
            )
        )
    }
}

extension JourneyState {
    private enum CodingKeys: String, CodingKey {
        case version, seed, pet, startDate, currentCityId, targetCityId, legFuel
        case route, stamps, openDate, days, letters, totalFuel, totalKm, legCost, legFrom, legTo, targetCountryCode
        case lastOpenedDate, weeklyMailEligibleFrom, lastWeeklyMailSunday, roadCluesEligibleFrom
        case usageEvents
        case homeCityId, homeCoordinate, phase, phaseSince, travelFund, tripCount, homecoming
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        seed = try values.decode(UInt32.self, forKey: .seed)
        pet = try values.decode(PetID.self, forKey: .pet)
        startDate = try values.decode(String.self, forKey: .startDate)
        homeCityId = try values.decode(String.self, forKey: .homeCityId)
        homeCoordinate = try values.decode(Coordinate.self, forKey: .homeCoordinate)
        phase = try values.decode(Phase.self, forKey: .phase)
        phaseSince = try values.decode(Date.self, forKey: .phaseSince)
        travelFund = try values.decode(Int.self, forKey: .travelFund)
        tripCount = try values.decode(Int.self, forKey: .tripCount)
        homecoming = try values.decodeIfPresent(Homecoming.self, forKey: .homecoming)
        guard travelFund >= 0, tripCount >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .travelFund, in: values, debugDescription: "Fund and trip count must be nonnegative")
        }
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
        totalKm = try values.decode(Double.self, forKey: .totalKm, default: 0)
        lastOpenedDate = try values.decodeIfPresent(String.self, forKey: .lastOpenedDate)
        weeklyMailEligibleFrom = try values.decodeIfPresent(String.self, forKey: .weeklyMailEligibleFrom)
        lastWeeklyMailSunday = try values.decodeIfPresent(String.self, forKey: .lastWeeklyMailSunday)
        roadCluesEligibleFrom = try values.decodeIfPresent(String.self, forKey: .roadCluesEligibleFrom)
        usageEvents = try values.decodeIfPresent(UsageEvents.self, forKey: .usageEvents)
    }
}

extension Letter {
    private enum CodingKeys: String, CodingKey {
        case id, kind, date, pet, cityId, transitTargetId, arrivals, newCountries, fuel, tokens
        case compareToMedianPercent, vehicles, isDeepVisit, deliverAt, read, logbook, enrichmentDone
        case tripNumber
        case storyId, storyVersion, arrivalStories, isRevisit, texts, leadTexts, learnedTexts, replyOptions, selectedReplyId, fulfilledReplyId
        case carriedItem, itemTriggered
        case facts, rewards, rewardItems, memoryReference, weeklySummary, wishExplanationAt, usageEventNotes, weatherCode, temperatureC, place, photoFile
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
        tripNumber = try values.decodeIfPresent(Int.self, forKey: .tripNumber)
        newCountries = try values.decode([String].self, forKey: .newCountries)
        fuel = try values.decode(Int.self, forKey: .fuel)
        tokens = try values.decodeIfPresent(Int.self, forKey: .tokens)
        compareToMedianPercent = try values.decodeIfPresent(Int.self, forKey: .compareToMedianPercent)
        vehicles = try values.decode([VehicleShare].self, forKey: .vehicles)
        isDeepVisit = try values.decode(Bool.self, forKey: .isDeepVisit)
        deliverAt = try values.decode(Date.self, forKey: .deliverAt)
        read = try values.decode(Bool.self, forKey: .read, default: false)
        logbook = try values.decodeIfPresent(Logbook.self, forKey: .logbook)
        enrichmentDone = try values.decode(Bool.self, forKey: .enrichmentDone, default: false)
        storyId = try values.decodeIfPresent(String.self, forKey: .storyId)
        storyVersion = try values.decodeIfPresent(Int.self, forKey: .storyVersion)
        arrivalStories = try values.decode([ArrivalStory].self, forKey: .arrivalStories, default: [])
        isRevisit = try values.decodeIfPresent(Bool.self, forKey: .isRevisit)
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
        rewardItems = try values.decode([Item].self, forKey: .rewardItems, default: [])
        memoryReference = try values.decodeIfPresent(CareState.Memory.self, forKey: .memoryReference)
        weeklySummary = try values.decodeIfPresent(WeeklyMailSummary.self, forKey: .weeklySummary)
        wishExplanationAt = try values.decodeIfPresent(Date.self, forKey: .wishExplanationAt)
        usageEventNotes = try values.decodeIfPresent([UsageEventNote].self, forKey: .usageEventNotes)
        weatherCode = try values.decodeIfPresent(Int.self, forKey: .weatherCode)
        temperatureC = try values.decodeIfPresent(Int.self, forKey: .temperatureC)
        place = try values.decode([String: Place].self, forKey: .place, default: [:])
        photoFile = try values.decodeIfPresent(String.self, forKey: .photoFile)
    }
}

extension DayRecord {
    private enum CodingKeys: String, CodingKey { case fuel, tokens, byClient, arrivals, tripNumber, newCountries, mainWindowOpened, roadClueDecision, finalUsageFuel, lastObservedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fuel = try values.decode(Int.self, forKey: .fuel, default: 0)
        tokens = try values.decodeIfPresent(Int.self, forKey: .tokens)
        mainWindowOpened = try values.decode(Bool.self, forKey: .mainWindowOpened, default: false)
        byClient = try values.decode([String: Int].self, forKey: .byClient, default: [:])
        arrivals = try values.decode([String].self, forKey: .arrivals, default: [])
        tripNumber = try values.decodeIfPresent(Int.self, forKey: .tripNumber)
        newCountries = try values.decode([String].self, forKey: .newCountries, default: [])
        roadClueDecision = try values.decodeIfPresent(RoadClueDecision.self, forKey: .roadClueDecision)
        finalUsageFuel = try values.decodeIfPresent(Int.self, forKey: .finalUsageFuel)
        lastObservedAt = try values.decodeIfPresent(Date.self, forKey: .lastObservedAt)
    }
}

private extension KeyedDecodingContainer {
    /// Only absent fields use defaults; explicit nulls and wrong types remain decoding errors.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) throws -> T {
        contains(key) ? try decode(type, forKey: key) : fallback
    }
}
