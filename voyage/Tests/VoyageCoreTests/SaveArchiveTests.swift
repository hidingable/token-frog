import Foundation
import Testing
@testable import VoyageCore

private struct ArchiveSandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func url(_ file: SaveFile) -> URL { directory.appendingPathComponent(file.rawValue) }
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func store(populated: Bool = true) throws -> SaveStore {
        if populated {
            try fixture("journey-v5").write(to: url(.journey))
            try fixture("care-v1").write(to: url(.care))
        }
        let store = SaveStore(directory: directory, now: { Date(timeIntervalSince1970: 0) },
                              pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        return store
    }
    func bytes() throws -> [SaveFile: Data] {
        try Dictionary(uniqueKeysWithValues: SaveFile.allCases.map { ($0, try Data(contentsOf: url($0))) })
    }
    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".voyage-import-") }
    }
    func archive(journey: String = "journey-v5", care: String = "care-v1") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": 1, "exportedAt": "2026-11-06T01:00:00Z", "appVersion": "1.0",
            "journey": JSONSerialization.jsonObject(with: fixture(journey)),
            "care": JSONSerialization.jsonObject(with: fixture(care)),
        ])
    }
}

@Suite struct SaveArchiveTests {
    @Test(arguments: [false, true])
    func importStagingBackupsReplacementAndRollbackArePrivate(failReplacement: Bool) throws {
        enum Injected: Error { case failure }
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let archive = try store.validateArchive(box.archive())
        var checkedStaging = false
        store.archiveOperation = { operation in
            if operation == .replace(.journey) {
                let temporary = try FileManager.default.contentsOfDirectory(at: box.directory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix(".voyage-import-") }
                #expect(temporary.count == 4)
                for file in temporary { #expect(try self.permissions(file) == 0o600) }
                checkedStaging = true
            }
            if failReplacement && operation == .replace(.care) { throw Injected.failure }
        }
        if failReplacement {
            #expect(throws: SaveArchiveError.writeFailed) { try store.importArchive(archive) }
        } else {
            try store.importArchive(archive)
        }
        #expect(checkedStaging)
        #expect(try permissions(box.directory) == 0o700)
        #expect(try permissions(box.directory.appendingPathComponent("backups")) == 0o700)
        for file in SaveFile.allCases {
            #expect(try permissions(box.url(file)) == 0o600)
            let backups = try store.backups(for: file)
            #expect(backups.count == 1)
            for backup in backups { #expect(try permissions(backup.url) == 0o600) }
        }
        #expect(try box.temporaryFiles().isEmpty)
    }

    @Test func newAndReplacedExportsArePrivateWithoutChangingTheChosenParent() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let parent = box.directory.appendingPathComponent("chosen-export-location")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        let destination = parent.appendingPathComponent("export.json")
        for _ in 0..<2 {
            try store.exportArchive(to: destination, appVersion: "1.0")
            #expect(try permissions(destination) == 0o600)
            #expect(try permissions(parent) == 0o755)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        }
    }

    @Test func legacyPhotoFilenameIsPreservedOnImport() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        var letters = try #require(journey["letters"] as? [[String: Any]])
        letters[0]["photoFile"] = "legacy-photo.jpg"
        journey["letters"] = letters
        object["journey"] = journey
        let archive = try store.validateArchive(JSONSerialization.data(withJSONObject: object))
        #expect(archive.journey.letters[0].photoFile == "legacy-photo.jpg")
        try store.importArchive(archive)
        guard case .loaded(let state) = store.journey else { Issue.record("Imported save must load"); return }
        #expect(state.letters[0].photoFile == "legacy-photo.jpg")
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777
    }

    @Test func archiveRoundTripPreservesJourneyAndCare() throws {
        let source = try ArchiveSandbox(), destination = try ArchiveSandbox()
        defer { source.cleanUp(); destination.cleanUp() }
        let original = try source.store()
        let target = try destination.store(populated: false)
        let exported = try original.exportArchive(appVersion: "1.2.3")
        let archive = try target.validateArchive(exported)
        #expect(archive.appVersion == "1.2.3")
        #expect(archive.exportedAt == Date(timeIntervalSince1970: 0))
        try target.importArchive(archive)
        guard case .loaded(let journey) = target.journey, case .loaded(let care) = target.care,
              case .loaded(let oldJourney) = original.journey, case .loaded(let oldCare) = original.care else {
            Issue.record("Both files must load immediately after import"); return
        }
        #expect(journey == oldJourney)
        #expect(care == oldCare)
        #expect(!target.isLocked)
        #expect(try destination.temporaryFiles().isEmpty)
        let json = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(Set(json.keys) == ["format", "exportedAt", "appVersion", "journey", "care"])
        #expect(json["format"] as? Int == 1)
    }

    @Test func exportNeverIncludesSiblingCredentialsOrPhotoBytes() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let secret = "FAKE_ONLY_archive_secret_7x"
        try Data("{\"accessToken\":\"\(secret)\",\"token\":\"\(secret)\"}".utf8)
            .write(to: box.directory.appendingPathComponent("credentials.json"))
        let photos = box.directory.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("FAKE_PHOTO_BYTES".utf8).write(to: photos.appendingPathComponent("letter-7.png"))
        let text = String(decoding: try store.exportArchive(appVersion: "1.0"), as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("accessToken"))
        #expect(!text.lowercased().contains("token"))
        #expect(!text.contains("FAKE_PHOTO_BYTES"))
    }

    @Test func exportUsesAtomicFileReplacementAndDatedFilename() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let name = SaveStore.suggestedArchiveFilename(date: Date(timeIntervalSince1970: 0), calendar: calendar)
        #expect(name == "voyage-save-1970-01-01.json")
        let file = box.directory.appendingPathComponent(name)
        try Data("old export".utf8).write(to: file)
        try store.exportArchive(to: file, appVersion: "1.0")
        let candidate = try store.validateArchive(at: file)
        #expect(candidate.appVersion == "1.0")
        #expect(try box.temporaryFiles().isEmpty)
    }

    @Test(arguments: ["broken", "header", "journey", "care", "requiredJourney", "requiredCare", "format", "newerFormat", "newerJourney", "newerCare", "invalidVersion"])
    func archiveValidationRejectsInvalidInputWithoutTouchingCurrentFiles(problem: String) throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var expected = SaveArchiveError.invalidArchive
        switch problem {
        case "header": object.removeValue(forKey: "exportedAt")
        case "journey": object.removeValue(forKey: "journey"); expected = .invalidSave(.journey)
        case "care": object.removeValue(forKey: "care"); expected = .invalidSave(.care)
        case "requiredJourney":
            var journey = try #require(object["journey"] as? [String: Any])
            journey.removeValue(forKey: "seed")
            object["journey"] = journey
            expected = .invalidSave(.journey)
        case "requiredCare":
            var care = try #require(object["care"] as? [String: Any])
            care.removeValue(forKey: "petName")
            object["care"] = care
            expected = .invalidSave(.care)
        case "format": object["format"] = 0; expected = .unsupportedFormat(0)
        case "newerFormat": object["format"] = 99; expected = .unsupportedFormat(99)
        case "newerJourney", "newerCare", "invalidVersion":
            let file: SaveFile = problem == "newerCare" ? .care : .journey
            let key = file == .care ? "care" : "journey"
            var state = try #require(object[key] as? [String: Any])
            let version = problem == "invalidVersion" ? 0 : 99
            state["version"] = version
            object[key] = state
            expected = version == 0 ? .invalidSave(file) : .newerSave(file: file, version: version)
        default: break
        }
        let data = problem == "broken" ? Data("{PRIVATE_FAKE_CONTENT".utf8) : try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try store.validateArchive(data)
            Issue.record("Invalid archive must be rejected")
        } catch let error as SaveArchiveError {
            #expect(error == expected)
            #expect(!String(describing: error).contains("PRIVATE_FAKE_CONTENT"))
        }
        #expect(try box.bytes() == original)
        #expect(try store.backups(for: .journey).isEmpty)
        #expect(try store.backups(for: .care).isEmpty)
        #expect(try box.temporaryFiles().isEmpty)
        #expect(!store.isLocked)
    }

    @Test func oversizedArchiveIsRejectedBeforeReadingItsContents() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        let file = box.directory.appendingPathComponent("huge.json")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SaveStore.maximumArchiveBytes + 1))
        try handle.close()
        #expect(throws: SaveArchiveError.tooLarge) { try store.validateArchive(at: file) }
        #expect(throws: SaveArchiveError.tooLarge) { try store.validateArchive(Data(count: SaveStore.maximumArchiveBytes + 1)) }
        #expect(try box.bytes() == original)
        #expect(try box.temporaryFiles().isEmpty)
        #expect(try store.backups(for: .journey).isEmpty)
    }

    @Test func oldVersionArchiveMigratesBothStatesWithoutValidationSideEffects() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        let archive = try store.validateArchive(box.archive(journey: "journey-v1", care: "care-v1"))
        #expect(archive.journey.version == JourneyState.currentVersion)
        #expect(archive.care.version == CareState.currentVersion)
        #expect(archive.journey.stamps.first?.countryCode == "CN")
        #expect(archive.journey.legCost > 0)
        #expect(try box.bytes() == original)
        #expect(try store.backups(for: .journey).isEmpty)
        try store.importArchive(archive)
        guard case .loaded(let journey) = store.journey, case .loaded(let care) = store.care else {
            Issue.record("Migrated pair must load"); return
        }
        #expect(journey == archive.journey)
        #expect(care == archive.care)
    }

    @Test func importBackupsPreserveBothOriginalFilesByteForByte() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        let archive = try store.validateArchive(box.archive(journey: "journey-v1"))
        var order: [SaveArchiveOperation] = []
        store.archiveOperation = { order.append($0) }
        try store.importArchive(archive)
        #expect(order == [.stage(.journey), .stage(.care), .backup(.journey), .backup(.care), .replace(.journey), .replace(.care)])
        for file in SaveFile.allCases {
            let backups = try store.backups(for: file)
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: #require(backups.first).url) == original[file])
        }
        #expect(try box.temporaryFiles().isEmpty)
    }

    @Test(arguments: [SaveArchiveOperation.stage(.journey), .stage(.care), .backup(.journey), .backup(.care), .replace(.journey), .replace(.care)])
    func failureAtEachImportBoundaryRestoresBothOriginalFiles(failure: SaveArchiveOperation) throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        let archive = try store.validateArchive(box.archive(journey: "journey-v1"))
        enum Injected: Error { case failure }
        store.archiveOperation = { operation in if operation == failure { throw Injected.failure } }
        #expect(throws: SaveArchiveError.writeFailed) { try store.importArchive(archive) }
        #expect(try box.bytes() == original)
        #expect(try box.temporaryFiles().isEmpty)
        #expect(!store.isLocked)
        store.archiveOperation = nil
        store.load()
        #expect(!store.isLocked)
    }

    @Test func failureAfterFirstReplacementRestoresMissingPairToMissing() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store(populated: false)
        let archive = try store.validateArchive(box.archive())
        enum Injected: Error { case failure }
        store.archiveOperation = { if $0 == .replace(.care) { throw Injected.failure } }
        #expect(throws: SaveArchiveError.writeFailed) { try store.importArchive(archive) }
        #expect(!FileManager.default.fileExists(atPath: box.url(.journey).path))
        #expect(!FileManager.default.fileExists(atPath: box.url(.care).path))
        #expect(try box.temporaryFiles().isEmpty)
        #expect(!store.isLocked)
    }

    @Test func archiveCanRecoverCorruptionButNeverOverwriteNewerCurrentSave() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store(populated: false)
        let archive = try store.validateArchive(box.archive())
        let corrupt = Data("broken current save".utf8)
        try corrupt.write(to: box.url(.journey))
        store.load()
        #expect(store.isLocked)
        try store.importArchive(archive)
        #expect(!store.isLocked)
        #expect(try Data(contentsOf: #require(store.backups(for: .journey).first).url) == corrupt)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: box.url(.journey))) as? [String: Any])
        json["version"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: box.url(.journey))
        store.load()
        #expect(throws: SaveArchiveError.newerSave(file: .journey, version: 99)) { try store.importArchive(archive) }
        #expect(try Data(contentsOf: box.url(.journey)) == future)
        #expect(try box.temporaryFiles().isEmpty)
    }

    @Test func importDiscardsUnknownCredentialFieldsRatherThanPersistingThem() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        journey["accessToken"] = "FAKE_SECRET_ONLY"
        object["journey"] = journey
        object["token"] = "FAKE_SECRET_ONLY"
        let candidate = try store.validateArchive(JSONSerialization.data(withJSONObject: object))
        try store.importArchive(candidate)
        let output = String(decoding: try store.exportArchive(appVersion: "1.0"), as: UTF8.self)
        #expect(!output.contains("FAKE_SECRET_ONLY"))
        #expect(!output.contains("accessToken"))
    }

    @Test(arguments: ["route", "currentCity", "targetCity", "startDate", "openDate", "reversedDates", "dayKey", "stampDate", "letterDate", "careHatched", "careWeek", "careCompanion", "careStamp", "careMemory", "careSpecialDay"])
    func importRejectsRuntimeInvariantViolationsWithoutChangingSaves(problem: String) throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        var care = try #require(object["care"] as? [String: Any])
        switch problem {
        case "route": journey["route"] = [] as [String]
        case "currentCity": journey["currentCityId"] = ""
        case "targetCity": journey["targetCityId"] = ""
        case "startDate": journey["startDate"] = "not-a-date"
        case "openDate": journey["openDate"] = "2026-02-30"
        case "reversedDates": journey["startDate"] = "2026-11-03"
        case "dayKey": journey["days"] = ["2026-99-99": ["fuel": 100]]
        case "stampDate":
            var stamps = try #require(journey["stamps"] as? [[String: Any]])
            stamps[0]["date"] = "2026-2-3"
            journey["stamps"] = stamps
        case "letterDate":
            var letters = try #require(journey["letters"] as? [[String: Any]])
            letters[0]["date"] = "invalid"
            journey["letters"] = letters
        case "careHatched": care["hatchedAt"] = "2026-02-30"
        case "careWeek": care["weekly"] = ["weekStart": "invalid"]
        case "careCompanion": care["companionDays"] = ["2026-13-01"]
        case "careStamp": care["weekly"] = ["weekStart": "2026-11-02", "stamps": ["invalid"]]
        case "careMemory": care["memories"] = [["kind": "reply", "date": "invalid", "letterId": 1]]
        case "careSpecialDay": care["specialDays"] = [["kind": "hatched", "date": "2026-02-30", "letterId": 0]]
        default: break
        }
        object["journey"] = journey
        object["care"] = care
        let expected = SaveArchiveError.invalidSave(problem.hasPrefix("care") ? .care : .journey)
        #expect(throws: expected) { try store.validateArchive(JSONSerialization.data(withJSONObject: object)) }
        #expect(try box.bytes() == original)
        #expect(try store.backups(for: .journey).isEmpty)
        #expect(try store.backups(for: .care).isEmpty)
        #expect(try box.temporaryFiles().isEmpty)
    }

    @Test(arguments: ["../outside.png", "nested/file.png", "/private/fake.png", "nested\\file.png", "", ".", "..", "bad\0name.png"])
    func importRejectsPhotoPathTraversalWithoutReadingPhotos(filename: String) throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        var letters = try #require(journey["letters"] as? [[String: Any]])
        letters[0]["photoFile"] = filename
        journey["letters"] = letters
        object["journey"] = journey
        #expect(throws: SaveArchiveError.invalidSave(.journey)) {
            try store.validateArchive(JSONSerialization.data(withJSONObject: object))
        }
        #expect(try box.bytes() == original)
        #expect(try box.temporaryFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.directory.appendingPathComponent("photos").path))
    }

    @Test(arguments: ["negativeLetter", "maximumLetter", "minimumComparison", "negativeLeg", "finishedLeg", "negativeTotal", "maximumTotal", "negativeDaily", "maximumDaily", "negativeClient", "clientSumOverflow", "badCoordinate", "careHabit", "careNegativeHabit", "carePity", "careBoxes", "careClue", "careAttempts"])
    func importRejectsValuesThatWouldTrapInRuntimeArithmetic(problem: String) throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        let original = try box.bytes()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        var care = try #require(object["care"] as? [String: Any])
        switch problem {
        case "negativeLetter", "maximumLetter", "minimumComparison":
            var letters = try #require(journey["letters"] as? [[String: Any]])
            letters[0][problem == "minimumComparison" ? "compareToMedianPercent" : "id"] =
                problem == "negativeLetter" ? -1 : (problem == "maximumLetter" ? Int.max : Int.min)
            journey["letters"] = letters
        case "negativeLeg": journey["legFuel"] = -1
        case "finishedLeg": journey["legFuel"] = journey["legCost"]
        case "negativeTotal": journey["totalFuel"] = -1
        case "maximumTotal": journey["totalFuel"] = Int.max
        case "negativeDaily": journey["days"] = ["2026-11-01": ["fuel": -1]]
        case "maximumDaily": journey["days"] = ["2026-11-01": ["fuel": Int.max]]
        case "negativeClient": journey["days"] = ["2026-11-01": ["fuel": 1, "byClient": ["fake": -1]]] as [String: Any]
        case "clientSumOverflow": journey["days"] = ["2026-11-01": ["fuel": 1, "byClient": ["fakeA": Int.max, "fakeB": 1]]] as [String: Any]
        case "badCoordinate": journey["legTo"] = ["lat": 1e300, "lon": 0]
        case "careHabit": care["habits"] = ["talkative": Int.max]
        case "careNegativeHabit": care["habits"] = ["observant": -1]
        case "carePity": care["pity"] = Int.max
        case "careBoxes": care["boxesOpened"] = Int.max
        case "careClue": care["trailClues"] = ["unknown-city": Int.max]
        case "careAttempts": care["pendingPromises"] = [["replyId": "fake-reply", "letterId": 1, "attempts": Int.max]] as [[String: Any]]
        default: break
        }
        object["journey"] = journey
        object["care"] = care
        #expect(throws: SaveArchiveError.invalidSave(problem.hasPrefix("care") ? .care : .journey)) {
            try store.validateArchive(JSONSerialization.data(withJSONObject: object))
        }
        #expect(try box.bytes() == original)
        #expect(try box.temporaryFiles().isEmpty)
        #expect(try store.backups(for: .journey).isEmpty)
        #expect(try store.backups(for: .care).isEmpty)
    }

    @Test func importKeepsUnknownPetsAndCitiesForExistingPlaceholderRendering() throws {
        let box = try ArchiveSandbox()
        defer { box.cleanUp() }
        let store = try box.store()
        var object = try #require(JSONSerialization.jsonObject(with: box.archive()) as? [String: Any])
        var journey = try #require(object["journey"] as? [String: Any])
        journey["pet"] = "removed-pet"
        journey["route"] = ["removed-city"]
        journey["currentCityId"] = "removed-city"
        journey["targetCityId"] = "removed-target"
        var care = try #require(object["care"] as? [String: Any])
        care["species"] = "removed-pet"
        object["journey"] = journey
        object["care"] = care
        let archive = try store.validateArchive(JSONSerialization.data(withJSONObject: object))
        try store.importArchive(archive)
        #expect(!store.isLocked)
        #expect(archive.journey.pet.rawValue == "removed-pet")
        #expect(archive.journey.route == ["removed-city"])
        #expect(testCatalog.city(archive.journey.currentCityId).isPlaceholder)
        #expect(testCatalog.pets.sprite(archive.journey.pet).rows == testCatalog.pets.eggs.placeholder.rows)
    }
}
