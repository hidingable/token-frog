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
    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
    public var isPlaceholder: Bool { status == "placeholder" }

    fileprivate static func placeholder(_ id: String) -> City {
        City(id: id, status: "placeholder", lat: 0, lon: 0, countryCode: "ZZ", continent: "", tags: [], level: "basic", names: [:], wikipedia: [:], facts: [])
    }
}

extension City {
    private enum CodingKeys: String, CodingKey {
        case id, status, lat, lon, countryCode, continent, tags, level, names, wikipedia, facts, rainyMonths
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
    }
}

/// A validated content snapshot. Its order is independent of filesystem enumeration.
public struct CityCatalog: Sendable {
    public let all: [City]
    public let stories: StoryLibrary
    public let pets: PetCatalog
    public let items: ItemLibrary
    public var active: [City] { all.filter { $0.status == "active" } }
    private let byId: [String: City]
    private let countries: [String: [String: String]]

    private init(cities: [City], countries: [String: [String: String]], stories: StoryLibrary, items: ItemLibrary, pets: PetCatalog) {
        all = cities.sorted { $0.id < $1.id }
        byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        self.countries = countries
        self.stories = stories
        self.items = items
        self.pets = pets
    }

    public static func load(directory: URL) throws -> CityCatalog {
        let issues = ContentValidator.validate(directory: directory)
        guard issues.isEmpty else { throw ContentValidationError(issues: issues) }
        return try CityCatalog(
            cities: ContentValidator.readCities(directory: directory).map(\.city),
            countries: ContentValidator.readCountries(directory: directory),
            stories: StoryLibrary(stories: ContentValidator.readStories(directory: directory).flatMap(\.stories)),
            items: ItemLibrary(
                items: ContentValidator.readItems(directory: directory).flatMap(\.items),
                boxes: ContentValidator.readBoxes(directory: directory)
            ),
            pets: PetCatalog.load(directory: directory)
        )
    }

    public func find(_ id: String) -> City? { byId[id] }
    public func city(_ id: String) -> City { find(id) ?? .placeholder(id) }
    public func countryNames(_ code: String) -> [String: String]? { countries[code] }
}
