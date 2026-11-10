import Foundation
import Testing
@testable import VoyageCore

private struct MigrationSandbox {
    let directory: URL
    var journeyURL: URL { directory.appendingPathComponent("journey.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func writeV1(_ edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: fixture("journey-v1")) as? [String: Any])
        try edit(&json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: journeyURL)
        return data
    }

    func migrated(_ name: String) throws -> JourneyState {
        var json = try JourneyMigrations.migrateV6(#require(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any]))
        json = try JourneyMigrations.migrateV7(json, catalog: testCatalog)
        json["version"] = JourneyState.currentVersion
        return try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func load() throws -> (JourneyState, SaveStore) {
        let store = SaveStore(directory: directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let state) = store.journey else {
            throw MigrationTestError.didNotLoad
        }
        return (state, store)
    }
}

private enum MigrationTestError: Error { case didNotLoad }

@Suite struct JourneyMigrationTests {
    @Test(arguments: [0, 123, 6_101_745, 12_203_489])
    func v6PreservesProgressAndHistoryWithoutInventingTokens(legFuel: Int) throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        var original = try #require(JSONSerialization.jsonObject(with: box.fixture("journey-v6")) as? [String: Any])
        original["legFuel"] = legFuel
        original["totalFuel"] = 98_765_432
        let bytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        var oldJSON = try JourneyMigrations.migrateV7(original, catalog: testCatalog)
        oldJSON["version"] = JourneyState.currentVersion
        let old = try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try bytes.write(to: box.journeyURL)
        let (state, store) = try box.load()
        #expect(state.version == 8)
        #expect(state.legCost == 1_220_349_000 && state.legFuel == legFuel * 100)
        #expect(abs(state.legProgress - old.legProgress) < 1e-15)
        #expect(state.position == old.position)
        #expect(state.totalKm == 9876.5432)
        #expect(state.totalFuel == old.totalFuel)
        #expect(state.legFrom == old.legFrom && state.legTo == old.legTo)
        #expect(state.route == old.route && state.targetCityId == old.targetCityId)
        #expect(state.days == old.days && state.letters == old.letters && state.stamps == old.stamps)
        #expect(state.days.values.allSatisfy { $0.tokens == nil })
        #expect(state.recentDailyKm() == 0)
        #expect(state.lastOpenedDate == old.lastOpenedDate && state.usageEvents == old.usageEvents)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == bytes)
        try store.save(state)
        let (reloaded, _) = try box.load()
        #expect(reloaded == state)
    }

    @Test func v6ScalingRejectsAnOverflowInsteadOfTrapping() throws {
        #expect(throws: SaveStoreError.invalidJSON) {
            try JourneyMigrations.migrateV6(["legCost": Int.max])
        }
    }

    @Test(arguments: [("上海", "zh-Hans"), ("Shanghai", "en")])
    func v4EnrichmentMigratesToLocalizedPlaceAndDiscardsWeather(title: String, language: String) throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        var original = try #require(JSONSerialization.jsonObject(with: box.fixture("journey-v4")) as? [String: Any])
        var letters = try #require(original["letters"] as? [[String: Any]])
        letters[1]["weather"] = "20°C 晴"
        letters[1]["placeTitle"] = title
        letters[1]["placeSummary"] = "Preserved summary"
        letters[1]["placeURL"] = "https://en.wikipedia.org/wiki/Shanghai"
        letters[1]["photoFile"] = "photo-7.png"
        letters[1]["enrichmentDone"] = true
        original["letters"] = letters
        let bytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try bytes.write(to: box.journeyURL)
        let (state, store) = try box.load()
        #expect(state.version == JourneyState.currentVersion)
        #expect(state.letters.map(\.id) == [0, 7])
        #expect(state.letters.map(\.read) == [true, false])
        #expect(state.letters[1].place == [language: .init(title: title, summary: "Preserved summary", url: "https://en.wikipedia.org/wiki/Shanghai")])
        #expect(state.letters[1].photoFile == "photo-7.png" && state.letters[1].enrichmentDone)
        #expect(state.letters.allSatisfy { $0.texts == nil && $0.replyOptions.isEmpty && $0.storyId == nil })
        #expect(state.letters[1].weatherCode == nil && state.letters[1].temperatureC == nil)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        let migrated = try #require(written["letters"] as? [[String: Any]])
        for letter in migrated {
            for key in ["weather", "placeTitle", "placeSummary", "placeURL"] { #expect(letter[key] == nil) }
        }
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == bytes)
    }

    @Test func frozenV5RoundTripsEveryStorySnapshotField() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let state = try decodeOldJourneyFixture(box.fixture("journey-v5"))
        let roundTrip = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip == state)
        let letter = try #require(state.letters.last)
        #expect(letter.storyId == "generic.transit.moving-address" && letter.storyVersion == 1)
        #expect(letter.texts?.count == 2 && letter.replyOptions.count == 2)
        #expect(letter.weatherCode == 61 && letter.temperatureC == 14)
        #expect(letter.place["en"]?.title == "Shanghai")
        #expect(letter.facts.first?.id == "saved-fact")
        #expect(letter.rewards == .init())
        #expect(state.letters[0].texts == nil)
    }

    @Test func frozenV3MigrationUpdatesMileageAndVersion() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v3")
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        var expected = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        expected = try JourneyMigrations.migrateV7(JourneyMigrations.migrateV6(expected), catalog: testCatalog)
        expected["version"] = JourneyState.currentVersion
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        #expect(NSDictionary(dictionary: written).isEqual(to: expected))
        #expect(state.version == JourneyState.currentVersion)
        #expect(state.letters.first?.kind == .departure)
        #expect(state.letters.first?.logbook == nil)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == original)
    }

    @Test func frozenV2MigrationRemovesChoiceAndUpdatesMileageAndVersion() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v2")
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        var expected = try box.migrated("journey-v3")
        expected.version = JourneyState.currentVersion
        #expect(state == expected)
        var old = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        old.removeValue(forKey: "nextChoiceId")
        old = try JourneyMigrations.migrateV7(JourneyMigrations.migrateV6(old), catalog: testCatalog)
        old["version"] = JourneyState.currentVersion
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        #expect(NSDictionary(dictionary: written).isEqual(to: old))
        #expect(written["nextChoiceId"] == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(encoded["nextChoiceId"] == nil)
        #expect(state.targetCityId == "xian")
        #expect(state.legCost == 1_220_349_000)
        #expect(state.legFrom == Coordinate(lat: 31.23, lon: 121.47))
        #expect(state.legTo == Coordinate(lat: 34.34, lon: 108.94))
        let backups = try store.backups(for: .journey)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first).url) == original)
    }

    @Test func frozenV1MigrationPreservesOriginalAndJourneyHistory() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v1")
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        var expected = try box.migrated("journey-v3")
        expected.version = JourneyState.currentVersion
        #expect(state == expected)
        #expect(state.version == JourneyState.currentVersion)
        #expect(state.totalFuel == 123 && state.legFuel == 12_300)
        #expect(state.route.isEmpty)
        #expect(state.letters.map(\.id) == [0, 7])
        #expect(state.stamps.map(\.countryCode) == ["CN"])
        #expect(state.legFrom == testCatalog.city("shanghai").coordinate)
        #expect(state.legTo == testCatalog.city("xian").coordinate)
        #expect(state.targetCountryCode == "CN")
        let oldCost = max(10_000, Int(state.legFrom.distanceKm(to: state.legTo) * 10_000)) * 100
        #expect(state.legCost == oldCost)
        #expect(state.legCost == 1_220_349_000)
        let backups = try store.backups(for: .journey)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first).url) == original)
        #expect(try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: box.journeyURL)) == expected)
        #expect(!store.isLocked)
    }

    @Test func everyCountryCollectionMigratesAndUnknownCountriesBecomeZZ() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.writeV1 { json in
            var stamps = try #require(json["stamps"] as? [[String: Any]])
            stamps.append(["country": "未知国家", "cityId": "missing-city", "date": "2026-11-01"])
            json["stamps"] = stamps
            var days = try #require(json["days"] as? [String: [String: Any]])
            days["2026-11-01"]?["newCountries"] = ["中国", "日本", "未知国家"]
            json["days"] = days
            var letters = try #require(json["letters"] as? [[String: Any]])
            letters[0]["newCountries"] = ["美国", "法国", "未知国家"]
            letters[1]["newCountries"] = ["中国", "日本"]
            json["letters"] = letters
        }
        let (state, store) = try box.load()
        #expect(state.stamps.map(\.countryCode) == ["CN", "ZZ"])
        #expect(state.days["2026-11-01"]?.newCountries == ["CN", "JP", "ZZ"])
        #expect(state.letters[0].newCountries == ["US", "FR", "ZZ"])
        #expect(state.letters[1].newCountries == ["CN", "JP"])
        #expect(JourneyMigrations.countryCode(for: "未知国家") == "ZZ")
        #expect(state.totalFuel == 123 && state.legFuel == 12_300)
        #expect(state.route.isEmpty && state.letters.count == 2)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        let stamps = try #require(written["stamps"] as? [[String: Any]])
        #expect(stamps.allSatisfy { $0["country"] == nil })
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == original)
    }

    @Test(arguments: ["current", "target", "both"])
    func missingCityEndpointsUseSpecifiedFallbacksAndContinue(missing: String) throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        _ = try box.writeV1 { json in
            if missing != "target" { json["currentCityId"] = "missing-current" }
            if missing != "current" { json["targetCityId"] = "missing-target" }
        }
        var (state, _) = try box.load()
        let coordinate = switch missing {
        case "current": testCatalog.city("xian").coordinate
        case "target": testCatalog.city("shanghai").coordinate
        default: Coordinate(lat: 0, lon: 0)
        }
        #expect(state.legFrom == coordinate && state.legTo == coordinate)
        #expect(state.legCost == max(state.legFuel + outboundTokensPerKm, outboundTokensPerKm))
        #expect(state.targetCountryCode == (missing == "current" ? "CN" : nil))
        #expect(state.position == coordinate)
        let destination = state.targetCityId
        let originalStampCount = state.stamps.count
        let fuel = state.remainingFuel + 321
        state.sync(today: DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel]), now: DayKey.date(from: (DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel])).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        #expect(state.currentCityId == destination)
        #expect(state.route.last == destination)
        #expect(state.phase == .staying && state.legFuel == state.legCost)
        #expect(state.travelFund == 0)
        #expect(state.targetCityId == destination)
        #expect(state.stamps.count == originalStampCount)
    }

    @Test func migrationAndFrozenM0SnapshotAdvanceToSameArrivalAndProgress() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        try box.fixture("journey-v1").write(to: box.journeyURL)
        var (migrated, _) = try box.load()
        // This fixture freezes the M0 coordinates and exact truncated distance formula.
        var reference = try box.migrated("journey-v3")
        reference.version = JourneyState.currentVersion
        let fuel = reference.remainingFuel + 4_321
        let usage = DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel])
        migrated.sync(today: usage, now: DayKey.date(from: (usage).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        reference.sync(today: usage, now: DayKey.date(from: (usage).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        #expect(migrated.currentCityId == "xian")
        #expect(migrated.phase == .staying && migrated.legFuel == migrated.legCost)
        #expect(migrated.route == reference.route)
        #expect(migrated.currentCityId == reference.currentCityId)
        #expect(migrated.targetCityId == reference.targetCityId)
        #expect(migrated.legProgress == reference.legProgress)
        #expect(migrated.remainingFuel == reference.remainingFuel)
        #expect(migrated.position == reference.position)
        #expect(migrated == reference)
    }
}

@Suite struct TripMigrationTests {
    @Test func frozenV7BecomesOutboundWithoutRedrawingOrReplayingAnything() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v7")
        let json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        #expect(state.version == 8 && state.homeCityId == "shanghai")
        #expect(state.homeCoordinate == Coordinate(lat: 31.23, lon: 121.47))
        #expect(state.route.isEmpty && state.tripCount == 0 && state.travelFund == 0)
        #expect(state.phase == .outbound && state.phaseSince == DayKey.date(from: state.openDate, calendar: careCalendar))
        #expect(state.legCost == json["legCost"] as? Int && state.legFuel == json["legFuel"] as? Int)
        #expect(state.targetCityId == json["targetCityId"] as? String)
        let snapshot = try decodeOldJourneyFixture(original)
        #expect(state == snapshot)
        #expect(state.totalKm == 0.0123 && state.days.values.allSatisfy { $0.lastObservedAt == nil })
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == original)
        try store.save(state)
        #expect(try box.load().0 == state)
    }

    @Test func laterV7LegUsesOnlySavedEndpointsAndStayedCityCount() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        var json = try #require(JSONSerialization.jsonObject(with: box.fixture("journey-v7")) as? [String: Any])
        json["route"] = ["removed-home", "retired-stop", "unknown-stop"]
        json["currentCityId"] = "unknown-stop"
        json["legFrom"] = ["lat": 12.0, "lon": 34.0]
        json["legTo"] = ["lat": 23.0, "lon": 45.0]
        try JSONSerialization.data(withJSONObject: json).write(to: box.journeyURL)
        let (state, _) = try box.load()
        #expect(state.homeCityId == "removed-home" && state.homeCoordinate == Coordinate(lat: 12, lon: 34))
        #expect(state.route == ["retired-stop", "unknown-stop"] && state.tripCount == 2)
        #expect(state.legFrom == Coordinate(lat: 12, lon: 34) && state.legTo == Coordinate(lat: 23, lon: 45))
        #expect(state.legFuel == 12_300 && state.legCost == 1_220_349_000)
        json["targetCityId"] = "removed-home"
        let migrated = try JourneyMigrations.migrateV7(json, catalog: testCatalog)
        let home = try #require(migrated["homeCoordinate"] as? [String: Double])
        #expect(home == ["lat": 23, "lon": 45])
    }

    @Test func v8ReadsAKnownHomeFromContentInsteadOfTheLastStop() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        var json = try #require(JSONSerialization.jsonObject(with: box.fixture("journey-v7")) as? [String: Any])
        let home = testCatalog.city("shanghai")
        json["route"] = ["shanghai", "hangzhou"]
        json["targetCityId"] = "suzhou"
        json["legFrom"] = ["lat": testCatalog.city("hangzhou").coordinate.lat, "lon": testCatalog.city("hangzhou").coordinate.lon]
        let migrated = try JourneyMigrations.migrateV7(json, catalog: testCatalog)
        let coordinate = try #require(migrated["homeCoordinate"] as? [String: Double])
        #expect(coordinate == ["lat": home.coordinate.lat, "lon": home.coordinate.lon])
    }
}
