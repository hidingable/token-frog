import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@MainActor
@Test func snapshotLanguageOverrideDoesNotWriteLanguagePreference() throws {
    let defaults = MemoryDefaults()
    defaults.set("zh-Hans", forKey: "language")
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/language-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let model = AppModel(isSnapshot: true, languageOverride: .en, defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes)
    #expect(model.languagePreference == .zhHans)
    #expect(model.l10n.language == .en)
    model.languagePreference = .en
    #expect(defaults.string(forKey: "language") == "zh-Hans")
    #expect(model.l10n.language == .en)
}

@MainActor
@Test func languagePreferenceChangesRefreshCurrentLocalization() throws {
    let defaults = MemoryDefaults()
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/language-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(isSnapshot: true, defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes)
    #expect(model.languagePreference == .system)
    model.languagePreference = .zhHans
    let before = model.l10n("nav.journey")
    model.languagePreference = .en
    #expect(model.l10n.language == .en)
    #expect(before != model.l10n("nav.journey"))
    #expect(model.l10n("nav.journey") == "Journey")
    #expect(defaults.string(forKey: "language") == nil)
}

@MainActor
@Test func modelUsesTheSavedCareNameInBothLanguages() throws {
    let defaults = MemoryDefaults()
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/language-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SaveStore(directory: directory, journeyMigrations: .journey(catalog: localizationCatalog))
    store.load()
    let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    try store.save(journey)
    try store.save(CareState(petName: "银杏 Ginkgo", species: .pigeon, hatchedAt: "2026-11-01"))
    let model = AppModel( defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes)
    let letter = try #require(model.state?.letters.first)
    for preference in [LanguagePreference.zhHans, .en] {
        model.languagePreference = preference
        #expect(model.petName == "银杏 Ginkgo")
        let text = LetterComposer.text(for: letter, l10n: model.l10n, petName: model.petName, catalog: localizationCatalog)
        #expect(text.signature.hasSuffix("银杏 Ginkgo"))
    }
}

/// Keeps every settings read and write in memory, including across parallel tests.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
@Test func normalLanguageChangesPersistThePreference() throws {
    let defaults = MemoryDefaults()
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/language-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes)
    model.languagePreference = .zhHans
    #expect(defaults.string(forKey: "language") == "zh-Hans")
    model.languagePreference = .en
    #expect(defaults.string(forKey: "language") == "en")
    let reloaded = AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes)
    #expect(reloaded.languagePreference == .en)
}

@MainActor
@Test(arguments: ["missing", "corrupt", "empty", "oneActive"])
func invalidContentLocksBeforeAnySaveOrScan(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-content-lock-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("data")
    let content = root.appendingPathComponent("Content")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    if mode != "missing" {
        try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content"), to: content)
        if mode == "corrupt" {
            try Data("broken content".utf8).write(to: content.appendingPathComponent("manifest.json"))
        } else {
            for city in localizationCatalog.all where mode == "empty" || city.id != "shanghai" {
                let file = content.appendingPathComponent("cities/\(city.id).json")
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                json["status"] = "retired"
                try JSONSerialization.data(withJSONObject: json).write(to: file)
            }
        }
    }
    let model = AppModel(defaults: MemoryDefaults(), directory: directory, contentDirectory: content)
    #expect(model.isLocked)
    #expect(model.state == nil)
    #expect(model.care == nil)
    #expect(model.recoveryIssues.count == 1)
    let issue = try #require(model.recoveryIssues.first)
    guard case .content = issue.problem else { Issue.record("Content failure must show reinstall recovery"); return }
    #expect(L10n(language: .zhHans)("recovery.content") == "内容文件损坏，请重新安装应用")
    model.start()
    model.scheduleScan(immediately: true)
    await model.scan()
    await model.loadDashboard()
    await model.loadQuotas(force: true)
    await model.enrichLatest()
    model.retrySaves()
    model.restartSave(.journey)
    model.restoreSave(SaveBackup(file: .journey, url: directory.appendingPathComponent("not-a-backup")))
    model.setStart("beijing")
    #expect(model.isLocked && model.state == nil)
    #expect(model.lastScan == nil && model.lastError == nil)
    #expect(model.dashboardDays == nil && model.quotasLoadedAt == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@MainActor
@Test func badContentDoesNotEvenQuarantineAnExistingBrokenSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-content-no-read-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("journey.json")
    let original = Data("do not touch".utf8)
    try original.write(to: file)
    let model = AppModel(defaults: MemoryDefaults(), directory: directory, contentDirectory: directory.appendingPathComponent("missing-content"))
    model.retrySaves()
    #expect(model.isLocked && model.state == nil)
    #expect(try Data(contentsOf: file) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["journey.json"])
}

@MainActor
@Test func startCityListUsesActiveCitiesAndCurrentLanguageOrdering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-start-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(isSnapshot: true, defaults: MemoryDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes)
    for preference in [LanguagePreference.zhHans, .en] {
        model.languagePreference = preference
        let expected = localizationCatalog.active.sorted { model.l10n.cityName($0).compare(model.l10n.cityName($1), locale: model.l10n.locale) == .orderedAscending }
        #expect(model.startCities.map(\.id) == expected.map(\.id))
    }
    #expect(model.startCities.count == 107)
}
