import Foundation
import Testing
@testable import VoyageCore

private let pickerCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func pickerCity(
    _ id: String, km: Double, country: String = "CN", level: String = "basic", status: String = "active", tags: [String] = ["coast"]
) -> City {
    City(
        id: id, status: status, lat: 0, lon: km / 6371 * 180 / .pi, countryCode: country,
        continent: "asia", tags: tags, level: level, names: ["en": id, "zh-Hans": id],
        wikipedia: ["en": id, "zh-Hans": id], facts: []
    )
}

/// Write cities in the supplied order, then exercise the production directory loader.
private struct PickerCatalogSandbox {
    let directory: URL
    let catalog: CityCatalog

    init(_ cities: [City]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-picker-\(UUID().uuidString)")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("cities"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("stories"), to: directory.appendingPathComponent("stories"))
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("items"), to: directory.appendingPathComponent("items"))
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("pets"), to: directory.appendingPathComponent("pets"))
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("sprites"), to: directory.appendingPathComponent("sprites"))
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("boxes.json"), to: directory.appendingPathComponent("boxes.json"))
        try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent("weekly-mail.json"), to: directory.appendingPathComponent("weekly-mail.json"))
        let encoder = JSONEncoder()
        let manifest: [String: Any] = ["formatVersion": 1, "packVersion": 1, "minAppVersion": "1.0.0"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        for file in ["tags.json", "wish.json", "road-clues.json"] {
            try FileManager.default.copyItem(at: contentDirectory.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        let countries = Dictionary(uniqueKeysWithValues: Set(cities.map(\.countryCode)).map { ($0, ["en": $0, "zh-Hans": $0]) })
        try encoder.encode(countries).write(to: directory.appendingPathComponent("countries.json"))
        try (cities.map(\.id).joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("published-ids.txt"), atomically: true, encoding: .utf8)
        for city in cities {
            try encoder.encode(city).write(to: directory.appendingPathComponent("cities/\(city.id).json"))
        }
        catalog = try CityCatalog.load(directory: directory)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func pick(_ catalog: CityCatalog, seed: UInt32, currentCityId: String = "home", route: [String] = ["home"], medianFuel: Int = 0) -> String {
    DestinationPicker.pick(
        from: Coordinate(lat: 0, lon: 0), currentCityId: currentCityId, route: route,
        stampedCountries: ["CN"], medianFuel: medianFuel, catalog: catalog, seed: seed
    )
}

@Suite struct DestinationPickerTests {
    @Test func excludesCurrentRecentAndRetiredCitiesButAllowsOlderVisits() throws {
        let box = try PickerCatalogSandbox([
            pickerCity("a", km: 0), pickerCity("b", km: 50), pickerCity("c", km: 100),
            pickerCity("d", km: 150), pickerCity("e", km: 200), pickerCity("retired", km: 250, status: "retired"),
        ])
        defer { box.cleanUp() }
        let route = ["a", "b", "c", "d", "e"]
        let eligible = DestinationPicker.candidates(currentCityId: "e", route: route, catalog: box.catalog)
        #expect(eligible.map(\.id) == ["a"])
        let selected = Set((0..<200).map { pick(box.catalog, seed: UInt32($0), currentCityId: "e", route: route) })
        #expect(selected == ["a"])
    }

    @Test func currentCityOutsideRouteSuffixStillExcludesTheLastThreeStops() throws {
        let box = try PickerCatalogSandbox([
            pickerCity("home", km: 0), pickerCity("older", km: 50), pickerCity("a", km: 100),
            pickerCity("b", km: 150), pickerCity("c", km: 200), pickerCity("retired", km: 250, status: "retired"),
            pickerCity("fresh", km: 300),
        ])
        defer { box.cleanUp() }
        let route = ["home", "older", "a", "b", "c"]
        let eligible = DestinationPicker.candidates(currentCityId: "home", route: route, catalog: box.catalog)
        #expect(eligible.map(\.id) == ["fresh", "older"])
        let selected = Set((0..<200).map { pick(box.catalog, seed: UInt32($0), route: route) })
        #expect(selected == ["fresh", "older"])
    }

    @Test(arguments: [UInt32(0), 42, UInt32.max])
    func adjacentStopsDoNotShareOffsetRandomNumbers(seed: UInt32) {
        var currentStop = SplitMix64(seed: seed, stopCount: 7)
        var nextStop = SplitMix64(seed: seed, stopCount: 8)
        _ = currentStop.next()
        #expect(currentStop.next() != nextStop.next())
    }

    @Test func emptyPoolRelaxesOnlyTheRecentStopExclusion() throws {
        let box = try PickerCatalogSandbox([
            pickerCity("home", km: 0), pickerCity("a", km: 100), pickerCity("b", km: 200),
            pickerCity("retired", km: 250, status: "retired"),
        ])
        defer { box.cleanUp() }
        let route = ["a", "b", "home"]
        #expect(DestinationPicker.candidates(currentCityId: "home", route: route, catalog: box.catalog).map(\.id) == ["a", "b"])
        #expect(Set((0..<200).map { pick(box.catalog, seed: UInt32($0), route: route) }) == ["a", "b"])
    }

    @Test func distanceBandsUseInclusiveIntegerBoundariesAndTheMinimumMedian() {
        let minimum = 300 * fuelPerKm
        for median in [0, 1, minimum - 1, minimum, minimum * 2] {
            let m = max(minimum, median)
            #expect(DestinationPicker.band(distanceFuel: m, medianFuel: median) == .near)
            #expect(DestinationPicker.band(distanceFuel: m + 1, medianFuel: median) == .middle)
            #expect(DestinationPicker.band(distanceFuel: m * 3, medianFuel: median) == .middle)
            #expect(DestinationPicker.band(distanceFuel: m * 3 + 1, medianFuel: median) == .far)
        }
    }

    @Test func bandWeightsAreExactAndEmptyBandsHaveZeroWeight() throws {
        let home = pickerCity("home", km: 0)
        let cities = [pickerCity("near", km: 100), pickerCity("middle", km: 600), pickerCity("far", km: 1500)]
        #expect(DestinationPicker.bandWeights(for: cities.map { [$0] }) == [5, 4, 1])
        // Cover every nonempty subset, including single remaining bands.
        for mask in 1..<8 {
            let bands = cities.enumerated().map { mask & (1 << $0.offset) == 0 ? [] : [$0.element] }
            let expected = [5, 4, 1].enumerated().map { mask & (1 << $0.offset) == 0 ? 0 : $0.element }
            #expect(DestinationPicker.bandWeights(for: bands) == expected)
            let box = try PickerCatalogSandbox([home] + bands.flatMap { $0 })
            defer { box.cleanUp() }
            let eligible = Set(bands.flatMap { $0 }.map(\.id))
            for seed in 0..<100 { #expect(eligible.contains(pick(box.catalog, seed: UInt32(seed)))) }
        }
    }

    @Test func allCityWeightCombinationsMultiplyExactlyOnce() {
        for mask in 0..<16 {
            let unvisited = mask & 1 != 0
            let newCountry = mask & 2 != 0
            let wish = mask & 4 != 0
            let content = mask & 8 != 0
            let city = pickerCity("city", km: 100, level: content ? "facts" : "basic", tags: ["coast", "food"])
            let weight = DestinationPicker.cityWeight(
                city, route: unvisited ? [] : ["city"], stampedCountries: newCountry ? [] : ["CN"],
                wishTags: wish ? ["coast", "food"] : ["art"]
            )
            let expected = 4 * (unvisited ? 3 : 1) * (newCountry ? 2 : 1) * (wish ? 3 : 1) * (content ? 2 : 1)
            #expect(weight == expected)
            if mask == 15 { #expect(weight == 144) }
        }
        #expect(DestinationPicker.cityWeight(pickerCity("full", km: 100, level: "full"), route: ["full"], stampedCountries: ["CN"], wishTags: []) == 8)
    }

    @Test func fiveThousandSeedsFollowTheDistanceBandDistribution() throws {
        let box = try PickerCatalogSandbox([
            pickerCity("home", km: 0), pickerCity("near", km: 100), pickerCity("middle", km: 600), pickerCity("far", km: 1500),
        ])
        defer { box.cleanUp() }
        var counts: [String: Int] = [:]
        for seed in 0..<5000 { counts[pick(box.catalog, seed: UInt32(seed)), default: 0] += 1 }
        for (id, expected) in [("near", 0.5), ("middle", 0.4), ("far", 0.1)] {
            #expect(abs(Double(counts[id, default: 0]) / 5000 - expected) <= 0.03)
        }
    }

    @Test func firstStopAlwaysComesFromNearbyContentCities() throws {
        let box = try PickerCatalogSandbox([
            pickerCity("home", km: 0), pickerCity("basic", km: 1), pickerCity("a", km: 100, level: "facts"),
            pickerCity("b", km: 250, country: "JP", level: "full"), pickerCity("distant", km: 500, level: "facts"),
            pickerCity("retired", km: 2, level: "full", status: "retired"),
        ])
        defer { box.cleanUp() }
        var selected: Set<String> = []
        for seed in 0..<200 {
            let state = JourneyState(seed: UInt32(seed), startCityId: "home", date: "2026-01-01", catalog: box.catalog)
            #expect(["a", "b"].contains(state.targetCityId))
            selected.insert(state.targetCityId)
        }
        #expect(selected == ["a", "b"])
    }

    @Test(arguments: [false, true])
    func firstStopFallsBackToNearestContentThenNearestCity(allBasic: Bool) throws {
        let box = try PickerCatalogSandbox([
            pickerCity("home", km: 0), pickerCity("basic", km: 1),
            pickerCity("b", km: 500, level: allBasic ? "basic" : "facts"),
            pickerCity("a", km: 500, level: allBasic ? "basic" : "full"),
            pickerCity("retired", km: 2, level: "full", status: "retired"),
        ])
        defer { box.cleanUp() }
        for seed in 0..<20 {
            let state = JourneyState(seed: UInt32(seed), startCityId: "home", date: "2026-01-01", catalog: box.catalog)
            #expect(state.targetCityId == (allBasic ? "basic" : "a"))
        }
    }

    @Test func allBasicFirstStopBreaksEqualDistancesById() throws {
        let box = try PickerCatalogSandbox([pickerCity("home", km: 0), pickerCity("z", km: 100), pickerCity("a", km: 100)])
        defer { box.cleanUp() }
        #expect(JourneyState(seed: 7, startCityId: "home", date: "2026-01-01", catalog: box.catalog).targetCityId == "a")
    }

    @Test func honoluluGetsTheNearestContentFirstStopInTheExpandedCatalog() throws {
        let home = testCatalog.city("honolulu")
        let candidates = testCatalog.active.filter { $0.id != home.id && $0.level != "basic" }
        let nearest = try #require(candidates.min {
            let left = JourneyState.cost(from: home, to: $0)
            let right = JourneyState.cost(from: home, to: $1)
            return left == right ? $0.id < $1.id : left < right
        })
        let state = JourneyState(seed: 7, startCityId: home.id, date: "2026-01-01", catalog: testCatalog)
        #expect(state.targetCityId == nearest.id)
        #expect(state.legCost == JourneyState.cost(from: home, to: nearest))
    }
}

private func replay(catalog: CityCatalog, seed: UInt32, slices: Int = 1, multiplier: Int = 1) -> JourneyState {
    var state = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-01-01", now: Date(timeIntervalSince1970: 0), catalog: catalog)
    var date = "2026-01-01"
    for day in 0..<35 {
        let fuel = (day % 7 == 0 ? 0 : (day * 7_919_147) % 120_000_000 + 1_000_000) * multiplier
        for slice in 1...slices {
            let value = fuel * slice / slices
            state.sync(today: DayUsage(date: date, fuel: value, byClient: ["codex": value]), calendar: pickerCalendar, catalog: catalog, wishTags: ["coast"])
        }
        let next = DayKey.next(date, calendar: pickerCalendar)
        state.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: fuel, byClient: ["codex": fuel])], calendar: pickerCalendar, catalog: catalog, wishTags: ["coast"])
        date = next
    }
    return state
}

@Suite struct RandomJourneyTests {
    @Test(arguments: [UInt32(0), 42, UInt32.max])
    func replayAndFiveScansPerDayProduceExactlyTheSameJourney(seed: UInt32) {
        let once = replay(catalog: testCatalog, seed: seed)
        let repeated = replay(catalog: testCatalog, seed: seed)
        let sliced = replay(catalog: testCatalog, seed: seed, slices: 5)
        #expect(once.route.count > 20)
        #expect(once.route == repeated.route)
        #expect(once.route == sliced.route)
        #expect(once == repeated)
        #expect(once == sliced)
    }

    @Test func directoryInsertionOrderCannotChangeTheJourney() throws {
        // A fixed permutation avoids relying on system randomness even in this check.
        let sorted = testCatalog.all
        let shuffled = sorted.indices.sorted { ($0 * 37) % sorted.count < ($1 * 37) % sorted.count }.map { sorted[$0] }
        #expect(shuffled.map(\.id) != sorted.map(\.id))
        let box = try PickerCatalogSandbox(shuffled)
        defer { box.cleanUp() }
        #expect(box.catalog.all == sorted)
        let original = replay(catalog: testCatalog, seed: 123)
        let reordered = replay(catalog: box.catalog, seed: 123)
        #expect(original.route == reordered.route)
        #expect(original == reordered)
    }

    @Test func medianUsesOnlyThePreviousFourteenActiveDays() {
        var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-02-01", catalog: testCatalog)
        for day in 1...20 {
            var record = DayRecord()
            record.fuel = day * fuelPerKm
            state.days[String(format: "2026-01-%02d", day)] = record
        }
        state.days["2026-01-31"] = DayRecord()
        var today = DayRecord()
        today.fuel = 1_000_000_000
        state.days["2026-02-01"] = today
        #expect(state.recentDailyFuel(before: "2026-02-01") == 14 * fuelPerKm)
        #expect(state.recentDailyFuel(before: "2026-01-01") == 0)
        #expect(DestinationPicker.band(distanceFuel: 300 * fuelPerKm, medianFuel: state.recentDailyFuel(before: "2026-01-01")) == .near)
    }

    @Test func arrivalDayFuelCannotChangeItsNextDestination() {
        for seed: UInt32 in 0..<200 {
            var low = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-01-01", catalog: testCatalog)
            let fuel = low.legCost
            var high = low
            low.sync(today: DayUsage(date: "2026-01-01", fuel: fuel), catalog: testCatalog)
            let extra = low.legCost - 1
            high.sync(today: DayUsage(date: "2026-01-01", fuel: fuel + extra), catalog: testCatalog)
            #expect(low.route.count == 2 && high.route == low.route)
            #expect(high.targetCityId == low.targetCityId)
            #expect(high.legCost == low.legCost)
            #expect(high.legFuel == extra)
            #expect(low.recentDailyFuel(before: "2026-01-01") == 0)
            #expect(high.recentDailyFuel(before: "2026-01-01") == 0)
        }
    }

    @Test func arrivalDrawUsesHistoricalFuelRatherThanAlwaysUsingTheMinimum() {
        var differsFromMinimum = false
        for seed: UInt32 in 0..<100 {
            var state = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-02-01", catalog: testCatalog)
            var previous = DayRecord()
            previous.fuel = 10_000_000
            state.days["2026-01-31"] = previous
            state.sync(today: DayUsage(date: "2026-02-01", fuel: state.legCost), catalog: testCatalog)
            let stamped = Set(state.stamps.map(\.countryCode))
            let expected = DestinationPicker.pick(
                from: state.legFrom, currentCityId: state.currentCityId, route: state.route,
                stampedCountries: stamped, medianFuel: previous.fuel, catalog: testCatalog, seed: seed
            )
            #expect(state.targetCityId == expected)
            let minimum = DestinationPicker.pick(
                from: state.legFrom, currentCityId: state.currentCityId, route: state.route,
                stampedCountries: stamped, medianFuel: 0, catalog: testCatalog, seed: seed
            )
            if expected != minimum { differsFromMinimum = true }
        }
        #expect(differsFromMinimum)
    }

    @Test func wishTagsReachBothLiveAndFinalizedArrivalDrawsWithoutBeingSaved() throws {
        var initial = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-01-01", now: Date(timeIntervalSince1970: 0), catalog: testCatalog)
        initial.sync(today: DayUsage(date: "2026-01-01", fuel: 123), catalog: testCatalog)
        let usage = DayUsage(date: "2026-01-01", fuel: initial.legCost)
        let wishes: Set<String> = ["coast", "food"]
        var live = initial
        var finalized = initial
        live.sync(today: usage, catalog: testCatalog, wishTags: wishes)
        let expected = DestinationPicker.pick(
            from: initial.legTo, currentCityId: initial.targetCityId, route: live.route,
            stampedCountries: Set(live.stamps.map(\.countryCode)), medianFuel: 0, wishTags: wishes, catalog: testCatalog, seed: initial.seed
        )
        #expect(live.targetCityId == expected)
        live.sync(today: DayUsage(date: "2026-01-02"), finalized: [usage], calendar: pickerCalendar, catalog: testCatalog, wishTags: wishes)
        finalized.sync(today: DayUsage(date: "2026-01-02"), finalized: [usage], calendar: pickerCalendar, catalog: testCatalog, wishTags: wishes)
        #expect(live == finalized)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(live)) as? [String: Any])
        #expect(json["wishTags"] == nil)
    }

    @Test(arguments: [UInt32(0), 42, UInt32.max])
    func aYearOfVariableUsageAllowsRevisitsAndHonorsEveryExclusion(seed: UInt32) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("cities/tokyo.json") { $0["status"] = "retired" }
        let catalog = try CityCatalog.load(directory: box.directory)
        var state = JourneyState(seed: seed, startCityId: "shanghai", date: "2026-01-01", catalog: catalog)
        var date = "2026-01-01"
        for day in 0..<365 {
            let fuel = day % 9 == 0 ? 0 : (day * 7_919_147) % 180_000_000 + 1_000_000
            let oldCount = state.route.count
            state.sync(today: DayUsage(date: date, fuel: fuel), calendar: pickerCalendar, catalog: catalog)
            // Check every intermediate arrival, including multiple arrivals in a single sync.
            for index in oldCount..<state.route.count {
                let arrived = state.route[index]
                let previous = state.route[index - 1]
                let recent = Set(state.route[..<(index - 1)].suffix(3))
                let strict = catalog.active.filter { $0.id != previous && !recent.contains($0.id) }
                #expect(arrived != previous)
                #expect(arrived != "tokyo")
                #expect(catalog.find(arrived)?.status == "active")
                if !strict.isEmpty { #expect(!recent.contains(arrived)) }
            }
            let recent = Set(state.route.dropLast().suffix(3))
            let strict = catalog.active.filter { $0.id != state.currentCityId && !recent.contains($0.id) }
            #expect(state.targetCityId != state.currentCityId && state.targetCityId != "tokyo")
            if !strict.isEmpty { #expect(!recent.contains(state.targetCityId)) }
            date = DayKey.next(date, calendar: pickerCalendar)
        }
        #expect(state.route.count > 100)
        #expect(Set(state.route).count < state.route.count)
        #expect(!state.route.contains("tokyo"))
    }

    @Test func doublingUsagePreservesLetterCountsDatesAndDeliveryTimes() {
        let normal = replay(catalog: testCatalog, seed: 42)
        let doubled = replay(catalog: testCatalog, seed: 42, multiplier: 2)
        #expect(normal.letters.count == 31)
        #expect(doubled.letters.count == normal.letters.count)
        #expect(doubled.letters.map(\.date) == normal.letters.map(\.date))
        #expect(doubled.letters.map(\.deliverAt) == normal.letters.map(\.deliverAt))
        #expect(doubled.letters.map(\.kind) == normal.letters.map(\.kind))
        #expect(doubled.totalFuel == normal.totalFuel * 2)
    }
}
