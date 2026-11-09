import Foundation
import Testing
@testable import VoyageCore

private struct SaveSandbox {
    let directory: URL
    var journeyURL: URL { directory.appendingPathComponent("journey.json") }
    var careURL: URL { directory.appendingPathComponent("care.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func fixture(_ name: String = "journey-v6") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func writeJourney(_ edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        try edit(&json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: journeyURL)
        return data
    }
}

@Suite struct SaveStoreTests {
    @Test func startupRepairsExistingPermissionsWithoutChangingBytes() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let original = try box.writeJourney()
        let photos = box.directory.appendingPathComponent("photos")
        let backups = box.directory.appendingPathComponent("backups")
        for directory in [box.directory, photos, backups] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        let existingFiles = [box.journeyURL, photos.appendingPathComponent("letter-7.png"), backups.appendingPathComponent("old.json")]
        for file in existingFiles {
            try original.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        #expect(!store.isLocked)
        for directory in [box.directory, photos, backups] { #expect(try permissions(directory) == 0o700) }
        for file in existingFiles {
            #expect(try permissions(file) == 0o600)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func newAndAtomicallyReplacedSavesArePrivate() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        try FileManager.default.removeItem(at: box.directory)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        let state = try JSONDecoder().decode(JourneyState.self, from: box.fixture())
        for _ in 0..<2 {
            try store.save(state)
            try store.save(CareState.legacy(from: state, pets: testCatalog.pets))
            #expect(try permissions(box.directory) == 0o700)
            #expect(try permissions(box.journeyURL) == 0o600)
            #expect(try permissions(box.careURL) == 0o600)
            for file in [box.journeyURL, box.careURL] {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777
    }

    @Test func frozenV6LoadsWithoutRewritingOrBackingUp() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let original = try box.fixture()
        try original.write(to: box.journeyURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let journey) = store.journey else { Issue.record("v6 must load"); return }
        #expect(journey.version == 6)
        #expect(journey.seed == 42)
        #expect(journey.pet == PetID(rawValue: "snail"))
        #expect(journey.targetCityId == "xian")
        #expect(journey.stamps.first?.countryCode == "CN")
        #expect(journey.days["2026-11-01"]?.byClient == ["codex": 123])
        #expect(journey.letters.map(\.id) == [0, 7])
        #expect(journey.letters[0].kind == .logbook)
        #expect(journey.letters[0].logbook == Logbook(workdayStartHour: 9, weekendActivePercent: 25, topClients: ["codex", "claude"]))
        #expect(journey.letters[1].transitTargetId == "xian")
        #expect(journey.letters[0].deliverAt == Date(timeIntervalSinceReferenceDate: 0))
        #expect(try Data(contentsOf: box.journeyURL) == original)
        #expect(try store.backups(for: .journey).isEmpty)
        #expect(!store.isLocked)
    }

    @Test func absentDefaultFieldsAndOptionalFieldsDecode() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        var json = try #require(JSONSerialization.jsonObject(with: box.fixture()) as? [String: Any])
        for key in ["legFuel", "stamps", "totalFuel"] { json.removeValue(forKey: key) }
        json["days"] = ["2026-11-01": [:]]
        var letters = try #require(json["letters"] as? [[String: Any]])
        for index in letters.indices {
            letters[index].removeValue(forKey: "read")
            letters[index].removeValue(forKey: "enrichmentDone")
            letters[index].removeValue(forKey: "transitTargetId")
        }
        json["letters"] = letters
        try JSONSerialization.data(withJSONObject: json).write(to: box.journeyURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let state) = store.journey else { Issue.record("Defaults must decode"); return }
        #expect(state.legFuel == 0 && state.totalFuel == 0)
        #expect(state.stamps.isEmpty)
        #expect(state.days["2026-11-01"] == DayRecord())
        #expect(state.letters.allSatisfy { !$0.read && !$0.enrichmentDone && $0.transitTargetId == nil })
        for key in ["days", "letters"] { json.removeValue(forKey: key) }
        let stateWithoutCollections = try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(stateWithoutCollections.days.isEmpty && stateWithoutCollections.letters.isEmpty)
    }

    @Test(arguments: ["seed", "pet", "startDate", "currentCityId", "targetCityId", "route", "openDate", "version", "legCost", "legFrom", "legTo"])
    func missingRequiredJourneyFieldIsCorrupted(key: String) throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        _ = try box.writeJourney { $0.removeValue(forKey: key) }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .corrupted = store.journey else { Issue.record("Missing \(key) must be corrupted"); return }
        #expect(store.isLocked)
    }

    @Test func journeyDecoderRequiresVersion() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let data = try box.writeJourney { $0.removeValue(forKey: "version") }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JourneyState.self, from: data) }
    }

    @Test(arguments: [0, -1]) func nonPositiveLegCostIsCorrupted(cost: Int) throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let data = try box.writeJourney { $0["legCost"] = cost }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JourneyState.self, from: data) }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .corrupted(let backup) = store.journey else { Issue.record("Non-positive leg cost must be corrupted"); return }
        #expect(try Data(contentsOf: backup) == data)
        #expect(store.isLocked)
    }

    @Test(arguments: ["id", "kind", "date", "pet", "cityId", "arrivals", "newCountries", "fuel", "vehicles", "isDeepVisit", "deliverAt"])
    func missingRequiredLetterFieldIsCorrupted(key: String) throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        _ = try box.writeJourney {
            var letters = try #require($0["letters"] as? [[String: Any]])
            letters[0].removeValue(forKey: key)
            $0["letters"] = letters
        }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .corrupted = store.journey else { Issue.record("Missing letter \(key) must be corrupted"); return }
    }

    @Test(arguments: [0, -1]) func invalidVersionIsCorrupted(version: Int) throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        _ = try box.writeJourney { $0["version"] = version }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .corrupted = store.journey else { Issue.record("Invalid version must be corrupted"); return }
    }

    @Test func explicitNullAndWrongTypesDoNotUseDefaults() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let data = try box.writeJourney { $0["legFuel"] = NSNull() }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(JourneyState.self, from: data) }
        let wrongType = try box.writeJourney { $0["totalFuel"] = "123" }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(JourneyState.self, from: wrongType) }
    }

    @Test func corruptBytesAreMovedIntactAndRetryAndRelaunchStayLocked() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let bytes = Data([0xFF, 0x00, 0x7B, 0x01])
        try bytes.write(to: box.journeyURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .corrupted(let backup) = store.journey else { Issue.record("Must quarantine"); return }
        #expect(try Data(contentsOf: backup) == bytes)
        #expect(!FileManager.default.fileExists(atPath: box.journeyURL.path))
        #expect(!FileManager.default.fileExists(atPath: box.careURL.path))
        let fresh = JourneyState(seed: 1, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
        #expect(throws: SaveStoreError.locked) { try store.save(fresh) }
        #expect(throws: SaveStoreError.locked) { try store.save(CareState.legacy(from: fresh, pets: testCatalog.pets)) }
        store.load()
        #expect(store.isLocked)
        let relaunched = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        relaunched.load()
        #expect(relaunched.isLocked)
        #expect(try relaunched.backups(for: .journey).count == 1)
    }

    @Test func tooNewStaysUntouchedWithNoBackup() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let bytes = try box.writeJourney { $0["version"] = 99 }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .tooNew(99) = store.journey else { Issue.record("Must reject newer version"); return }
        #expect(try Data(contentsOf: box.journeyURL) == bytes)
        #expect(try store.backups(for: .journey).isEmpty)
        let fresh = JourneyState(seed: 1, startCityId: "shanghai", date: "2026-11-01", catalog: testCatalog)
        #expect(throws: SaveStoreError.locked) { try store.save(fresh) }
        #expect(throws: SaveStoreError.locked) { try store.save(CareState.legacy(from: fresh, pets: testCatalog.pets)) }
        #expect(!FileManager.default.fileExists(atPath: box.careURL.path))
    }

    @Test func migrationsRunInOrderAndBackUpOriginalBytes() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let original = try box.writeJourney { $0["version"] = 2 }
        var order: [Int] = []
        let migrations = SaveMigrations(currentVersion: 4, steps: [
            2: { json in
                order.append(2)
                #expect(json["version"] as? Int == 2)
                var json = json
                json["totalFuel"] = 456
                return json
            },
            3: { json in
                order.append(3)
                #expect(json["version"] as? Int == 3)
                #expect(json["totalFuel"] as? Int == 456)
                return json
            },
        ])
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: migrations)
        store.load()
        #expect(order == [2, 3])
        guard case .loaded(let state) = store.journey else { Issue.record("Migration must load"); return }
        #expect(state.version == 4 && state.totalFuel == 456)
        let backups = try store.backups(for: .journey)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first).url) == original)
        let written = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: box.journeyURL))
        #expect(written.version == 4)
    }

    @Test(arguments: [false, true]) func failedOrMissingMigrationNeverWrites(missing: Bool) throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let original = try box.writeJourney { $0["version"] = 2 }
        enum MigrationError: Error { case failed }
        var steps: [Int: SaveMigrations.Step] = [2: { $0 }]
        if !missing { steps[3] = { _ in throw MigrationError.failed } }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: SaveMigrations(currentVersion: 4, steps: steps))
        store.load()
        guard case .unreadable = store.journey else { Issue.record("Migration failure must lock"); return }
        #expect(try Data(contentsOf: box.journeyURL) == original)
        #expect(try store.backups(for: .journey).count == 1)
        #expect(!FileManager.default.fileExists(atPath: box.careURL.path))
    }

    @Test func migrationMustDecodeBeforeWritingAndOtherFileCanBlockWriteback() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let original = try box.writeJourney { $0["version"] = 2 }
        let broken = SaveMigrations(currentVersion: 3, steps: [2: { json in
            var json = json
            json.removeValue(forKey: "seed")
            return json
        }])
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: broken)
        store.load()
        #expect(store.isLocked)
        #expect(try Data(contentsOf: box.journeyURL) == original)
        try Data("broken care".utf8).write(to: box.careURL)
        let valid = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: SaveMigrations(currentVersion: 3, steps: [2: { $0 }]))
        valid.load()
        #expect(valid.isLocked)
        #expect(try Data(contentsOf: box.journeyURL) == original)
    }

    @Test func permissionFailureIsUnreadableAndDoesNotMoveOrWrite() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        let original = try box.writeJourney()
        // Revoke access after the one-time startup permission repair.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.journeyURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: box.journeyURL.path) }
        store.load()
        guard case .unreadable = store.journey else { Issue.record("chmod 000 must be unreadable"); return }
        #expect(FileManager.default.fileExists(atPath: box.journeyURL.path))
        #expect(try store.backups(for: .journey).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.careURL.path))
        let state = try JSONDecoder().decode(JourneyState.self, from: original)
        #expect(throws: SaveStoreError.locked) { try store.save(state) }
    }

    @Test func existingDirectoryInPlaceOfFileIsUnreadable() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        try FileManager.default.createDirectory(at: box.journeyURL, withIntermediateDirectories: true)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .unreadable = store.journey else { Issue.record("I/O failure must be unreadable"); return }
        #expect(try store.backups(for: .journey).isEmpty)
    }

    @Test func badCareLocksBothSaves() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let bytes = try box.writeJourney()
        let badCare = Data("not json".utf8)
        try badCare.write(to: box.careURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(let state) = store.journey, case .corrupted(let backup) = store.care else {
            Issue.record("Care must lock a normal journey"); return
        }
        #expect(try Data(contentsOf: backup) == badCare)
        #expect(throws: SaveStoreError.locked) { try store.save(state) }
        #expect(throws: SaveStoreError.locked) { try store.save(CareState.legacy(from: state, pets: testCatalog.pets)) }
        #expect(try Data(contentsOf: box.journeyURL) == bytes)
    }

    @Test func legacyCarePreservesPetAndMarksAllOldLettersProcessed() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let state = try JSONDecoder().decode(JourneyState.self, from: box.fixture())
        let care = CareState.legacy(from: state, pets: testCatalog.pets)
        #expect(care.version == 1)
        #expect(care.species == PetID(rawValue: "snail") && care.petName == "壳壳")
        #expect(care.hatchedAt == state.startDate)
        #expect(care.companionDays.isEmpty)
        #expect(care.habits.talkative == 0 && care.habits.observant == 0)
        #expect(care.identity == nil && care.wish == nil)
        #expect(care.bag.owned == ["sketchbook", "note-slip", "raincoat"])
        #expect(care.bag.todayItem == nil)
        #expect(care.pity == 0 && care.processedLetterIds == [0, 7])
        #expect(care.souvenirs.isEmpty && care.menus.isEmpty && care.trailClues.isEmpty)
        #expect(care.weekly.stamps.isEmpty && care.weekly.boxes.isEmpty)
        #expect(care.pendingPromises.isEmpty && care.memories.isEmpty)
    }

    @Test func careExampleRoundTripsAndExistingCareIsPreserved() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let bytes = try box.fixture("care-v1")
        let care = try JSONDecoder().decode(CareState.self, from: bytes)
        #expect(care.petName == "阿鸽" && care.species == PetID(rawValue: "pigeon"))
        #expect(care.habits.talkative == 20 && care.habits.observant == 10)
        #expect(care.souvenirs.first?.id == "jingdezhen.note")
        #expect(care.souvenirs.first?.shelved == true)
        #expect(care.menus.first?.letterId == 3)
        #expect(care.trailClues == ["jingdezhen": 2])
        #expect(care.weekly.weekStart == "2026-11-02")
        #expect(care.pendingPromises.first?.replyId == "ask-next-time")
        #expect(care.memories.first?.kind == "reply")
        #expect(care.pity == 3 && care.processedLetterIds == [1, 2, 3])
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
        try bytes.write(to: box.careURL)
        _ = try box.writeJourney()
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        #expect(try Data(contentsOf: box.careURL) == bytes)
        #expect(try store.backups(for: .care).isEmpty)
    }

    @Test func missingSavesDoNotCreateAnythingAndCareUsesSameVersionPipeline() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .missing = store.journey, case .missing = store.care else { Issue.record("Fresh directory must be missing"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.directory.path).isEmpty)
        let original = try box.fixture("care-v1")
        try original.write(to: box.careURL)
        let migrating = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog), careMigrations: SaveMigrations(currentVersion: 2, steps: [1: { $0 }]))
        migrating.load()
        guard case .loaded(let care) = migrating.care else { Issue.record("Care must migrate"); return }
        #expect(care.version == 2)
        #expect(try Data(contentsOf: #require(migrating.backups(for: .care).first).url) == original)
        let older = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        older.load()
        guard case .tooNew(2) = older.care else { Issue.record("Care must reject newer versions"); return }
        #expect(older.isLocked)
    }

    @Test func restoreValidatesBeforeReplacingAndRetainsBackup() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let current = try box.writeJourney()
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        let candidate = box.directory.appendingPathComponent("candidate.json")
        try Data("bad backup".utf8).write(to: candidate)
        let backup = SaveBackup(file: .journey, url: candidate)
        #expect(throws: (any Error).self) { try store.restore(backup: backup) }
        #expect(try Data(contentsOf: box.journeyURL) == current)
        #expect(try store.backups(for: .journey).isEmpty)
        var state = try JSONDecoder().decode(JourneyState.self, from: current)
        state.totalFuel = 987
        let valid = try JSONEncoder().encode(state)
        try valid.write(to: candidate)
        try store.restore(backup: backup)
        #expect(try Data(contentsOf: candidate) == valid)
        #expect(try Data(contentsOf: box.journeyURL) == valid)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == current)
        #expect(!store.isLocked)
    }

    @Test func sameTimestampBackupsNeverOverwrite() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let store = SaveStore(directory: box.directory, now: { Date(timeIntervalSince1970: 0) }, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        let first = Data("first broken save".utf8)
        let second = Data("second broken save".utf8)
        try first.write(to: box.journeyURL)
        store.load()
        try second.write(to: box.journeyURL)
        store.load()
        let backups = try store.backups(for: .journey)
        #expect(backups.count == 2)
        #expect(Set(try backups.map { try Data(contentsOf: $0.url) }) == Set([first, second]))
    }

    @Test func restorableBackupsExcludeQuarantinedFiles() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let store = SaveStore(
            directory: box.directory,
            pets: testCatalog.pets, journeyMigrations: SaveMigrations(currentVersion: 3, steps: [2: { $0 }])
        )
        #expect(try store.restorableBackups(for: .journey).isEmpty)
        _ = try box.writeJourney { $0["version"] = 2 }
        store.load()
        try Data("broken journey".utf8).write(to: box.journeyURL)
        store.load()
        let backups = try store.backups(for: .journey)
        #expect(backups.count == 2)
        #expect(backups.contains { $0.url.lastPathComponent.hasSuffix(".corrupted.json") })
        let restorable = try store.restorableBackups(for: .journey)
        #expect(restorable == backups.filter { $0.url.lastPathComponent.hasSuffix(".migration.json") })
        #expect(restorable.count == 1)
    }

    @Test func restorableBackupsSortByTimeAcrossVersions() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let directory = box.directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = directory.appendingPathComponent("journey.json.v2.2026-11-05T12-00-00Z.older.migration.json")
        let newer = directory.appendingPathComponent("journey.json.v1.2026-11-06T12-00-00Z.newer.migration.json")
        let data = try box.fixture()
        try data.write(to: older)
        try data.write(to: newer)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        let allNames = try store.backups(for: .journey).map { $0.url.lastPathComponent }
        let restorableNames = try store.restorableBackups(for: .journey).map { $0.url.lastPathComponent }
        #expect(allNames == [older.lastPathComponent, newer.lastPathComponent])
        #expect(restorableNames == [newer.lastPathComponent, older.lastPathComponent])
    }

    @Test func restoreUnlocksWithoutLosingTheQuarantinedFile() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: box.journeyURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        let good = box.directory.appendingPathComponent("good-backup.json")
        let original = try box.fixture()
        try original.write(to: good)
        try store.restore(backup: SaveBackup(file: .journey, url: good))
        #expect(!store.isLocked)
        #expect(try Data(contentsOf: box.journeyURL) == original)
        #expect(try Data(contentsOf: good) == original)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == corrupt)
        guard case .loaded(let care) = store.care else { Issue.record("Legacy care must be created"); return }
        #expect(care.processedLetterIds == [0, 7])
    }

    @Test func onlyCorruptedFilesCanRestart() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        #expect(throws: SaveStoreError.restartNotAllowed) { try store.restart() }
        _ = try box.writeJourney { $0["version"] = 99 }
        store.load()
        #expect(throws: SaveStoreError.restartNotAllowed) { try store.restart() }
        try Data("broken".utf8).write(to: box.journeyURL)
        store.load()
        try store.restart()
        #expect(!store.isLocked)
        // A reload while recovering the other file must not undo explicit restart consent.
        store.load()
        #expect(!store.isLocked)
        let replacement = JourneyState(seed: 8, startCityId: "shanghai", date: "2026-11-06", catalog: testCatalog)
        try store.save(replacement)
        #expect(try store.backups(for: .journey).count == 1)
        store.load()
        guard case .loaded(let journey) = store.journey else { Issue.record("Must save after restart"); return }
        #expect(journey.seed == 8)
    }

    @Test func restartingCarePreservesJourneyAndAllBackups() throws {
        let box = try SaveSandbox()
        defer { box.cleanUp() }
        let journeyBytes = try box.writeJourney()
        try Data("broken care".utf8).write(to: box.careURL)
        let store = SaveStore(directory: box.directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        try store.restart(.care)
        store.load()
        #expect(!store.isLocked)
        #expect(try Data(contentsOf: box.journeyURL) == journeyBytes)
        #expect(try store.backups(for: .care).count == 1)
        guard case .loaded(let care) = store.care else { Issue.record("Care must be regenerated"); return }
        #expect(care.petName == "壳壳" && care.processedLetterIds == [0, 7])
    }
}
