import AppKit
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class AppearanceDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private(set) var writes: [String] = []
    override func object(forKey name: String) -> Any? { values[name] }
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func set(_ value: Any?, forKey name: String) { values[name] = value; writes.append(name) }
}

@MainActor
private func appearanceModel(_ directory: URL, defaults: UserDefaults, snapshot: Bool = false, override: ThemeScheme? = nil) -> AppModel {
    AppModel(isSnapshot: snapshot, appearanceOverride: override, systemScheme: .light, defaults: defaults,
             directory: directory, catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
}

@MainActor
@Test func appearanceDefaultsToSystemAndChangesWithSystemAppearance() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-appearance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = AppearanceDefaults()
    let model = appearanceModel(directory, defaults: defaults)
    #expect(model.appearancePreference == .system)
    #expect(model.theme.id == "day")
    var notifications = 0
    model.onAppearanceChange = { notifications += 1 }
    model.systemAppearanceChanged(to: .dark)
    #expect(model.theme.id == "night")
    model.systemAppearanceChanged(to: .light)
    #expect(model.theme.id == "day")
    #expect(notifications == 2)
    #expect(defaults.writes.isEmpty)
}

@MainActor
@Test func explicitAppearancePersistsToInjectedDefaultsAndIgnoresTheSystem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-appearance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = AppearanceDefaults()
    let model = appearanceModel(directory, defaults: defaults, override: .light)
    for (preference, id) in [(AppearancePreference.dark, "night"), (.light, "day")] {
        model.appearancePreference = preference
        #expect(defaults.string(forKey: "appearance") == preference.rawValue)
        for system in [ThemeScheme.dark, .light] {
            model.systemAppearanceChanged(to: system)
            #expect(model.theme.id == id)
        }
    }
    #expect(appearanceModel(directory, defaults: defaults).appearancePreference == .light)
    model.appearancePreference = .system
    #expect(defaults.string(forKey: "appearance") == "system")
    #expect(defaults.writes == ["appearance", "appearance", "appearance"])
}

@MainActor
@Test func snapshotAppearanceOverridesOnlyThisRunAndNeverWritesSettingsOrSaves() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-appearance-snapshot-\(UUID().uuidString)")
    let defaults = AppearanceDefaults()
    defaults.set("dark", forKey: "appearance")
    let writes = defaults.writes
    for override in [ThemeScheme.dark, .light] {
        let model = appearanceModel(directory, defaults: defaults, snapshot: true, override: override)
        #expect(!model.isLocked && model.state != nil)
        for preference in AppearancePreference.standard {
            model.appearancePreference = preference
            model.systemAppearanceChanged(to: .dark)
            #expect(model.theme.scheme == override)
        }
        #expect(defaults.string(forKey: "appearance") == "dark")
    }
    #expect(defaults.writes == writes)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func appearanceArgumentIsSnapshotOnlyAndRejectsInvalidValues() throws {
    #expect(try SnapshotAppearance.parse(arguments: ["app", "--appearance", "light"]) == nil)
    #expect(try SnapshotAppearance.parse(arguments: ["app", "--snapshot", "out"]) == nil)
    for scheme in [ThemeScheme.dark, .light] {
        #expect(try SnapshotAppearance.parse(arguments: ["app", "--snapshot", "out", "--appearance", scheme.rawValue]) == scheme)
    }
    for value in ["", "system", "night", "--language"] {
        #expect(throws: SnapshotAppearance.ParseError.self) {
            try SnapshotAppearance.parse(arguments: ["app", "--snapshot", "out", "--appearance", value])
        }
    }
    #expect(throws: SnapshotAppearance.ParseError.self) {
        try SnapshotAppearance.parse(arguments: ["app", "--snapshot", "out", "--appearance"])
    }
    #expect(ThemeScheme(appearance: NSAppearance(named: .darkAqua)) == .dark)
    #expect(ThemeScheme(appearance: NSAppearance(named: .aqua)) == .light)
}

@MainActor
@Test(arguments: ["missing", "brokenJSON", "missingToken"])
func damagedThemesUseContentRecoveryBeforeReadingAnySave(_ failure: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-theme-recovery-\(UUID().uuidString)")
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let save = data.appendingPathComponent("journey.json")
    let untouched = Data("leave the existing save alone".utf8)
    try untouched.write(to: save)
    let content = root.appendingPathComponent("Content")
    let themes = content.appendingPathComponent("themes")
    if failure != "missing" {
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content/themes"), to: themes)
        let file = themes.appendingPathComponent("night.json")
        if failure == "brokenJSON" { try Data("broken".utf8).write(to: file) }
        else {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var colors = try #require(json["colors"] as? [String: Any])
            colors.removeValue(forKey: "background")
            json["colors"] = colors
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }
    }
    let defaults = AppearanceDefaults()
    let model = AppModel(defaults: defaults, directory: data, catalog: localizationCatalog, contentDirectory: content, runtimeEnabled: false)
    #expect(model.isLocked && model.state == nil && model.care == nil && model.onboarding == nil)
    #expect(model.themes == nil && model.theme.definition == nil)
    let issue = try #require(model.recoveryIssues.first)
    guard case .content = issue.problem else { Issue.record("Expected damaged-content recovery"); return }
    model.start()
    await model.scan()
    await model.loadDashboard()
    await model.loadQuotas(force: true)
    model.retrySaves()
    model.restartSave(.journey)
    #expect(try Data(contentsOf: save) == untouched)
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == ["journey.json"])
    #expect(defaults.writes.isEmpty)
}

@Test func appSourcesKeepColorLiteralsInsideTheThemeAndSpriteAllowlist() throws {
    // Theme.swift converts validated RGB data; Sprites.swift retains fixed character/item/egg art.
    let allowed = Set(["Theme.swift", "Sprites.swift"])
    let expression = try NSRegularExpression(pattern: #"Color\s*\(\s*hex\s*:|0x[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{6}\b|Color\.(?:black|white|gray|red|blue)\b"#)
    let files = try #require(FileManager.default.enumerator(at: LocalizationTestFiles.appSources, includingPropertiesForKeys: nil))
    var count = 0
    var schemeFiles: [String] = []
    for case let file as URL in files where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        if source.contains(".preferredColorScheme(") { schemeFiles.append(file.lastPathComponent) }
        guard !allowed.contains(file.lastPathComponent) else { continue }
        #expect(expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) == nil, "\(file.lastPathComponent)")
        #expect(!source.contains("Palette."), "\(file.lastPathComponent)")
        count += 1
    }
    #expect(count > 0)
    #expect(schemeFiles == ["L10n.swift"])
}

@MainActor
@Test func anAddedThemeCanBeSelectedAndReloadedWithoutARegistryChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-custom-appearance-\(UUID().uuidString)")
    let content = root.appendingPathComponent("Content")
    let themes = content.appendingPathComponent("themes")
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content/themes"), to: themes)
    defer { try? FileManager.default.removeItem(at: root) }
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: themes.appendingPathComponent("day.json"))) as? [String: Any])
    json["id"] = "custom-day"
    json["names"] = ["zh-Hans": "午后", "en": "Afternoon"]
    try JSONSerialization.data(withJSONObject: json).write(to: themes.appendingPathComponent("custom-day.json"))
    let defaults = AppearanceDefaults()
    let model = AppModel(systemScheme: .dark, defaults: defaults, directory: data, catalog: localizationCatalog, contentDirectory: content, runtimeEnabled: false)
    #expect(model.themes?.find("custom-day") != nil)
    model.appearancePreference = .theme("custom-day")
    #expect(model.theme.id == "custom-day" && model.theme.scheme == .light)
    model.systemAppearanceChanged(to: .light)
    model.systemAppearanceChanged(to: .dark)
    #expect(model.theme.id == "custom-day")
    #expect(defaults.string(forKey: "appearance") == "custom-day")
    let reloaded = AppModel(systemScheme: .dark, defaults: defaults, directory: data, catalog: localizationCatalog, contentDirectory: content, runtimeEnabled: false)
    #expect(reloaded.appearancePreference == .theme("custom-day"))
    #expect(reloaded.theme.id == "custom-day")
}

@MainActor
@Test func unknownSavedAppearanceFallsBackToSystemWithoutRewritingPreferences() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-unknown-appearance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = AppearanceDefaults()
    defaults.set("removed-theme", forKey: "appearance")
    let model = appearanceModel(directory, defaults: defaults)
    #expect(model.appearancePreference == .system && model.theme.id == "day")
    #expect(defaults.writes == ["appearance"])
}
