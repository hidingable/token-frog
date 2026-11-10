public enum DestinationPicker {
    struct Configuration: Sendable {
        let recentActiveDays = 14
        let excludedStops = 3
        let minimumMedianKm = 300.0
        let reachableTodayMinimumMultiplier = 0.3
        let reachableTodayMaximumMultiplier = 0.8
        let wanderMaximumMultiplier = 5.0
        let reachableTodayWeight = 80
        let wanderWeight = 20
        let baseCityWeight = 1
        let unvisitedMultiplier = 3
        let newCountryMultiplier = 2
        let wishMultiplier = 3
        let revisitMultiplier = 3
        let contentMultiplier = 2
        let tierMultipliers = [8, 4, 2, 1]
    }

    static let configuration = Configuration()

    enum Band: Int, CaseIterable {
        case reachableToday, wander

        func contains(distanceKm: Double, medianKm: Double) -> Bool {
            let median = max(configuration.minimumMedianKm, medianKm)
            switch self {
            case .reachableToday:
                return (configuration.reachableTodayMinimumMultiplier * median...configuration.reachableTodayMaximumMultiplier * median).contains(distanceKm)
            case .wander:
                return distanceKm <= configuration.wanderMaximumMultiplier * median
            }
        }
    }

    static func bandWeights(for bands: [[City]]) -> [Int] {
        let weights = [configuration.reachableTodayWeight, configuration.wanderWeight]
        return Band.allCases.map { bands[$0.rawValue].isEmpty ? 0 : weights[$0.rawValue] }
    }

    static func drawBand(from bands: [[City]], random: inout SplitMix64) -> Band {
        Band.allCases[draw(weights: bandWeights(for: bands), random: &random)]
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
        let cities = candidates(currentCityId: currentCityId, route: route, catalog: catalog)
        for city in cities {
            let distance = coordinate.distanceKm(to: city.coordinate)
            // Wander includes reachable-today cities as well as other cities within its cap.
            for band in Band.allCases where band.contains(distanceKm: distance, medianKm: medianKm) {
                bands[band.rawValue].append(city)
            }
        }
        if bands.allSatisfy(\.isEmpty) { return nearestCity(cities, from: coordinate) }
        var random = SplitMix64(seed: seed, stopCount: tripCount)
        let selectedBand = drawBand(from: bands, random: &random)
        return drawCity(bands[selectedBand.rawValue], route: route, stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities, random: &random)
    }

    static func first(
        from coordinate: Coordinate, currentCityId: String, route: [String], stampedCountries: Set<String>,
        wishTags: Set<String> = [], revisitCities: Set<String> = [], catalog: CityCatalog, seed: UInt32
    ) -> String {
        let route = route.map { catalog.city($0).id }
        let cities = candidates(currentCityId: currentCityId, route: route, catalog: catalog)
        let withContent = cities.filter { $0.level != "basic" }
        let reachable = withContent.filter {
            Band.reachableToday.contains(distanceKm: coordinate.distanceKm(to: $0.coordinate), medianKm: configuration.minimumMedianKm)
        }
        if !reachable.isEmpty {
            var random = SplitMix64(seed: seed, stopCount: 0)
            return drawCity(reachable, route: route, stampedCountries: stampedCountries, wishTags: wishTags, revisitCities: revisitCities, random: &random)
        }
        return nearestCity(withContent.isEmpty ? cities : withContent, from: coordinate)
    }

    private static func nearestCity(_ cities: [City], from coordinate: Coordinate) -> String {
        let nearest = cities.min {
            let left = coordinate.distanceKm(to: $0.coordinate)
            let right = coordinate.distanceKm(to: $1.coordinate)
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
