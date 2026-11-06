import Foundation

/// Resolves both content layers once, retaining base IDs as aliases for saved journeys.
struct CityContent {
    var cities: [City]
    var aliases: [String: String]

    static func load(directory: URL) throws -> CityContent {
        let base = try readBase(directory: directory)
        let details = try ContentValidator.readCities(directory: directory)
        var cities: [String: City] = [:]
        var baseByWiki: [String: String] = [:]
        var aliases: [String: String] = [:]
        for city in base {
            guard cities.updateValue(city, forKey: city.id) == nil else {
                throw issue("world/cities.tsv", "uniqueID", "Duplicate base city ID: \(city.id)")
            }
            baseByWiki[city.wikidata!] = city.id
        }
        var detailIDs: Set<String> = []
        var detailWikis: Set<String> = []
        for (file, city) in details {
            guard detailIDs.insert(city.id).inserted,
                  city.wikidata.map({ detailWikis.insert($0).inserted }) ?? true else {
                throw issue(file.lastPathComponent, "uniqueID", "Duplicate detail city identity: \(city.id)")
            }
            let matched = Set([cities[city.id]?.id, city.wikidata.flatMap { baseByWiki[$0] }].compactMap { $0 })
            for id in matched {
                if let replaced = cities.removeValue(forKey: id), let wiki = replaced.wikidata {
                    aliases[wiki] = city.id
                }
                aliases[id] = city.id
            }
            cities[city.id] = city
            if let wiki = city.wikidata { aliases[wiki] = city.id }
        }
        return CityContent(cities: Array(cities.values), aliases: aliases)
    }

    static let header = "id\tlat\tlon\tcountryCode\tcontinent\ttier\ten\tzh"

    static func readBase(directory: URL) throws -> [City] {
        let file = directory.appendingPathComponent("world/cities.tsv")
        // Older content packs and small test packs consist solely of per-city JSON.
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let bytes = Array(try Data(contentsOf: file))
        var cities: [City] = []
        cities.reserveCapacity(7400)
        var fields: [String] = []
        fields.reserveCapacity(8)
        var start = 0
        var row = 0
        for end in 0...bytes.count {
            let byte: UInt8 = end == bytes.count ? 10 : bytes[end]
            guard byte == 9 || byte == 10 else { continue }
            if end == bytes.count && start == end { break }
            fields.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end + 1
            guard byte == 10 else { continue }
            row += 1
            if row == 1 {
                guard fields.joined(separator: "\t") == header else {
                    throw issue("world/cities.tsv", "cityTSV", "Invalid TSV header")
                }
            } else {
                guard fields.count == 8, let lat = Double(fields[1]), let lon = Double(fields[2]),
                      let tier = Int(fields[5]), (1...4).contains(tier) else {
                    throw issue("world/cities.tsv", "cityTSV", "Invalid TSV row \(row)")
                }
                cities.append(City(
                    id: fields[0], status: "active", lat: lat, lon: lon, countryCode: fields[3],
                    continent: fields[4], tags: [], level: "basic", names: ["en": fields[6], "zh-Hans": fields[7]],
                    wikipedia: [:], facts: [], tier: tier, wikidata: fields[0]
                ))
            }
            fields.removeAll(keepingCapacity: true)
        }
        guard row > 0 else { throw issue("world/cities.tsv", "cityTSV", "Empty TSV") }
        return cities
    }

    private static func issue(_ file: String, _ rule: String, _ message: String) -> ContentValidationError {
        ContentValidationError(issues: [ContentIssue(file: file, rule: rule, message: message)])
    }
}

/// Immutable catalog copies share language ordering and the most recent search for each language.
/// The lock protects lazy caches when a catalog is shared with background work.
final class CityListCache: @unchecked Sendable {
    private let lock = NSLock()
    private var sorted: [Language: [City]] = [:]
    private var searches: [Language: (query: String, cities: [City])] = [:]
    private var searchNames: [String: String] = [:]

    func cities(_ active: [City], matching query: String, language: Language) -> [City] {
        lock.lock()
        defer { lock.unlock() }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = searches[language], cached.query == query { return cached.cities }
        if sorted[language] == nil {
            let locale = Locale(identifier: language.rawValue)
            let named = active.map { ($0, $0.names[language.rawValue] ?? $0.names["en"] ?? $0.id) }
            sorted[language] = named.sorted {
                let order = $0.1.compare($1.1, locale: locale)
                return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
            }.map(\.0)
        }
        let ordered = sorted[language]!
        if searchNames.isEmpty {
            searchNames = Dictionary(uniqueKeysWithValues: active.map {
                ($0.id, ($0.names["en", default: ""] + "\n" + $0.names["zh-Hans", default: ""]).lowercased())
            })
        }
        let result = query.isEmpty ? ordered : ordered.filter { searchNames[$0.id]!.contains(query) }
        searches[language] = (query, result)
        return result
    }
}
