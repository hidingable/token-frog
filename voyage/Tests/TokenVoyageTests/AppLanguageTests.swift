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
    let model = AppModel(isSnapshot: true, languageOverride: .en, defaults: defaults, directory: directory)
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
    let model = AppModel(isSnapshot: true, defaults: defaults, directory: directory)
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
    let store = SaveStore(directory: directory)
    store.load()
    let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01")
    try store.save(journey)
    try store.save(CareState(petName: "银杏 Ginkgo", species: .pigeon, hatchedAt: "2026-11-01"))
    let model = AppModel(isSnapshot: true, defaults: defaults, directory: directory)
    let letter = try #require(model.state.letters.first)
    for preference in [LanguagePreference.zhHans, .en] {
        model.languagePreference = preference
        #expect(model.petName == "银杏 Ginkgo")
        let text = LetterComposer.text(for: letter, l10n: model.l10n, petName: model.petName)
        #expect(text.signature.hasSuffix("银杏 Ginkgo"))
    }
}

/// Keeps every settings read and write in memory, including across parallel tests.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
@Test func normalLanguageChangesPersistThePreference() throws {
    let defaults = MemoryDefaults()
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/language-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(defaults: defaults, directory: directory)
    model.languagePreference = .zhHans
    #expect(defaults.string(forKey: "language") == "zh-Hans")
    model.languagePreference = .en
    #expect(defaults.string(forKey: "language") == "en")
    let reloaded = AppModel(defaults: defaults, directory: directory)
    #expect(reloaded.languagePreference == .en)
}
