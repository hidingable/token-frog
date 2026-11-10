import Darwin
import Foundation
import Testing
@testable import VoyageCore

@Test func worldTSVHasStableOrderAndEightFields() throws {
    let file = contentDirectory.appendingPathComponent("world/cities.tsv")
    let text = try String(contentsOf: file, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.first == Substring(CityContent.header))
    #expect(text.hasSuffix("\n"))
    let fields = lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
    #expect((6500...7400).contains(fields.count))
    #expect(fields.allSatisfy { $0.count == 8 })
    let ids = fields.map { String($0[0]) }
    #expect(ids == ids.sorted())
    #expect(Set(ids).count == ids.count)
    for row in fields {
        #expect(row[0].range(of: #"^q[1-9][0-9]*$"#, options: .regularExpression) != nil)
        for coordinate in [row[1], row[2]] {
            #expect(coordinate.range(of: #"^-?\d+\.\d{4}$"#, options: .regularExpression) != nil)
        }
    }
    let cities = try CityContent.readBase(directory: contentDirectory)
    #expect(cities.count == fields.count)
    #expect(cities.allSatisfy { $0.level == "basic" && $0.tags.isEmpty && $0.wikipedia.isEmpty && $0.facts.isEmpty })
    #expect(cities.allSatisfy { (-90...90).contains($0.lat) && (-180...180).contains($0.lon) })
    #expect(cities.allSatisfy { testCatalog.countryNames($0.countryCode) != nil })
    #expect(cities.allSatisfy { $0.names["zh-Hans"]?.range(of: #"\p{Han}"#, options: .regularExpression) != nil })
}

@Test(arguments: [
    ("q8686", "Shanghai", "上海", "CN"), ("q68695", "Quanzhou", "泉州", "CN"),
    ("q34405", "Jingdezhen", "景德镇", "CN"), ("q1490", "Tokyo", "东京", "JP"),
    ("q1899", "Kyiv", "基辅", "UA"), ("q44254", "Ushuaia", "乌斯怀亚", "AR"),
])
func worldCityFactsAreCorrect(entry: (String, String, String, String)) throws {
    let city = try #require(testCatalog.find(entry.0))
    #expect(city.names["en"] == entry.1)
    #expect(city.names["zh-Hans"] == entry.2)
    #expect(city.countryCode == entry.3)
    if entry.0 == "q68695" || entry.0 == "q34405" {
        #expect(city.level == "full" && !city.wikipedia.isEmpty && !city.tags.isEmpty)
    }
}

@Test func shanghaiDetailReplacesItsBaseAndKeepsItsAlias() throws {
    let city = try #require(testCatalog.find("q8686"))
    #expect(city.id == "shanghai")
    #expect(testCatalog.find("Q8686") == city)
    #expect(testCatalog.active.filter { $0.wikidata == "q8686" }.count == 1)
    #expect(!testCatalog.all.contains { $0.id == "q8686" })
    #expect(testCatalog.all.count == 7130)
    #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
}

@Test(arguments: Language.allCases)
func cuscoDetailIsTheOnlyCuscoInTheCityList(language: Language) throws {
    let city = try #require(testCatalog.find("cusco"))
    #expect(city.wikidata == "q5582862")
    #expect(testCatalog.find("q5582862") == city)
    #expect(testCatalog.find("Q5582862") == city)
    #expect(testCatalog.cities(matching: "库斯科", language: language).map(\.id) == ["cusco"])
    #expect(testCatalog.cities(language: language).filter { $0.wikidata == "q5582862" || $0.id == "cusco" }.map(\.id) == ["cusco"])
}

@Test func futureQuanzhouDetailResolvesSavedWikidataWithoutChangingTheLeg() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try FileManager.default.removeItem(at: box.directory.appendingPathComponent("cities/quanzhou.json"))
    let beforeCatalog = try CityCatalog.load(directory: box.directory)
    var saved = JourneyState(seed: 42, startCityId: "q68695", date: "2026-11-01", catalog: beforeCatalog)
    saved.sync(today: DayUsage(date: "2026-11-01", fuel: 123), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: 123)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: beforeCatalog)
    let data = try JSONEncoder().encode(saved)
    let original = try #require(beforeCatalog.find("q68695"))
    #expect(original.id == "q68695")
    var detail = testCatalog.city("quanzhou")
    detail.id = "quanzhou"
    detail.wikidata = "Q68695"
    detail.lat = 24.87
    detail.lon = 118.68
    detail.tags = ["coast", "heritage"]
    detail.wikipedia = ["zh-Hans": "泉州市", "en": "Quanzhou"]
    try JSONEncoder().encode(detail).write(to: box.directory.appendingPathComponent("cities/quanzhou.json"))
    let published = box.directory.appendingPathComponent("published-ids.txt")
    try (String(contentsOf: published, encoding: .utf8) + "quanzhou\n").write(to: published, atomically: true, encoding: .utf8)
    try validateContent(directory: box.directory)
    let catalog = try CityCatalog.load(directory: box.directory)
    #expect(catalog.find("q68695")?.id == "quanzhou")
    #expect(catalog.find("Q68695")?.id == "quanzhou")
    #expect(catalog.all.count == testCatalog.all.count)
    #expect(catalog.all.filter { $0.wikidata == "q68695" }.count == 1)
    var loaded = try JSONDecoder().decode(JourneyState.self, from: data)
    loaded.sync(today: DayUsage(date: "2026-11-01", fuel: 123), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: 123)).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: catalog)
    #expect(loaded == saved)
    #expect(loaded.legCost == saved.legCost && loaded.legFrom == saved.legFrom && loaded.legTo == saved.legTo)
    #expect(!DestinationPicker.candidates(currentCityId: "q68695", route: ["q68695"], catalog: catalog).contains { $0.id == "quanzhou" })
    #expect(!DestinationPicker.candidates(currentCityId: "shanghai", route: ["q68695", "shanghai"], catalog: catalog).contains { $0.id == "quanzhou" })
}

@Test func baseIDCanBeOverriddenDirectlyWithoutRepeatingWikidata() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try FileManager.default.removeItem(at: box.directory.appendingPathComponent("cities/quanzhou.json"))
    var detail = try #require(CityContent.readBase(directory: box.directory).first { $0.id == "q68695" })
    try FileManager.default.removeItem(at: box.directory.appendingPathComponent("stories/quanzhou.json"))
    try FileManager.default.removeItem(at: box.directory.appendingPathComponent("items/quanzhou.json"))
    let published = box.directory.appendingPathComponent("published-ids.txt")
    let ids = try String(contentsOf: published, encoding: .utf8).split(separator: "\n").filter { $0 != "quanzhou" }
    try (ids.joined(separator: "\n") + "\n").write(to: published, atomically: true, encoding: .utf8)
    detail.wikidata = nil
    detail.tags = ["coast"]
    detail.wikipedia = ["en": "Quanzhou", "zh-Hans": "泉州市"]
    try JSONEncoder().encode(detail).write(to: box.directory.appendingPathComponent("cities/q68695.json"))
    try validateContent(directory: box.directory)
    let catalog = try CityCatalog.load(directory: box.directory)
    #expect(catalog.find("q68695") == detail)
    #expect(catalog.all.count == testCatalog.all.count)
}

@Test func loadingParsesWithoutRunningTheFullContentValidator() throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try box.edit("manifest.json") { $0["formatVersion"] = 999 }
    #expect(!ContentValidator.validate(directory: box.directory).isEmpty)
    let catalog = try CityCatalog.load(directory: box.directory)
    #expect(catalog.all == testCatalog.all)
}

@Test(arguments: ["q1\tbad\t0\tCN\tasia\t2\tCity\t城市\n", "q1\t0\t0\tCN\tasia\t0\tCity\t城市\n", "q1\t0\n"])
func baseParserRejectsMalformedRows(row: String) throws {
    let box = try ContentSandbox()
    defer { box.cleanUp() }
    try (CityContent.header + "\n" + row).write(to: box.directory.appendingPathComponent("world/cities.tsv"), atomically: true, encoding: .utf8)
    #expect(throws: ContentValidationError.self) { try CityCatalog.load(directory: box.directory) }
}

@Test func tierMultipliersAreExactAndLegacyCitiesDefaultToTwo() throws {
    #expect(DestinationPicker.configuration.tierMultipliers == [8, 4, 2, 1])
    var city = testCatalog.city("shanghai")
    #expect(city.tier == 2)
    city.level = "basic" // Isolate tier weights from the separately tested content multiplier.
    for (tier, multiplier) in [8, 4, 2, 1].enumerated() {
        city.tier = tier + 1
        #expect(DestinationPicker.cityWeight(city, route: [city.id], stampedCountries: [city.countryCode], wishTags: []) == multiplier)
        #expect(DestinationPicker.cityWeight(city, route: [], stampedCountries: [], wishTags: ["river"]) == multiplier * 3 * 2 * 3)
    }
}

@Test(arguments: Language.allCases)
func citySearchMatchesBothLanguagesCaseAndNoResults(language: Language) {
    #expect(testCatalog.cities(matching: "QUANZHOU", language: language).map(\.id) == ["quanzhou"])
    #expect(testCatalog.cities(matching: " 泉州 ", language: language).map(\.id) == ["quanzhou"])
    #expect(testCatalog.cities(matching: "jInGdEzHeN", language: language).map(\.id) == ["jingdezhen"])
    #expect(testCatalog.cities(matching: "上海", language: language).map(\.id) == ["shanghai"])
    #expect(testCatalog.cities(matching: "no-such-city-12345", language: language).isEmpty)
    let cities = testCatalog.cities(language: language)
    #expect(cities.count == testCatalog.active.count)
    let locale = Locale(identifier: language.rawValue)
    #expect(zip(cities, cities.dropFirst()).allSatisfy {
        $0.names[language.rawValue]!.compare($1.names[language.rawValue]!, locale: locale) != .orderedDescending
    })
    #expect(testCatalog.cities(language: language) == cities)
    #expect(testCatalog.cities(matching: "泉州", language: language).map(\.id) == ["quanzhou"])
}

private func residentMemory() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    #expect(result == KERN_SUCCESS)
    return info.resident_size
}

/// Run alone in release mode with: swift test -c release --filter measureWorldCatalog
@Test func measureWorldCatalog() throws {
    let before = try residentMemory()
    let start = ContinuousClock.now
    let catalog = try CityCatalog.load(directory: contentDirectory)
    let load = start.duration(to: .now)
    let after = try residentMemory()
    let pickStart = ContinuousClock.now
    let selected = DestinationPicker.pick(from: catalog.city("shanghai").coordinate, currentCityId: "shanghai",
        route: ["shanghai"], stampedCountries: ["CN"], medianKm: 300, catalog: catalog, seed: 42)
    let pick = pickStart.duration(to: .now)
    #expect(catalog.find(selected) != nil)
    print("WORLD cities=\(catalog.active.count) load=\(load) pick=\(pick) memoryDelta=\(Int64(after) - Int64(before)) bytes")
    #expect(load < .seconds(1))
    #expect(pick < .milliseconds(50))
}
