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

/// Owns both save files. No caller can save one while the other needs recovery.
public final class SaveStore {
    public let directory: URL
    public private(set) var journey: SaveLoadResult<JourneyState> = .unreadable(reason: "Save store has not been loaded.")
    public private(set) var care: SaveLoadResult<CareState> = .unreadable(reason: "Save store has not been loaded.")
    public var isLocked: Bool { !journey.allowsSaving || !care.allowsSaving }

    private let now: () -> Date
    private let journeyMigrations: SaveMigrations
    private let careMigrations: SaveMigrations
    private let files = FileManager.default
    private var pendingRestarts: Set<SaveFile> = []

    public init(
        directory: URL, now: @escaping () -> Date = Date.init,
        journeyMigrations: SaveMigrations = SaveMigrations(currentVersion: JourneyState.currentVersion),
        careMigrations: SaveMigrations = SaveMigrations(currentVersion: CareState.currentVersion)
    ) {
        self.directory = directory
        self.now = now
        self.journeyMigrations = journeyMigrations
        self.careMigrations = careMigrations
    }

    public func load() {
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
                try save(CareState.legacy(from: saved))
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
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let name = "\(file.rawValue).v\(version.map(String.init) ?? "unknown").\(timestamp).\(UUID().uuidString).\(kind).json"
        let backup = backupDirectory.appendingPathComponent(name)
        if moving {
            try files.moveItem(at: url(for: file), to: backup)
        } else {
            try files.copyItem(at: url(for: file), to: backup)
        }
        return backup
    }

    private func atomicWrite(_ data: Data, to file: SaveFile) throws {
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: file), options: .atomic)
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
