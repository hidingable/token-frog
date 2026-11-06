public enum DestinationPicker {
    struct Configuration: Sendable {
        let recentActiveDays = 14
        let excludedStops = 3
        let minimumMedianFuel = 300 * fuelPerKm
        let middleDistanceMultiplier = 3
        let bandWeights = [5, 4, 1]
        let baseCityWeight = 1
        let unvisitedMultiplier = 3
        let newCountryMultiplier = 2
        let wishMultiplier = 3
        let contentMultiplier = 2
        let tierMultipliers = [8, 4, 2, 1]
    }

    static let configuration = Configuration()

    enum Band: Int, CaseIterable { case near, middle, far }

    static func band(distanceFuel: Int, medianFuel: Int) -> Band {
        let median = max(configuration.minimumMedianFuel, medianFuel)
        if distanceFuel <= median { return .near }
        // Division keeps the integer comparison exact without overflowing 3 * median.
        if (distanceFuel - 1) / configuration.middleDistanceMultiplier < median { return .middle }
        return .far
    }

    static func bandWeights(for bands: [[City]]) -> [Int] {
        Band.allCases.map { bands[$0.rawValue].isEmpty ? 0 : configuration.bandWeights[$0.rawValue] }
    }

    static func cityWeight(_ city: City, route: [String], stampedCountries: Set<String>, wishTags: Set<String>) -> Int {
        cityWeight(city, visited: Set(route), stampedCountries: stampedCountries, wishTags: wishTags)
    }

    private static func cityWeight(_ city: City, visited: Set<String>, stampedCountries: Set<String>, wishTags: Set<String>) -> Int {
        var weight = configuration.baseCityWeight * configuration.tierMultipliers[city.tier - 1]
        if !visited.contains(city.id) { weight *= configuration.unvisitedMultiplier }
        if !stampedCountries.contains(city.countryCode) { weight *= configuration.newCountryMultiplier }
        if !wishTags.isDisjoint(with: city.tags) { weight *= configuration.wishMultiplier }
        if city.level != "basic" { weight *= configuration.contentMultiplier }
        return weight
    }

    static func candidates(currentCityId: String, route: [String], catalog: CityCatalog) -> [City] {
        let current = catalog.city(currentCityId).id
        let active = catalog.active.filter { $0.id != current }
        let previousStops = route.last.map({ catalog.city($0).id }) == current ? route.dropLast() : route[...]
        let recent = Set(previousStops.suffix(configuration.excludedStops).map { catalog.city($0).id })
        let candidates = active.filter { !recent.contains($0.id) }
        return candidates.isEmpty ? active : candidates
    }

    public static func pick(
        from coordinate: Coordinate, currentCityId: String, route: [String], stampedCountries: Set<String>,
        medianFuel: Int, wishTags: Set<String> = [], catalog: CityCatalog, seed: UInt32
    ) -> String {
        var bands = Array(repeating: [City](), count: Band.allCases.count)
        let route = route.map { catalog.city($0).id }
        for city in candidates(currentCityId: currentCityId, route: route, catalog: catalog) {
            let band = band(distanceFuel: JourneyState.cost(from: coordinate, to: city.coordinate), medianFuel: medianFuel)
            bands[band.rawValue].append(city)
        }
        var random = SplitMix64(seed: seed, stopCount: route.count)
        let selectedBand = draw(weights: bandWeights(for: bands), random: &random)
        return drawCity(bands[selectedBand], route: route, stampedCountries: stampedCountries, wishTags: wishTags, random: &random)
    }

    static func first(
        from coordinate: Coordinate, currentCityId: String, route: [String], stampedCountries: Set<String>,
        wishTags: Set<String> = [], catalog: CityCatalog, seed: UInt32
    ) -> String {
        let route = route.map { catalog.city($0).id }
        let cities = candidates(currentCityId: currentCityId, route: route, catalog: catalog)
        let withContent = cities.filter { $0.level != "basic" }
        let near = withContent.filter {
            JourneyState.cost(from: coordinate, to: $0.coordinate) <= configuration.minimumMedianFuel
        }
        if !near.isEmpty {
            var random = SplitMix64(seed: seed, stopCount: route.count)
            return drawCity(near, route: route, stampedCountries: stampedCountries, wishTags: wishTags, random: &random)
        }
        let nearest = (withContent.isEmpty ? cities : withContent).min {
            let left = JourneyState.cost(from: coordinate, to: $0.coordinate)
            let right = JourneyState.cost(from: coordinate, to: $1.coordinate)
            return left == right ? $0.id < $1.id : left < right
        }
        // AppModel requires at least two active cities before starting or resuming.
        return nearest!.id
    }

    private static func drawCity(
        _ cities: [City], route: [String], stampedCountries: Set<String>, wishTags: Set<String>, random: inout SplitMix64
    ) -> String {
        let visited = Set(route)
        let weights = cities.map { cityWeight($0, visited: visited, stampedCountries: stampedCountries, wishTags: wishTags) }
        return cities[draw(weights: weights, random: &random)].id
    }

    private static func draw(weights: [Int], random: inout SplitMix64) -> Int {
        let total = weights.reduce(0, +)
        precondition(total > 0, "A destination requires at least one eligible city")
        var ticket = Int(random.next() % UInt64(total))
        for (index, weight) in weights.enumerated() {
            if ticket < weight { return index }
            ticket -= weight
        }
        preconditionFailure("Destination weights must cover the draw")
    }
}
