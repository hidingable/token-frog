import Foundation
import Testing
@testable import VoyageCore

let contentDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Content")
let testCatalog = try! CityCatalog.load(directory: contentDirectory)

// Runtime loading parses only. Tests explicitly request the full content gate.
func validateContent(directory: URL) throws {
    let issues = ContentValidator.validate(directory: directory)
    if !issues.isEmpty { throw ContentValidationError(issues: issues) }
}

struct ContentSandbox {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-content-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: contentDirectory, to: directory)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func edit(_ path: String = "cities/shanghai.json", _ body: (inout [String: Any]) -> Void) throws {
        let file = directory.appendingPathComponent(path)
        if path.hasPrefix("cities/"), !FileManager.default.fileExists(atPath: file.path) {
            let id = file.deletingPathExtension().lastPathComponent
            let city = try #require(CityContent.readBase(directory: directory).first { $0.id == id })
            try JSONEncoder().encode(city).write(to: file)
        }
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        body(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    func remove(_ id: String) throws {
        let detail = directory.appendingPathComponent("cities/\(id).json")
        if FileManager.default.fileExists(atPath: detail.path) {
            try FileManager.default.removeItem(at: detail)
        } else {
            let base = directory.appendingPathComponent("world/cities.tsv")
            let rows = try String(contentsOf: base, encoding: .utf8).split(separator: "\n")
                .filter { !$0.hasPrefix(id + "\t") }
            try (rows.joined(separator: "\n") + "\n").write(to: base, atomically: true, encoding: .utf8)
        }
        let file = directory.appendingPathComponent("published-ids.txt")
        let ids = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { $0 != id }
        try (ids.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

@Test func repositoryContentIsCompleteAndSorted() throws {
    #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
    #expect((6500...7400).contains(testCatalog.active.count))
    #expect(testCatalog.all.map(\.id) == testCatalog.all.map(\.id).sorted())
    #expect(testCatalog.all.allSatisfy { $0.status == "active" && ["basic", "full"].contains($0.level) })
    #expect(testCatalog.all.filter { $0.level == "basic" }.allSatisfy { $0.facts.isEmpty })
    #expect(testCatalog.all.allSatisfy { !$0.isPlaceholder })
    let tags = try JSONDecoder().decode([String].self, from: Data(contentsOf: contentDirectory.appendingPathComponent("tags.json")))
    #expect(Set(tags) == Set(["coast", "island", "mountain", "river", "lake", "desert", "capital", "heritage", "food", "art", "market", "nature"]))
    for file in try ContentValidator.cityFiles(directory: contentDirectory) {
        #expect(try Data(contentsOf: file).last == 10)
    }
    let published = try String(contentsOf: contentDirectory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
    let registered = published.split(separator: "\n").map(String.init)
    #expect(registered == registered.sorted())
    #expect(Set(registered).count == registered.count)
    #expect(registered.allSatisfy { testCatalog.find($0) != nil })
    #expect(Set(testCatalog.all.map(\.id)).isSubset(of: Set(registered)))
}

@Test func cityTagsCoverKnownGeographyAndEveryDeclaredTag() throws {
    #expect(Set(["coast", "capital"]).isSubset(of: Set(testCatalog.city("lisbon").tags)))
    #expect(Set(["coast", "capital", "food"]).isSubset(of: Set(testCatalog.city("tokyo").tags)))
    #expect(testCatalog.city("dubai").tags.contains("desert"))
    #expect(testCatalog.city("havana").tags.contains("coast"))
    let declared = try JSONDecoder().decode([String].self, from: Data(contentsOf: contentDirectory.appendingPathComponent("tags.json")))
    #expect(Set(testCatalog.all.flatMap(\.tags)) == Set(declared))
}

@Test func everyCityHasTwoToFourDistinctTags() {
    for city in try! ContentValidator.readCities(directory: contentDirectory).map(\.city) {
        #expect((2...4).contains(city.tags.count), "\(city.id) must have two to four tags")
        #expect(Set(city.tags).count == city.tags.count, "\(city.id) has duplicate tags")
    }
}

@Test func islandTagsMatchIslandTravelDestinations() {
    let expected: Set<String> = ["bali", "zanzibar", "honolulu", "singapore", "suva", "venice", "reykjavik", "colombo", "havana"]
    let actual = Set(testCatalog.all.filter { $0.tags.contains("island") }.map(\.id))
    #expect(actual == expected)
    for id in ["london", "kyoto", "taipei"] {
        #expect(!testCatalog.city(id).tags.contains("island"))
    }
}

@Test(arguments: [("heritage", 35), ("market", 20), ("art", 25), ("food", 25)])
func broadTravelTagsStaySelective(tag: String, maximum: Int) {
    let count = testCatalog.all.filter { $0.tags.contains(tag) }.count
    // The first sourced batch adds tags for six authored cities to the original budget.
    let expandedMaximum = maximum + firstBatchCityIds.count
    #expect(count <= expandedMaximum, "\(tag) covers \(count) cities; maximum is \(expandedMaximum)")
}

@Test func capitalTagsExcludeHistoricalCapitalsAndOtherGovernmentSeats() {
    for id in ["almaty", "capetown", "colombo", "kyoto", "lapaz", "yangon"] {
        #expect(!testCatalog.city(id).tags.contains("capital"))
    }
}

@Test func countryContentPreservesEveryLegacyChineseName() throws {
    let countries = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: contentDirectory.appendingPathComponent("countries.json")))
    for (name, code) in JourneyMigrations.legacyCountryCodes {
        #expect(countries[code]?["zh-Hans"] == name)
        #expect(testCatalog.countryNames(code) == countries[code])
    }
    #expect(testCatalog.all.allSatisfy { countries[$0.countryCode] != nil })
    #expect(testCatalog.countryNames("invalid") == nil)
    #expect(testCatalog.countryNames("ZZ") == nil)
    #expect(testCatalog.countryNames("AD")?["en"] == "Andorra")
}

private struct M0City: Decodable {
    let id: String
    let name: String
    let country: String
    let lat: Double
    let lon: Double
    let wikiZh: String
    let wikiEn: String
}

@Test func contentExactlyPreservesEveryM0City() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/cities-m0.json")
    let old = try JSONDecoder().decode([M0City].self, from: Data(contentsOf: file))
    #expect(old.count == 107)
    #expect(Set(old.map(\.id)).isSubset(of: Set(testCatalog.all.map(\.id))))
    for entry in old {
        let city = try #require(testCatalog.find(entry.id))
        #expect(city.lat == entry.lat && city.lon == entry.lon)
        #expect(city.names["zh-Hans"] == entry.name)
        #expect(city.wikipedia == ["zh-Hans": entry.wikiZh, "en": entry.wikiEn])
        #expect(city.countryCode == JourneyMigrations.countryCode(for: entry.country))
        #expect(city.countryCode != "ZZ")
    }
    #expect(testCatalog.city("darwin").names["en"] == "Darwin")
    #expect(testCatalog.city("xian").names["en"] == "Xi'an")
    #expect(testCatalog.city("bogota").names["en"] == "Bogotá")
}

@Test(arguments: ["current", "target", "both"])
func removedCitiesLoadAndReachTheirSavedTarget(endpoint: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
    let target = state.targetCityId
    let from = state.legFrom
    let to = state.legTo
    if endpoint != "target" { try box.remove(state.currentCityId) }
    if endpoint != "current" { try box.remove(target) }
    let catalog = try CityCatalog.load(directory: box.directory)
    state = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
    #expect(state.legFrom == from && state.legTo == to)
    for id in [state.currentCityId, target] where catalog.find(id) == nil {
        #expect(catalog.city(id).isPlaceholder)
        #expect(catalog.city(id).names.isEmpty)
    }
    let savedCountry = state.targetCountryCode
    state.sync(today: DayUsage(date: "2026-11-01", fuel: state.legCost + 123), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: state.legCost + 123)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: catalog)
    #expect(state.currentCityId == target)
    #expect(state.phase == .staying && state.legFuel == state.legCost)
    #expect(state.route.last == target)
    #expect(state.targetCityId == target)
    #expect(state.legTo == to)
    if let savedCountry { #expect(state.stamps.contains { $0.countryCode == savedCountry }) }
}

@Test func addingACityOnlyNeedsContentFiles() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    let state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
    let source = box.directory.appendingPathComponent("cities/shanghai.json")
    try FileManager.default.copyItem(at: source, to: box.directory.appendingPathComponent("cities/test-harbor.json"))
    try box.edit("cities/test-harbor.json") {
        $0["id"] = "test-harbor"
        $0.removeValue(forKey: "wikidata")
        $0["lat"] = state.legTo.lat + 0.0001
        $0["lon"] = state.legTo.lon
        $0["names"] = ["zh-Hans": "测试港", "en": "Test Harbor"]
    }
    let published = box.directory.appendingPathComponent("published-ids.txt")
    let ids = try String(contentsOf: published, encoding: .utf8)
    try (ids + "test-harbor\n").write(to: published, atomically: true, encoding: .utf8)
    var revisit = try #require(testCatalog.stories.all.first { $0.cityId == "shanghai" && $0.kind == "revisit" })
    revisit.cityId = "test-harbor"
    revisit.id = "test-harbor.revisit"
    revisit.replies = revisit.replies.map { reply in
        var reply = reply
        reply.id = revisit.id + "." + reply.habit
        return reply
    }
    try JSONEncoder().encode([revisit]).write(to: box.directory.appendingPathComponent("stories/test-harbor.json"))
    #expect(ContentValidator.validate(directory: box.directory).isEmpty)
    let catalog = try CityCatalog.load(directory: box.directory)
    #expect(catalog.find("test-harbor") != nil)
    #expect(catalog.active.count == testCatalog.active.count + 1)
    let picks = (0..<200).map { seed in
        DestinationPicker.pick(
            from: state.legTo, currentCityId: state.targetCityId, route: state.route + [state.targetCityId],
            stampedCountries: Set(state.stamps.map(\.countryCode)), medianKm: 0, catalog: catalog, seed: UInt32(seed)
        )
    }
    #expect(picks.contains("test-harbor"))
}

@Test func retiredTargetsArriveButAreNeverSelectedAgain() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
    let retired = state.targetCityId
    try box.edit("cities/\(retired).json") { $0["status"] = "retired" }
    let catalog = try CityCatalog.load(directory: box.directory)
    #expect(catalog.find(retired)?.status == "retired")
    #expect(!catalog.active.contains { $0.id == retired })
    state.sync(today: DayUsage(date: "2026-11-01", fuel: state.legCost), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: state.legCost)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: catalog)
    #expect(state.currentCityId == retired)
    state.sync(today: DayUsage(date: "2026-11-01", observedTokens: state.legCost),
               now: DayKey.date(from: "2026-11-01")!.addingTimeInterval(18 * 3600), catalog: catalog)
    let finalTokens = state.days[state.openDate]!.tokens! + state.remainingFuel
    state.sync(today: DayUsage(date: "2026-11-01", observedTokens: finalTokens),
               now: DayKey.date(from: "2026-11-01")!.addingTimeInterval(19 * 3600), catalog: catalog)
    #expect(state.phase == .home && state.tripCount == 1)
    #expect(state.targetCityId != retired)
    #expect(!DestinationPicker.candidates(currentCityId: state.homeCityId, route: state.route, catalog: catalog).contains { $0.id == retired })
}

@Test func catalogCoordinateChangesCannotMoveASavedLeg() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
    state.sync(today: DayUsage(date: "2026-11-01", fuel: 123), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: 123)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
    let original = state
    for id in [state.currentCityId, state.targetCityId] {
        try box.edit("cities/\(id).json") { $0["lat"] = 0; $0["lon"] = 0 }
    }
    let catalog = try CityCatalog.load(directory: box.directory)
    state = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
    state.sync(today: DayUsage(date: "2026-11-01", fuel: 123), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: 123)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: catalog)
    #expect(state.legCost == original.legCost)
    #expect(state.position == original.position)
    #expect(state.legProgress == original.legProgress && state.remainingFuel == original.remainingFuel)
    #expect(state.legFrom == original.legFrom && state.legTo == original.legTo)
    state.sync(today: DayUsage(date: "2026-11-01", fuel: state.legCost), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: state.legCost)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: catalog)
    #expect(state.currentCityId == original.targetCityId)
    #expect(state.legTo == original.legTo)
}

@Test(arguments: ["filename", "uniqueID", "status", "level", "continent", "latitude", "longitude", "countryCode", "names", "wikipedia", "cityTags", "emptyTags", "factID", "factNames", "factSources", "publishedMissing", "unpublished", "cityJSON"])
func validatorReportsEachCityRule(rule: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    switch rule {
    case "filename":
        try box.edit { $0["id"] = "wrong" }
    case "uniqueID":
        try FileManager.default.copyItem(at: box.directory.appendingPathComponent("cities/shanghai.json"), to: box.directory.appendingPathComponent("cities/duplicate.json"))
    case "publishedMissing":
        try FileManager.default.removeItem(at: box.directory.appendingPathComponent("cities/shanghai.json"))
    case "unpublished":
        try "shanghai\n".write(to: box.directory.appendingPathComponent("published-ids.txt"), atomically: true, encoding: .utf8)
    default:
        try box.edit { json in
            switch rule {
            case "status", "level", "continent", "countryCode": json[rule] = "invalid"
            case "latitude": json["lat"] = 91
            case "longitude": json["lon"] = -181
            case "names", "wikipedia": json[rule] = ["zh-Hans": "上海"]
            case "cityTags": json["tags"] = ["unknown"]
            case "emptyTags": json["tags"] = []
            case "cityJSON": json["lat"] = "invalid"
            default:
                var fact: [String: Any] = ["id": "a", "type": "place", "names": ["en": "River", "zh-Hans": "河"], "sources": ["https://en.wikipedia.org/wiki/River"]]
                if rule == "factNames" { fact["names"] = ["zh-Hans": "河"] }
                if rule == "factSources" { fact["sources"] = [] }
                json["facts"] = rule == "factID" ? [fact, fact] : [fact]
            }
        }
    }
    let expected = ["latitude": "coordinate", "longitude": "coordinate", "emptyTags": "cityTags"][rule] ?? rule
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == expected })
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}

@Test(arguments: ["file:///tmp/source", "http://en.wikipedia.org/wiki/River", "https://localhost/source", "https://example.org/verified-source", "https://example.com/source", "https://sub.example.org/source", "https://127.0.0.1/source", "https://[::1]/source"])
func validatorRejectsNonPublicFactSources(source: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit { $0["facts"] = [["id": "river", "type": "place", "names": ["en": "River", "zh-Hans": "河"], "sources": [source]]] }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "factSources" })
}

@Test func validatorAcceptsASourcedBilingualFact() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit {
        var facts = $0["facts"] as! [[String: Any]]
        facts.append(["id": "river", "type": "place", "names": ["en": "Huangpu River", "zh-Hans": "黄浦江"], "summary": ["zh-Hans": "流经上海的河流。", "en": "A river flowing through Shanghai."], "sources": ["https://en.wikipedia.org/wiki/Huangpu_River"]])
        $0["facts"] = facts
    }
    #expect(ContentValidator.validate(directory: box.directory).isEmpty)
}

@Test(arguments: ["formatVersion", "packVersion", "minAppVersion"])
func validatorRequiresEveryManifestField(field: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit("manifest.json") { $0.removeValue(forKey: field) }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "manifest" })
}

@Test(arguments: ["manifest.json", "tags.json", "countries.json", "published-ids.txt", "cities"])
func validatorReportsMissingOrUnreadableContent(path: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try FileManager.default.removeItem(at: box.directory.appendingPathComponent(path))
    #expect(!ContentValidator.validate(directory: box.directory).isEmpty)
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}

@Test func validatorRejectsCityCountryWithoutContentNames() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit("countries.json") { $0.removeValue(forKey: "AD") }
    try box.edit { $0["countryCode"] = "AD" }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "cities/shanghai.json" && $0.rule == "countryCode" })
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}

@Test(arguments: ["zh-Hans", "en"], ["missing", "blank"])
func validatorRequiresBilingualCountryNames(language: String, mode: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit("countries.json") { json in
        var names = json["CN"] as! [String: String]
        names[language] = mode == "missing" ? nil : " \n "
        json["CN"] = names
    }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "countries.json" && $0.rule == "countryNames" })
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}

@Test(arguments: ["invalid", "CHN", "cn"])
func validatorRejectsNonISOKeysInCountryNames(code: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit("countries.json") { $0[code] = ["zh-Hans": "测试", "en": "Test"] }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "countries.json" && $0.rule == "countryCode" })
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}

@Test(arguments: ["directory", "malformed"])
func validatorRejectsUnreadableCountryContent(mode: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    let file = box.directory.appendingPathComponent("countries.json")
    if mode == "directory" {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    } else {
        try Data("{".utf8).write(to: file)
    }
    #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "countries.json" && $0.rule == "countries" })
    #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
}
