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
    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
    public var isPlaceholder: Bool { status == "placeholder" }

    fileprivate static func placeholder(_ id: String) -> City {
        City(id: id, status: "placeholder", lat: 0, lon: 0, countryCode: "ZZ", continent: "", tags: [], level: "basic", names: [:], wikipedia: [:], facts: [])
    }
}

/// A validated content snapshot. Its order is independent of filesystem enumeration.
public struct CityCatalog: Sendable {
    public let all: [City]
    public var active: [City] { all.filter { $0.status == "active" } }
    private let byId: [String: City]
    private let countries: [String: [String: String]]

    private init(cities: [City], countries: [String: [String: String]]) {
        all = cities.sorted { $0.id < $1.id }
        byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        self.countries = countries
    }

    public static func load(directory: URL) throws -> CityCatalog {
        let issues = ContentValidator.validate(directory: directory)
        guard issues.isEmpty else { throw ContentValidationError(issues: issues) }
        return try CityCatalog(cities: ContentValidator.readCities(directory: directory).map(\.city), countries: ContentValidator.readCountries(directory: directory))
    }

    public func find(_ id: String) -> City? { byId[id] }
    public func city(_ id: String) -> City { find(id) ?? .placeholder(id) }
    public func countryNames(_ code: String) -> [String: String]? { countries[code] }
}
