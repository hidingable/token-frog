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

    static func storyFiles(directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("stories"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readStories(directory: URL) throws -> [(file: URL, stories: [Story])] {
        try storyFiles(directory: directory).map { ($0, try JSONDecoder().decode([Story].self, from: Data(contentsOf: $0))) }
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
        var cities: [String: City] = [:]
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
            cities[city.id] = city
            if !city.rainyMonths.allSatisfy({ (1...12).contains($0) }) {
                report(path, "rainyMonths", "Rainy months must be in 1...12")
            }
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
        issues += validateStories(directory: directory, cities: cities, tags: tags)
        return issues
    }

    private static func validateStories(directory: URL, cities: [String: City], tags: Set<String>) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        let files: [URL]
        do { files = try storyFiles(directory: directory) }
        catch { return [ContentIssue(file: "stories", rule: "stories", message: "Cannot read stories: \(error)")] }
        var entries: [(file: String, story: Story)] = []
        for file in files {
            let path = "stories/\(file.lastPathComponent)"
            do {
                entries += try JSONDecoder().decode([Story].self, from: Data(contentsOf: file)).map { (path, $0) }
            } catch { report(path, "storyJSON", "Cannot decode stories: \(error)") }
        }
        let habits: Set<String> = ["talkative", "observant"]
        let seasons: Set<String> = ["spring", "summer", "autumn", "winter"]
        let replyIds = Set(entries.flatMap { $0.story.replies.map(\.id) })
        var ids: Set<String> = []
        var seenReplyIds: Set<String> = []
        for (file, story) in entries {
            if story.id.isEmpty || !ids.insert(story.id).inserted { report(file, "storyID", "Story IDs must be nonempty and unique: \(story.id)") }
            if story.version < 1 { report(file, "storyVersion", "Story version must be positive") }
            if !["arrival", "transit", "fulfill"].contains(story.kind) { report(file, "storyKind", "Invalid story kind") }
            if let id = story.cityId, cities[id] == nil { report(file, "storyCity", "Unknown story city: \(id)") }
            let facts = Set(story.cityId.flatMap { cities[$0] }?.facts.map(\.id) ?? [])
            if !Set(story.factIds).isSubset(of: facts) { report(file, "storyFacts", "Unknown facts in story city") }
            if !Set(story.tags).isSubset(of: tags) { report(file, "storyTags", "Unknown story tags") }
            if let habit = story.requires.habit, !habits.contains(habit) { report(file, "storyHabit", "Invalid required habit") }
            if let habit = story.fulfillsHabit, !habits.contains(habit) { report(file, "storyHabit", "Invalid fulfillment habit") }
            if let season = story.requires.season, !seasons.contains(season) { report(file, "storySeason", "Invalid required season") }
            if !Set(story.fulfills).isSubset(of: replyIds) { report(file, "storyFulfills", "Unknown fulfilled reply ID") }
            for reply in story.replies {
                if reply.id.isEmpty || !seenReplyIds.insert(reply.id).inserted { report(file, "replyID", "Reply IDs must be nonempty and globally unique: \(reply.id)") }
                if !habits.contains(reply.habit) { report(file, "storyHabit", "Invalid reply habit") }
            }
            let localizedTexts = [story.text] + (story.lead.map { [$0] } ?? []) + story.replies.map(\.text)
            for texts in localizedTexts {
                if !["zh-Hans", "en"].allSatisfy({ texts[$0] != nil })
                    || texts.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    report(file, "storyTranslation", "Story, lead and replies require nonempty zh-Hans and en")
                }
                let sets = texts.values.map { StorySlots.names(in: $0) }
                if let first = sets.first, !sets.allSatisfy({ $0 == first }) { report(file, "storySlots", "Slots must match in every language") }
                for text in texts.values {
                    let names = StorySlots.names(in: text)
                    let stripped = StorySlots.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                    if !names.isSubset(of: ["pet", "city", "target", "reply"]) || stripped.contains("{") || stripped.contains("}") {
                        report(file, "storySlots", "Unknown or malformed slot")
                    }
                    if names.contains("target") && story.kind != "transit" { report(file, "storyTarget", "Target is only allowed in transit stories") }
                    if names.contains("city") && story.kind == "fulfill" && story.cityId == nil {
                        report(file, "storyCitySlot", "Cityless fulfillment stories cannot use the city slot")
                    }
                    if names.contains("reply") && story.kind != "fulfill" && story.fulfills.isEmpty {
                        report(file, "storyReply", "Reply requires a fulfillment story")
                    }
                    if text.range(of: #"[A-Za-z0-9_]\{|\}[A-Za-z0-9_]|\}['’]s\b"#, options: .regularExpression) != nil {
                        report(file, "storySlotGrammar", "Slots cannot form part of a word or possessive")
                    }
                }
            }
        }
        let generic = entries.map(\.story).filter { $0.cityId == nil && $0.requires.isEmpty }
        for kind in ["arrival", "transit"] where !generic.contains(where: { $0.kind == kind && $0.fulfills.isEmpty }) {
            report("stories", "storyBaseline", "Missing unconditional generic \(kind) story")
        }
        for habit in habits.sorted() where !generic.contains(where: { $0.kind == "fulfill" && $0.fulfills.isEmpty && $0.fulfillsHabit == habit }) {
            report("stories", "storyBaseline", "Missing unconditional generic fulfillment for \(habit)")
        }
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
