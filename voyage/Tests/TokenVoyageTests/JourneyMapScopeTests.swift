import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class MapScopeDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    private(set) var writes: [String] = []
    override func object(forKey name: String) -> Any? { values[name] }
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func set(_ value: Any?, forKey name: String) { values[name] = value; writes.append(name) }
}

@Suite @MainActor struct JourneyMapScopeTests {
    private func model(directory: URL, defaults: MapScopeDefaults, snapshot: Bool = false) -> AppModel {
        AppModel(isSnapshot: snapshot, defaults: defaults, directory: directory,
                 catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
    }

    @Test func defaultsToRegionAndPersistsWorldAndRegionThroughInjectedDefaults() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-map-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = MapScopeDefaults()
        let app = model(directory: directory, defaults: defaults)
        #expect(app.journeyMapScope == .region)
        #expect(!defaults.writes.contains("journeyMapScope"))
        app.journeyMapScope = .world
        #expect(defaults.string(forKey: "journeyMapScope") == "world")
        let restored = model(directory: directory, defaults: defaults)
        #expect(restored.journeyMapScope == .world)
        restored.journeyMapScope = .region
        #expect(defaults.string(forKey: "journeyMapScope") == "region")
        #expect(model(directory: directory, defaults: defaults).journeyMapScope == .region)
        #expect(defaults.writes.filter { $0 == "journeyMapScope" }.count == 2)
    }

    @Test func unknownStoredScopeFallsBackToRegion() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-map-scope-unknown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = MapScopeDefaults()
        defaults.values["journeyMapScope"] = "unknown"
        #expect(model(directory: directory, defaults: defaults).journeyMapScope == .region)
        #expect(!defaults.writes.contains("journeyMapScope"))
    }

    @Test func snapshotScopeCanChangeWithoutWritingDefaultsOrCreatingData() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-map-scope-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = MapScopeDefaults()
        defaults.values["journeyMapScope"] = "region"
        let app = model(directory: directory, defaults: defaults, snapshot: true)
        app.journeyMapScope = .world
        #expect(app.journeyMapScope == .world)
        #expect(defaults.string(forKey: "journeyMapScope") == "region")
        #expect(defaults.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func scopeLabelsAreAvailableInBothLanguages() {
        for language in Language.allCases {
            let l10n = L10n(language: language)
            for key in ["journey.mapScope.region", "journey.mapScope.world", "journey.mapScope.label"] {
                #expect(l10n(key) != key)
            }
        }
    }
}
