import Darwin
import Foundation

public enum SaveLoadResult<State> {
    case missing
    case loaded(State)
    case corrupted(backup: URL)
    case tooNew(version: Int)
    case unreadable(reason: String)

    public var allowsSaving: Bool {
        switch self {
        case .missing, .loaded: true
        case .corrupted, .tooNew, .unreadable: false
        }
    }
}

/// Step n transforms the JSON dictionary from version n to n + 1. The store owns the version key.
public struct SaveMigrations {
    public typealias Step = ([String: Any]) throws -> [String: Any]
    public let currentVersion: Int
    public let steps: [Int: Step]

    public init(currentVersion: Int, steps: [Int: Step] = [:]) {
        precondition(currentVersion >= 1)
        self.currentVersion = currentVersion
        self.steps = steps
    }
}

public enum SaveFile: String, CaseIterable, Hashable, Sendable {
    case journey = "journey.json"
    case care = "care.json"
}

public struct SaveBackup: Equatable, Sendable, Identifiable {
    public let file: SaveFile
    public let url: URL
    public var id: URL { url }

    public init(file: SaveFile, url: URL) {
        self.file = file
        self.url = url
    }
}

public enum SaveStoreError: Error, Equatable {
    case locked
    case invalidVersion
    case tooNew(Int)
    case missingMigration(Int)
    case invalidJSON
    case restartNotAllowed
}

public enum SaveArchiveError: Error, Equatable {
    case tooLarge
    case unreadable
    case invalidArchive
    case unsupportedFormat(Int)
    case newerSave(file: SaveFile, version: Int)
    case invalidSave(SaveFile)
    case unavailable
    case writeFailed
    case recoveryRequired
}

/// A fully decoded, migrated pair. Creating this value never changes the current saves.
public struct ValidatedSaveArchive: Sendable {
    public let exportedAt: Date
    public let appVersion: String
    public let journey: JourneyState
    public let care: CareState
    fileprivate let journeyData: Data
    fileprivate let careData: Data
}

enum SaveArchiveOperation: Equatable, Sendable {
    case stage(SaveFile)
    case backup(SaveFile)
    case replace(SaveFile)
}

/// Owns both save files. No caller can save one while the other needs recovery.
public final class SaveStore {
    public let directory: URL
    public private(set) var journey: SaveLoadResult<JourneyState> = .unreadable(reason: "Save store has not been loaded.")
    public private(set) var care: SaveLoadResult<CareState> = .unreadable(reason: "Save store has not been loaded.")
    public var isLocked: Bool { !journey.allowsSaving || !care.allowsSaving }

    private let pets: PetCatalog?
    private let now: () -> Date
    private let journeyMigrations: SaveMigrations
    private let careMigrations: SaveMigrations
    private let files = FileManager.default
    private var pendingRestarts: Set<SaveFile> = []
    private var repairedPermissions = false
    // Test seam for failures at each transaction boundary; production uses Foundation file operations.
    var archiveOperation: ((SaveArchiveOperation) throws -> Void)?

    public static let maximumArchiveBytes = 50 * 1_024 * 1_024

    public init(
        directory: URL, now: @escaping () -> Date = Date.init, pets: PetCatalog?,
        journeyMigrations: SaveMigrations,
        careMigrations: SaveMigrations = SaveMigrations(currentVersion: CareState.currentVersion)
    ) {
        self.pets = pets
        self.directory = directory
        self.now = now
        self.journeyMigrations = journeyMigrations
        self.careMigrations = careMigrations
    }

    public func load() {
        if !repairedPermissions {
            PrivateStorage.repairPermissions(in: directory)
            repairedPermissions = true
        }
        let pendingJourney: (SaveLoadResult<JourneyState>, Data?) = prepare(.journey, migrations: journeyMigrations)
        let pendingCare: (SaveLoadResult<CareState>, Data?) = prepare(.care, migrations: careMigrations)
        journey = pendingJourney.0
        care = pendingCare.0
        guard !isLocked else { return }
        // Stage both files before writing a migration, so a recovery issue locks the whole store.
        do {
            if let data = pendingJourney.1 { try atomicWrite(data, to: .journey) }
            if let data = pendingCare.1 { try atomicWrite(data, to: .care) }
            if case .loaded(let saved) = journey, case .missing = care {
                try save(CareState.legacy(from: saved, pets: pets))
            }
        } catch {
            // atomicWrite records the failing file as unreadable.
        }
    }

    public func save(_ state: JourneyState) throws {
        guard !isLocked else { throw SaveStoreError.locked }
        guard state.version == journeyMigrations.currentVersion else { throw SaveStoreError.invalidVersion }
        let data = try JSONEncoder().encode(state)
        try atomicWrite(data, to: .journey)
        journey = .loaded(state)
    }

    public func save(_ state: CareState) throws {
        guard !isLocked else { throw SaveStoreError.locked }
        guard state.version == careMigrations.currentVersion else { throw SaveStoreError.invalidVersion }
        let data = try JSONEncoder().encode(state)
        try atomicWrite(data, to: .care)
        care = .loaded(state)
    }

    public static func suggestedArchiveFilename(date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "voyage-save-%04d-%02d-%02d.json", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Exports only the two typed game states. Credentials, settings and photo files are not read.
    public func exportArchive(appVersion: String) throws -> Data {
        guard case .loaded(let journey) = journey, case .loaded(let care) = care, !isLocked else {
            throw SaveArchiveError.unavailable
        }
        // Journey's dates use its existing numeric encoding, independently of envelope metadata.
        let journeyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journey))
        let careJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(care))
        let json: [String: Any] = [
            "format": 1, "exportedAt": ISO8601DateFormatter().string(from: now()), "appVersion": appVersion,
            "journey": journeyJSON, "care": careJSON,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    public func exportArchive(to destination: URL, appVersion: String) throws {
        let data = try exportArchive(appVersion: appVersion)
        do { try PrivateStorage.write(data, to: destination) }
        catch { throw SaveArchiveError.writeFailed }
    }

    /// Reads at most 50 MB, including when the chosen file grows after the size check.
    public func validateArchive(at source: URL) throws -> ValidatedSaveArchive {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(Self.maximumArchiveBytes) else { throw SaveArchiveError.tooLarge }
            try handle.seek(toOffset: 0)
            data = try handle.read(upToCount: Self.maximumArchiveBytes + 1) ?? Data()
        } catch let error as SaveArchiveError {
            throw error
        } catch {
            throw SaveArchiveError.unreadable
        }
        return try validateArchive(data)
    }

    public func validateArchive(_ data: Data) throws -> ValidatedSaveArchive {
        guard data.count <= Self.maximumArchiveBytes else { throw SaveArchiveError.tooLarge }
        struct Header: Decodable {
            let format: Int
            let exportedAt: String
            let appVersion: String
        }
        let header: Header
        let json: [String: Any]
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SaveArchiveError.invalidArchive
            }
            json = object
        } catch { throw SaveArchiveError.invalidArchive }
        guard header.format == 1 else { throw SaveArchiveError.unsupportedFormat(header.format) }
        let dateParser = ISO8601DateFormatter()
        guard let exportedAt = dateParser.date(from: header.exportedAt), !header.appVersion.isEmpty else {
            throw SaveArchiveError.invalidArchive
        }
        let (journey, journeyData) = try validatedArchiveState(
            json["journey"], file: .journey, as: JourneyState.self, migrations: journeyMigrations
        )
        let (care, careData) = try validatedArchiveState(
            json["care"], file: .care, as: CareState.self, migrations: careMigrations
        )
        // Imported files cross a trust boundary. These are runtime invariants assumed by route[0],
        // day settlement and the photo loader; the existing version decoders only check the JSON shape.
        let dayParser = DateFormatter()
        dayParser.calendar = Calendar(identifier: .gregorian)
        dayParser.timeZone = TimeZone(secondsFromGMT: 0)
        dayParser.locale = Locale(identifier: "en_US_POSIX")
        dayParser.dateFormat = "yyyy-MM-dd"
        dayParser.isLenient = false
        func validDay(_ key: String) -> Bool {
            guard key.count == 10, let date = dayParser.date(from: key) else { return false }
            return dayParser.string(from: date) == key
        }
        // Settlement multiplies daily fuel by 100 before converting a percentage to Int.
        // Reserve the same daily range for the next totalFuel += delta operation.
        let maximumDailyFuel = Int(Double(Int.max).nextDown / 100)
        func validRecord(_ record: DayRecord) -> Bool {
            guard (0...maximumDailyFuel).contains(record.fuel) else { return false }
            var total = 0
            for fuel in record.byClient.values {
                guard fuel >= 0 else { return false }
                let addition = total.addingReportingOverflow(fuel)
                guard !addition.overflow else { return false }
                total = addition.partialValue
            }
            return true
        }
        func validCoordinate(_ coordinate: Coordinate) -> Bool {
            (-90...90).contains(coordinate.lat) && (-180...180).contains(coordinate.lon)
        }
        guard !journey.route.isEmpty, journey.route.allSatisfy({ !$0.isEmpty }),
              !journey.currentCityId.isEmpty, !journey.targetCityId.isEmpty,
              (0..<journey.legCost).contains(journey.legFuel),
              (0...(Int.max - maximumDailyFuel)).contains(journey.totalFuel),
              validCoordinate(journey.legFrom), validCoordinate(journey.legTo),
              validDay(journey.startDate), validDay(journey.openDate), journey.startDate <= journey.openDate,
              journey.days.keys.allSatisfy(validDay), journey.days.values.allSatisfy(validRecord),
              journey.stamps.allSatisfy({ validDay($0.date) }),
              journey.letters.allSatisfy({ letter in
                  guard validDay(letter.date), (0..<Int.max).contains(letter.id), letter.fuel >= 0,
                        letter.compareToMedianPercent != Int.min else { return false }
                  guard let name = letter.photoFile else { return true }
                  return !name.isEmpty && name != "." && name != ".."
                      && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
              }) else { throw SaveArchiveError.invalidSave(.journey) }
        guard validDay(care.hatchedAt), validDay(care.weekly.weekStart),
              (0...100).contains(care.habits.talkative), (0...100).contains(care.habits.observant),
              (0..<Int.max).contains(care.pity), (0..<Int.max).contains(care.boxesOpened),
              care.trailClues.values.allSatisfy({ (0..<Int.max).contains($0) }),
              care.pendingPromises.allSatisfy({ (0..<Int.max).contains($0.attempts) }),
              care.companionDays.allSatisfy(validDay), care.weekly.stamps.allSatisfy(validDay),
              care.memories.allSatisfy({ validDay($0.date) }) else { throw SaveArchiveError.invalidSave(.care) }
        return ValidatedSaveArchive(exportedAt: exportedAt, appVersion: header.appVersion,
                                    journey: journey, care: care, journeyData: journeyData, careData: careData)
    }

    private func validatedArchiveState<State: Codable>(
        _ object: Any?, file: SaveFile, as type: State.Type, migrations: SaveMigrations
    ) throws -> (State, Data) {
        do {
            guard let object = object as? [String: Any] else { throw SaveArchiveError.invalidSave(file) }
            let original = try JSONSerialization.data(withJSONObject: object)
            let result = try validated(original, as: type, migrations: migrations)
            // Drop unknown external fields, rather than importing arbitrary credential-like data.
            return (result.state, try JSONEncoder().encode(result.state))
        } catch {
            if let saveError = error as? SaveStoreError, case .tooNew(let version) = saveError {
                throw SaveArchiveError.newerSave(file: file, version: version)
            }
            throw SaveArchiveError.invalidSave(file)
        }
    }

    /// Call only after the UI confirms replacement. Stages both files before touching either current file.
    public func importArchive(_ archive: ValidatedSaveArchive) throws {
        for file in SaveFile.allCases {
            let currentVersion = file == .journey ? journeyMigrations.currentVersion : careMigrations.currentVersion
            let incomingVersion = file == .journey ? archive.journey.version : archive.care.version
            guard incomingVersion == currentVersion else {
                if incomingVersion > currentVersion { throw SaveArchiveError.newerSave(file: file, version: incomingVersion) }
                throw SaveArchiveError.invalidSave(file)
            }
        }
        if case .tooNew(let version) = journey { throw SaveArchiveError.newerSave(file: .journey, version: version) }
        if case .tooNew(let version) = care { throw SaveArchiveError.newerSave(file: .care, version: version) }

        let transactionID = UUID().uuidString
        let staged = Dictionary(uniqueKeysWithValues: SaveFile.allCases.map {
            ($0, directory.appendingPathComponent(".voyage-import-\(transactionID)-\($0.rawValue).pending"))
        })
        var rollbackFiles: [SaveFile: URL] = [:]
        var installed: Set<SaveFile> = []
        var mayRemoveRollback = false
        defer {
            for temporary in staged.values { try? files.removeItem(at: temporary) }
            if mayRemoveRollback {
                for original in rollbackFiles.values { try? files.removeItem(at: original) }
            }
        }
        do {
            try PrivateStorage.createDirectory(at: directory)
            var current: [SaveFile: Data] = [:]
            for file in SaveFile.allCases {
                do { current[file] = try Data(contentsOf: url(for: file)) }
                catch { if !Self.isMissing(error) { throw error } }
                try archiveOperation?(.stage(file))
                try PrivateStorage.write(file == .journey ? archive.journeyData : archive.careData, to: staged[file]!, options: .withoutOverwriting)
                if let original = current[file] {
                    let rollback = directory.appendingPathComponent(".voyage-import-\(transactionID)-\(file.rawValue).rollback")
                    rollbackFiles[file] = rollback
                    try PrivateStorage.write(original, to: rollback, options: .withoutOverwriting)
                }
            }
            // Preserve exact original bytes before the first replacement, including unreadable JSON.
            for file in SaveFile.allCases where current[file] != nil {
                try archiveOperation?(.backup(file))
                _ = try makeBackup(for: file, version: try? version(in: current[file]!), kind: "import", moving: false)
            }
            // Match normal persistence: journey first; care can be replayed from letter snapshots.
            for file in SaveFile.allCases {
                try archiveOperation?(.replace(file))
                try replaceAtomically(staged[file]!, at: url(for: file))
                installed.insert(file)
            }
            mayRemoveRollback = true
        } catch {
            do {
                for file in SaveFile.allCases.reversed() where installed.contains(file) {
                    if let original = rollbackFiles[file] { try replaceAtomically(original, at: url(for: file)) }
                    else { try files.removeItem(at: url(for: file)) }
                }
                mayRemoveRollback = true
            } catch {
                // Preserve rollback files and exact-byte backups if the filesystem also refuses recovery.
                journey = .unreadable(reason: "The save import needs recovery from its backups.")
                care = .unreadable(reason: "The save import needs recovery from its backups.")
                throw SaveArchiveError.recoveryRequired
            }
            throw SaveArchiveError.writeFailed
        }
        pendingRestarts.removeAll()
        load()
    }

    /// POSIX rename atomically replaces an existing file on this same filesystem, without allocating a new copy.
    private func replaceAtomically(_ staged: URL, at destination: URL) throws {
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func backups(for file: SaveFile) throws -> [SaveBackup] {
        let entries: [URL]
        do {
            entries = try files.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        } catch {
            if Self.isMissing(error) { return [] }
            throw error
        }
        return entries.filter { $0.lastPathComponent.hasPrefix("\(file.rawValue).v") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { SaveBackup(file: file, url: $0) }
    }

    public func restorableBackups(for file: SaveFile) throws -> [SaveBackup] {
        try backups(for: file)
            .filter { !$0.url.lastPathComponent.hasSuffix(".corrupted.json") }
            .sorted {
                // Skip the file name and version so the backup timestamp determines the order.
                let first = $0.url.lastPathComponent.split(separator: ".").dropFirst(3)
                let second = $1.url.lastPathComponent.split(separator: ".").dropFirst(3)
                return second.lexicographicallyPrecedes(first)
            }
    }

    /// Validates without moving or editing the candidate. A failed validation has no side effects.
    public func restore(backup: SaveBackup) throws {
        let source = try Data(contentsOf: backup.url)
        let data: Data
        switch backup.file {
        case .journey:
            if case .tooNew(let version) = journey { throw SaveStoreError.tooNew(version) }
            data = try validated(source, as: JourneyState.self, migrations: journeyMigrations).data
        case .care:
            if case .tooNew(let version) = care { throw SaveStoreError.tooNew(version) }
            data = try validated(source, as: CareState.self, migrations: careMigrations).data
        }
        // Preserve an existing current file too, when explicitly replacing it with a backup.
        let current: Data?
        do {
            current = try Data(contentsOf: url(for: backup.file))
        } catch {
            guard Self.isMissing(error) else { throw error }
            current = nil
        }
        if let current {
            _ = try makeBackup(for: backup.file, version: try? version(in: current), kind: "restore", moving: false)
        }
        try atomicWrite(data, to: backup.file)
        load()
    }

    /// Consent to create a replacement for a quarantined file. Existing backups are never removed.
    public func restart(_ file: SaveFile = .journey) throws {
        switch file {
        case .journey:
            guard case .corrupted = journey else { throw SaveStoreError.restartNotAllowed }
            journey = .missing
        case .care:
            guard case .corrupted = care else { throw SaveStoreError.restartNotAllowed }
            care = .missing
        }
        pendingRestarts.insert(file)
    }

    private var backupDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    private func url(for file: SaveFile) -> URL { directory.appendingPathComponent(file.rawValue) }

    private struct Header: Decodable { let version: Int }

    private func version(in data: Data) throws -> Int {
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version >= 1 else { throw SaveStoreError.invalidVersion }
        return version
    }

    private func validated<State: Decodable>(
        _ original: Data, as type: State.Type, migrations: SaveMigrations
    ) throws -> (state: State, data: Data) {
        let version = try version(in: original)
        guard version <= migrations.currentVersion else { throw SaveStoreError.tooNew(version) }
        var data = original
        if version < migrations.currentVersion {
            guard var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SaveStoreError.invalidJSON
            }
            for stepVersion in version..<migrations.currentVersion {
                guard let step = migrations.steps[stepVersion] else { throw SaveStoreError.missingMigration(stepVersion) }
                json = try step(json)
                json["version"] = stepVersion + 1
            }
            data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return (try JSONDecoder().decode(type, from: data), data)
    }

    private func prepare<State: Decodable>(
        _ file: SaveFile, migrations: SaveMigrations
    ) -> (SaveLoadResult<State>, Data?) {
        let data: Data
        do {
            data = try Data(contentsOf: url(for: file))
        } catch {
            guard Self.isMissing(error) else { return (.unreadable(reason: error.localizedDescription), nil) }
            if pendingRestarts.contains(file) { return (.missing, nil) }
            do {
                // A quarantined save must still require consent after retrying or relaunching.
                if let backup = try backups(for: file).first(where: { $0.url.lastPathComponent.hasSuffix(".corrupted.json") }) {
                    return (.corrupted(backup: backup.url), nil)
                }
                return (.missing, nil)
            } catch {
                return (.unreadable(reason: error.localizedDescription), nil)
            }
        }
        let version: Int
        do {
            version = try JSONDecoder().decode(Header.self, from: data).version
        } catch {
            return quarantine(file, version: nil)
        }
        if version < 1 { return quarantine(file, version: version) }
        if version > migrations.currentVersion { return (.tooNew(version: version), nil) }
        if version < migrations.currentVersion {
            do {
                _ = try makeBackup(for: file, version: version, kind: "migration", moving: false)
                let migrated = try validated(data, as: State.self, migrations: migrations)
                return (.loaded(migrated.state), migrated.data)
            } catch {
                return (.unreadable(reason: error.localizedDescription), nil)
            }
        }
        do {
            return (.loaded(try JSONDecoder().decode(State.self, from: data)), nil)
        } catch {
            return quarantine(file, version: version)
        }
    }

    private func quarantine<State>(_ file: SaveFile, version: Int?) -> (SaveLoadResult<State>, Data?) {
        do {
            let backup = try makeBackup(for: file, version: version, kind: "corrupted", moving: true)
            return (.corrupted(backup: backup), nil)
        } catch {
            return (.unreadable(reason: error.localizedDescription), nil)
        }
    }

    private func makeBackup(for file: SaveFile, version: Int?, kind: String, moving: Bool) throws -> URL {
        try PrivateStorage.createDirectory(at: directory)
        try PrivateStorage.createDirectory(at: backupDirectory)
        let timestamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let name = "\(file.rawValue).v\(version.map(String.init) ?? "unknown").\(timestamp).\(UUID().uuidString).\(kind).json"
        let backup = backupDirectory.appendingPathComponent(name)
        if moving {
            try files.moveItem(at: url(for: file), to: backup)
        } else {
            try files.copyItem(at: url(for: file), to: backup)
        }
        try PrivateStorage.secureFile(at: backup)
        return backup
    }

    private func atomicWrite(_ data: Data, to file: SaveFile) throws {
        do {
            try PrivateStorage.createDirectory(at: directory)
            try PrivateStorage.write(data, to: url(for: file))
            pendingRestarts.remove(file)
        } catch {
            switch file {
            case .journey: journey = .unreadable(reason: error.localizedDescription)
            case .care: care = .unreadable(reason: error.localizedDescription)
            }
            throw error
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
