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

    func load() throws -> (JourneyState, SaveStore) {
        let store = SaveStore(directory: directory, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let state) = store.journey else {
            throw MigrationTestError.didNotLoad
        }
        return (state, store)
    }
}

private enum MigrationTestError: Error { case didNotLoad }

@Suite struct JourneyMigrationTests {
    @Test func frozenV3MigrationOnlyChangesVersion() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v3")
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        var expected = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        expected["version"] = 4
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        #expect(NSDictionary(dictionary: written).isEqual(to: expected))
        #expect(state.version == 4)
        #expect(state.letters.first?.kind == .departure)
        #expect(state.letters.first?.logbook == nil)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == original)
    }

    @Test func frozenV2MigrationOnlyRemovesChoiceAndUpdatesVersion() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture("journey-v2")
        try original.write(to: box.journeyURL)
        let (state, store) = try box.load()
        var expected = try JSONDecoder().decode(JourneyState.self, from: box.fixture("journey-v3"))
        expected.version = 4
        #expect(state == expected)
        var old = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        old.removeValue(forKey: "nextChoiceId")
        old["version"] = 4
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.journeyURL)) as? [String: Any])
        #expect(NSDictionary(dictionary: written).isEqual(to: old))
        #expect(written["nextChoiceId"] == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(encoded["nextChoiceId"] == nil)
        #expect(state.targetCityId == "xian")
        #expect(state.legCost == 12_203_490)
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
        var expected = try JSONDecoder().decode(JourneyState.self, from: box.fixture("journey-v3"))
        expected.version = 4
        #expect(state == expected)
        #expect(state.version == 4)
        #expect(state.totalFuel == 123 && state.legFuel == 123)
        #expect(state.route == ["shanghai"])
        #expect(state.letters.map(\.id) == [0, 7])
        #expect(state.stamps.map(\.countryCode) == ["CN"])
        #expect(state.legFrom == testCatalog.city("shanghai").coordinate)
        #expect(state.legTo == testCatalog.city("xian").coordinate)
        #expect(state.targetCountryCode == "CN")
        let oldCost = max(fuelPerKm, Int(state.legFrom.distanceKm(to: state.legTo) * Double(fuelPerKm)))
        #expect(state.legCost == oldCost)
        #expect(state.legCost == 12_203_490)
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
        #expect(state.totalFuel == 123 && state.legFuel == 123)
        #expect(state.route == ["shanghai"] && state.letters.count == 2)
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
        #expect(state.legCost == max(state.legFuel + fuelPerKm, fuelPerKm))
        #expect(state.targetCountryCode == (missing == "current" ? "CN" : nil))
        #expect(state.position == coordinate)
        let destination = state.targetCityId
        let originalStampCount = state.stamps.count
        let fuel = state.remainingFuel + 321
        state.sync(today: DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel]), catalog: testCatalog)
        #expect(state.currentCityId == destination)
        #expect(state.route.last == destination)
        #expect(state.legFuel == 321)
        #expect(testCatalog.find(state.targetCityId)?.status == "active")
        #expect(state.stamps.count == originalStampCount)
    }

    @Test func migrationAndFrozenM0SnapshotAdvanceToSameArrivalAndProgress() throws {
        let box = try MigrationSandbox()
        defer { box.cleanUp() }
        try box.fixture("journey-v1").write(to: box.journeyURL)
        var (migrated, _) = try box.load()
        // This fixture freezes the M0 coordinates and exact truncated distance formula.
        var reference = try JSONDecoder().decode(JourneyState.self, from: box.fixture("journey-v3"))
        reference.version = 4
        let fuel = reference.remainingFuel + 4_321
        let usage = DayUsage(date: "2026-11-02", fuel: fuel, byClient: ["codex": fuel])
        migrated.sync(today: usage, catalog: testCatalog)
        reference.sync(today: usage, catalog: testCatalog)
        #expect(migrated.currentCityId == "xian")
        #expect(migrated.legFuel == 4_321)
        #expect(migrated.route == reference.route)
        #expect(migrated.currentCityId == reference.currentCityId)
        #expect(migrated.targetCityId == reference.targetCityId)
        #expect(migrated.legProgress == reference.legProgress)
        #expect(migrated.remainingFuel == reference.remainingFuel)
        #expect(migrated.position == reference.position)
        #expect(migrated == reference)
    }
}
