import Foundation

public struct ContentIssue: Equatable, Sendable {
    public let file: String
    public let rule: String
    public let message: String
}

public struct ContentValidationError: Error, Sendable {
    public let issues: [ContentIssue]
}

public enum ContentValidator {
    private struct Manifest: Decodable {
        let formatVersion: Int
        let packVersion: Int
        let minAppVersion: String
    }

    static func cityFiles(directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("cities"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readCities(directory: URL) throws -> [(file: URL, city: City)] {
        try cityFiles(directory: directory).map { ($0, try JSONDecoder().decode(City.self, from: Data(contentsOf: $0))) }
    }

    static func readCountries(directory: URL) throws -> [String: [String: String]] {
        try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: directory.appendingPathComponent("countries.json")))
    }

    public static func validate(directory: URL) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        let decoder = JSONDecoder()
        let regions = Set(Locale.Region.isoRegions.map(\.identifier))
        func complete(_ names: [String: String]) -> Bool {
            ["zh-Hans", "en"].allSatisfy { !(names[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        do {
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            if manifest.formatVersion != 1 || manifest.packVersion < 1
                || manifest.minAppVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil {
                report("manifest.json", "manifest", "Unsupported or invalid manifest fields")
            }
        } catch { report("manifest.json", "manifest", "Cannot read a complete manifest: \(error)") }

        var tags: Set<String> = []
        do {
            let values = try decoder.decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("tags.json")))
            tags = Set(values)
            if tags.isEmpty || tags.count != values.count || tags.contains("") {
                report("tags.json", "tags", "Tags must be nonempty and unique")
            }
        } catch { report("tags.json", "tags", "Cannot read tags: \(error)") }

        var countries: [String: [String: String]] = [:]
        do {
            countries = try readCountries(directory: directory)
            for code in countries.keys.sorted() {
                if !regions.contains(code) || code.count != 2 {
                    report("countries.json", "countryCode", "Invalid ISO region code: \(code)")
                }
                if !complete(countries[code]!) {
                    report("countries.json", "countryNames", "Country \(code) requires zh-Hans and en names")
                }
            }
        } catch { report("countries.json", "countries", "Cannot read country names: \(error)") }

        var published: Set<String> = []
        do {
            let text = try String(contentsOf: directory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
            published = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        } catch { report("published-ids.txt", "published", "Cannot read published IDs: \(error)") }

        let files: [URL]
        do { files = try cityFiles(directory: directory) }
        catch {
            report("cities", "cities", "Cannot read cities: \(error)")
            return issues
        }
        var ids: Set<String> = []
        let continents: Set<String> = ["asia", "europe", "africa", "north-america", "south-america", "oceania"]
        for file in files {
            let path = "cities/\(file.lastPathComponent)"
            let city: City
            do { city = try decoder.decode(City.self, from: Data(contentsOf: file)) }
            catch { report(path, "cityJSON", "Cannot decode city: \(error)"); continue }
            if city.id.isEmpty || file.deletingPathExtension().lastPathComponent != city.id {
                report(path, "filename", "Filename must equal the city ID")
            }
            if !ids.insert(city.id).inserted { report(path, "uniqueID", "Duplicate city ID") }
            if !["active", "retired"].contains(city.status) { report(path, "status", "Invalid city status") }
            if !["basic", "facts", "full"].contains(city.level) { report(path, "level", "Invalid city level") }
            if !continents.contains(city.continent) { report(path, "continent", "Invalid continent") }
            if !(-90...90).contains(city.lat) || !(-180...180).contains(city.lon) {
                report(path, "coordinate", "Coordinates are out of range")
            }
            if !regions.contains(city.countryCode) || city.countryCode.count != 2 {
                report(path, "countryCode", "Invalid ISO region code")
            } else if countries[city.countryCode] == nil {
                report(path, "countryCode", "Country code is missing from countries.json: \(city.countryCode)")
            }
            if city.tags.isEmpty || !Set(city.tags).isSubset(of: tags) { report(path, "cityTags", "Missing or unknown city tags") }
            if !complete(city.names) { report(path, "names", "City names require zh-Hans and en") }
            if !complete(city.wikipedia) { report(path, "wikipedia", "Wikipedia titles require zh-Hans and en") }
            var facts: Set<String> = []
            for fact in city.facts {
                if fact.id.isEmpty || !facts.insert(fact.id).inserted { report(path, "factID", "Fact IDs must be nonempty and unique within a city") }
                if !complete(fact.names) { report(path, "factNames", "Fact names require zh-Hans and en") }
                if fact.sources.isEmpty || !fact.sources.allSatisfy(validSource) { report(path, "factSources", "Facts require a public HTTPS source") }
            }
        }
        for id in published.subtracting(ids).sorted() { report("published-ids.txt", "publishedMissing", "Published city is missing: \(id)") }
        for id in ids.subtracting(published).sorted() { report("published-ids.txt", "unpublished", "City is not registered: \(id)") }
        return issues
    }

    private static func validSource(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let blocked = ["localhost", "example.org", "example.com", "127.0.0.1", "::1", "[::1]"]
        return !blocked.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
