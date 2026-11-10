public enum DestinationPicker {
    struct Configuration: Sendable {
        let recentActiveDays = 14
        let excludedStops = 3
        let minimumMedianKm = 300.0
        let middleDistanceMultiplier = 3
        let bandWeights = [5, 4, 1]
        let baseCityWeight = 1
        let unvisitedMultiplier = 3
        let newCountryMultiplier = 2
        let wishMultiplier = 3
        let revisitMultiplier = 3
        let contentMultiplier = 2
        let tierMultipliers = [8, 4, 2, 1]
    }

    static let configuration = Configuration()

    enum Band: Int, CaseIterable { case near, middle, far }

    static func band(distanceKm: Double, medianKm: Double) -> Band {
        let median = max(configuration.minimumMedianKm, medianKm)
        if distanceKm <= median { return .near }
        if distanceKm <= Double(configuration.middleDistanceMultiplier) * median { return .middle }
        return .far
    }

    static func bandWeights(for bands: [[City]]) -> [Int] {
        Band.allCases.map { bands[$0.rawValue].isEmpty ? 0 : configuration.bandWeights[$0.rawValue] }
    }

    static func cityWeight(_ city: City, route: [String], stampedCountries: Set<String>, wishTags: Set<String>, revisitCities: Set<String> = []) -> Int {
        cityWeight(city, visited: Set(route), stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities)
    }

    private static func cityWeight(_ city: City, visited: Set<String>, stampedCountries: Set<String>, wishTags: Set<String>, revisitCities: Set<String>) -> Int {
        var weight = configuration.baseCityWeight * configuration.tierMultipliers[city.tier - 1]
        if !visited.contains(city.id) { weight *= configuration.unvisitedMultiplier }
        if !stampedCountries.contains(city.countryCode) { weight *= configuration.newCountryMultiplier }
        if !wishTags.isDisjoint(with: city.tags) { weight *= configuration.wishMultiplier }
        if revisitCities.contains(city.id) { weight *= configuration.revisitMultiplier }
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
        medianKm: Double, wishTags: Set<String> = [], revisitCities: Set<String> = [], catalog: CityCatalog, seed: UInt32, tripCount: Int = 0
    ) -> String {
        var bands = Array(repeating: [City](), count: Band.allCases.count)
        let route = route.map { catalog.city($0).id }
        for city in candidates(currentCityId: currentCityId, route: route, catalog: catalog) {
            let band = band(distanceKm: coordinate.distanceKm(to: city.coordinate), medianKm: medianKm)
            bands[band.rawValue].append(city)
        }
        var random = SplitMix64(seed: seed, stopCount: tripCount)
        let selectedBand = draw(weights: bandWeights(for: bands), random: &random)
        return drawCity(bands[selectedBand], route: route, stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities, random: &random)
    }

    static func first(
        from coordinate: Coordinate, currentCityId: String, route: [String], stampedCountries: Set<String>,
        wishTags: Set<String> = [], revisitCities: Set<String> = [], catalog: CityCatalog, seed: UInt32
    ) -> String {
        let route = route.map { catalog.city($0).id }
        let cities = candidates(currentCityId: currentCityId, route: route, catalog: catalog)
        let withContent = cities.filter { $0.level != "basic" }
        let near = withContent.filter {
            coordinate.distanceKm(to: $0.coordinate) <= configuration.minimumMedianKm
        }
        if !near.isEmpty {
            var random = SplitMix64(seed: seed, stopCount: 0)
            return drawCity(near, route: route, stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities, random: &random)
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
        _ cities: [City], route: [String], stampedCountries: Set<String>, wishTags: Set<String>, revisitCities: Set<String>, random: inout SplitMix64
    ) -> String {
        let visited = Set(route)
        let weights = cities.map { cityWeight($0, visited: visited, stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities) }
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
