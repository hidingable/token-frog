import CoreGraphics
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let petFixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func frozenPetData(_ name: String) throws -> [String: [String: String]] {
    try JSONDecoder().decode([String: [String: String]].self,
                             from: Data(contentsOf: petFixtureRoot.appendingPathComponent("Tests/TokenVoyageTests/Fixtures/\(name).json")))
}

private func imageRecord(_ image: CGImage) throws -> [String: String] {
    let bytes = try #require(image.dataProvider?.data) as Data
    return ["width": String(image.width), "height": String(image.height), "rgba": bytes.base64EncodedString()]
}

@MainActor @Test func petEggAndItemPixelsExactlyMatchThePreRefactorRenderer() throws {
    var actual: [String: [String: String]] = [:]
    let catalog = localizationCatalog.pets
    for definition in catalog.all {
        let pet = definition.id
        for frame in Sprites.Frame.allCases {
            actual["pet/\(pet.rawValue)/\(frame)"] = try imageRecord(Sprites.image(pet, frame, catalog: catalog))
        }
        for cracked in [false, true] {
            actual["egg/\(pet.rawValue)/\(cracked)"] = try imageRecord(Sprites.egg(pet, cracked: cracked, catalog: catalog))
        }
    }
    for icon in catalog.icons.keys { actual["item/\(icon)"] = try imageRecord(Sprites.item(icon, catalog: catalog)) }
    #expect(try actual == frozenPetData("pet-pixels-before"))
}

@Test func namesEggNamesQuirksAndLegacyLettersExactlyMatchThePreRefactorText() throws {
    var actual: [String: [String: String]] = [:]
    for pet in localizationCatalog.pets.all {
        for language in Language.allCases {
            let l10n = L10n(language: language)
            var entry = ["name": l10n.defaultPetName(pet.id, catalog: localizationCatalog.pets),
                         "eggName": l10n.eggName(pet.id, catalog: localizationCatalog.pets)]
            for (index, quirk) in pet.quirks.enumerated() { entry["quirk/\(index)"] = LetterComposer.localized(quirk, l10n: l10n) }
            var letter = JourneyState(seed: 7, startCityId: "shanghai", pet: pet.id, date: "2026-11-01", catalog: localizationCatalog).letters[0]
            letter.kind = .daily
            letter.texts = nil
            for index in 0..<3 {
                letter.id = index + 3
                for mode in ["arrival", "transit", "deep", "trip"] {
                    letter.transitTargetId = mode == "transit" ? "tokyo" : nil
                    letter.isDeepVisit = mode == "deep"
                    letter.arrivals = mode == "trip" ? ["beijing", "shanghai"] : ["shanghai"]
                    let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Ginkgo", catalog: localizationCatalog)
                    entry["letter/\(index)/\(mode)"] = ([text.title, text.voice, text.signature] + text.itinerary).joined(separator: "\n")
                }
            }
            actual["\(pet.id.rawValue)/\(language.rawValue)"] = entry
        }
    }
    #expect(try actual == frozenPetData("pet-text-before"))
}

private final class PetTestDefaults: UserDefaults, @unchecked Sendable {
    override func string(forKey key: String) -> String? { key == "language" ? "en" : nil }
    override func object(forKey key: String) -> Any? { string(forKey: key) }
    override func set(_ value: Any?, forKey key: String) {}
}

private struct PetAppSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-pets-\(UUID().uuidString)")
    var content: URL { root.appendingPathComponent("Content") }
    var data: URL { root.appendingPathComponent("data") }
    var today: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))! }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: petFixtureRoot.appendingPathComponent("Content"), to: content)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func addPet(_ id: String, order: Int) throws {
        var pet = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: content.appendingPathComponent("pets/pigeon.json"))) as? [String: Any])
        pet["id"] = id
        pet["order"] = order
        pet["names"] = ["zh-Hans": "小鹤", "en": "Crane"]
        pet["eggNames"] = ["zh-Hans": "鹤蛋", "en": "Crane egg"]
        pet["quirks"] = (0..<4).map { ["zh-Hans": "鹤的短句\($0)。", "en": "Crane quirk \($0)."] }
        try JSONSerialization.data(withJSONObject: pet).write(to: content.appendingPathComponent("pets/\(id).json"))
    }
    @MainActor func model() -> AppModel {
        AppModel(defaults: PetTestDefaults(), directory: data, contentDirectory: content, now: { today }, onboardingSeed: 42,
                 onboardingReader: { _, _ in ([], []) }, quotaReader: { [] },
                 usageReader: { _, until in [DayDetail(date: until, rows: [UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: 123_456))])] },
                 hoursReader: { _, _ in [] }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    }
}

@MainActor @Test(arguments: [5, 6]) func addingOnlyPetFilesSupportsOnboardingEveryFrameSavingAndReloading(count: Int) throws {
    let sandbox = try PetAppSandbox()
    defer { sandbox.remove() }
    // The five-pet case adds exactly one file. A second temporary file exercises the sixth egg.
    try sandbox.addPet("crane", order: 0)
    if count == 6 { try sandbox.addPet("ibis", order: 5) }
    #expect(ContentValidator.validate(directory: sandbox.content).isEmpty)
    let model = sandbox.model()
    #expect(!model.isLocked && model.recoveryIssues.isEmpty)
    let flow = try #require(model.onboarding)
    #expect(flow.eggs.count == count)
    #expect(flow.eggs.map(\.order) == flow.eggs.map(\.order).sorted())
    let pet = PetID(rawValue: "crane")
    #expect(flow.eggs.contains { $0.id == pet })
    #expect(flow.catalog.pets.defaultID == pet && flow.preview.pet == pet)
    for definition in flow.eggs {
        for frame in Sprites.Frame.allCases {
            let image = Sprites.image(definition.id, frame, catalog: flow.catalog.pets)
            #expect(image.width == 16 && image.height == 17)
            let pixels = try #require(image.dataProvider?.data) as Data
            #expect(pixels.contains { $0 != 0 })
        }
        for cracked in [false, true] {
            let egg = Sprites.egg(definition.id, cracked: cracked, catalog: flow.catalog.pets)
            #expect(egg.width == 16 && egg.height == 16)
        }
    }
    let l10n = L10n(language: .en)
    flow.selectEgg(pet)
    flow.advance(l10n: l10n)
    flow.advance(l10n: l10n)
    #expect(flow.petName == "Crane")
    #expect(l10n.eggName(pet, catalog: flow.catalog.pets) == "Crane egg")
    flow.skipHatching()
    flow.advance(l10n: l10n)
    flow.advance(l10n: l10n)
    #expect(flow.step == .depart)
    model.completeOnboarding()
    #expect(model.onboarding == nil && model.state?.pet == pet && model.care?.species == pet)
    #expect(model.petName == "Crane")
    for (file, key) in [("journey.json", "pet"), ("care.json", "species")] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.data.appendingPathComponent(file))) as? [String: Any])
        #expect(json[key] as? String == "crane")
    }
    let reloaded = sandbox.model()
    #expect(!reloaded.isLocked && reloaded.recoveryIssues.isEmpty)
    #expect(reloaded.state?.pet == pet && reloaded.care?.species == pet && reloaded.petName == "Crane")
    var letter = try #require(reloaded.state?.letters.first)
    letter.kind = .daily
    letter.texts = nil
    for index in 0..<8 {
        letter.id = index
        for language in Language.allCases {
            let text = LetterComposer.text(for: letter, l10n: L10n(language: language), petName: reloaded.petName, catalog: flow.catalog)
            #expect(text.voice.contains(language == .en ? "Crane quirk \(index % 4)." : "鹤的短句\(index % 4)。"))
        }
    }
}

@MainActor @Test func unknownPetSavesUseTheSavedNameAndPlaceholderAndStillScan() async throws {
    let sandbox = try PetAppSandbox()
    defer { sandbox.remove() }
    let catalog = try CityCatalog.load(directory: sandbox.content)
    let pet = PetID(rawValue: "dragon")
    let store = SaveStore(directory: sandbox.data, pets: catalog.pets, journeyMigrations: .journey(catalog: catalog))
    store.load()
    var state = JourneyState(seed: 7, startCityId: "shanghai", pet: pet, date: DayKey.string(from: sandbox.today), now: sandbox.today, catalog: catalog)
    state.letters[0].kind = .daily
    state.letters[0].texts = nil
    try store.save(state)
    try store.save(CareState(petName: "Saved Dragon", species: pet, hatchedAt: state.startDate))
    let model = sandbox.model()
    model.start()
    #expect(!model.isLocked && model.recoveryIssues.isEmpty && model.onboarding == nil)
    #expect(model.state?.pet == pet && model.care?.species == pet && model.petName == "Saved Dragon")
    #expect(catalog.pets.find(pet) == nil)
    #expect(Sprites.petPixels(pet, catalog: catalog.pets) == catalog.pets.eggs.placeholder.rows.flatMap { $0.map { catalog.pets.palette[$0] } })
    for frame in Sprites.Frame.allCases {
        let image = Sprites.image(pet, frame, catalog: catalog.pets)
        #expect(image.width == 16 && image.height == 17)
    }
    let text = LetterComposer.text(for: state.letters[0], l10n: L10n(language: .en), petName: model.petName, catalog: catalog)
    #expect(text.signature.contains("Saved Dragon"))
    await model.scan()
    #expect(model.lastScan == sandbox.today && model.lastError == nil)
    #expect(model.state?.totalFuel == 123_456)
    #expect(sandbox.model().petName == "Saved Dragon")
    #expect(!FileManager.default.fileExists(atPath: sandbox.data.appendingPathComponent("backups").path))
}

@MainActor @Test func damagedPetContentUsesContentRecoveryWithoutTouchingSaves() throws {
    let sandbox = try PetAppSandbox()
    defer { sandbox.remove() }
    let invalidSave = Data("a save that must not even be read".utf8)
    try FileManager.default.createDirectory(at: sandbox.data, withIntermediateDirectories: true)
    let save = sandbox.data.appendingPathComponent("journey.json")
    try invalidSave.write(to: save)
    try Data("{".utf8).write(to: sandbox.content.appendingPathComponent("pets/pigeon.json"))
    let model = sandbox.model()
    let issue = try #require(model.recoveryIssues.first)
    guard case .content = issue.problem else { Issue.record("Expected content-file recovery"); return }
    #expect(model.isLocked && model.state == nil && model.onboarding == nil)
    #expect(try Data(contentsOf: save) == invalidSave)
    #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.data.path) == ["journey.json"])
}
