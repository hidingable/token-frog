import Foundation

public struct Coordinate: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    public func distanceKm(to other: Coordinate) -> Double {
        let radius = 6371.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}

public struct City: Codable, Equatable, Sendable, Identifiable {
    public struct Fact: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var type: String
        public var names: [String: String]
        public var sources: [String]
        public var summary: [String: String]? = nil
    }

    public var id: String
    public var status: String
    public var lat: Double
    public var lon: Double
    public var countryCode: String
    public var continent: String
    public var tags: [String]
    public var level: String
    public var names: [String: String]
    public var wikipedia: [String: String]
    public var facts: [Fact]
    public var rainyMonths: [Int] = []
    public var tier: Int = 2
    public var wikidata: String? = nil
    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
    public var isPlaceholder: Bool { status == "placeholder" }

    fileprivate static func placeholder(_ id: String) -> City {
        City(id: id, status: "placeholder", lat: 0, lon: 0, countryCode: "ZZ", continent: "", tags: [], level: "basic", names: [:], wikipedia: [:], facts: [])
    }
}

extension City {
    private enum CodingKeys: String, CodingKey {
        case id, status, lat, lon, countryCode, continent, tags, level, names, wikipedia, facts, rainyMonths, tier, wikidata
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        lat = try values.decode(Double.self, forKey: .lat)
        lon = try values.decode(Double.self, forKey: .lon)
        countryCode = try values.decode(String.self, forKey: .countryCode)
        continent = try values.decode(String.self, forKey: .continent)
        tags = try values.decode([String].self, forKey: .tags)
        level = try values.decode(String.self, forKey: .level)
        names = try values.decode([String: String].self, forKey: .names)
        wikipedia = try values.decode([String: String].self, forKey: .wikipedia)
        facts = try values.decode([Fact].self, forKey: .facts)
        rainyMonths = values.contains(.rainyMonths) ? try values.decode([Int].self, forKey: .rainyMonths) : []
        tier = try values.decodeIfPresent(Int.self, forKey: .tier) ?? 2
        guard (1...4).contains(tier) else {
            throw DecodingError.dataCorruptedError(forKey: .tier, in: values, debugDescription: "Tier must be in 1...4")
        }
        wikidata = try values.decodeIfPresent(String.self, forKey: .wikidata)?.lowercased()
    }
}

/// A parsed content snapshot. Full content validation belongs to the content tests.
public struct CityCatalog: Sendable {
    public let all: [City]
    public let stories: StoryLibrary
    public let pets: PetCatalog
    public let items: ItemLibrary
    public let active: [City]
    private let byId: [String: City]
    private let countries: [String: [String: String]]
    private let lists = CityListCache()

    private init(cities: CityContent, countries: [String: [String: String]], stories: StoryLibrary, items: ItemLibrary, pets: PetCatalog) {
        all = cities.cities.sorted { $0.id < $1.id }
        active = all.filter { $0.status == "active" }
        var index = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for (alias, id) in cities.aliases { index[alias] = index[id] }
        byId = index
        self.countries = countries
        self.stories = stories
        self.items = items
        self.pets = pets
    }

    public static func load(directory: URL) throws -> CityCatalog {
        try ContentValidator.parseManifest(directory: directory)
        return try CityCatalog(
            cities: CityContent.load(directory: directory),
            countries: ContentValidator.readCountries(directory: directory),
            stories: StoryLibrary(stories: ContentValidator.readStories(directory: directory).flatMap(\.stories)),
            items: ItemLibrary(
                items: ContentValidator.readItems(directory: directory).flatMap(\.items),
                boxes: ContentValidator.readBoxes(directory: directory)
            ),
            pets: PetCatalog.parse(directory: directory)
        )
    }

    public func find(_ id: String) -> City? { byId[id.lowercased()] }
    public func city(_ id: String) -> City { find(id) ?? .placeholder(id) }
    public func countryNames(_ code: String) -> [String: String]? { countries[code] }

    public func cities(matching query: String = "", language: Language) -> [City] {
        lists.cities(active, matching: query, language: language)
    }
}
