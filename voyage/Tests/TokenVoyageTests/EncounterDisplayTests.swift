import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private final class EncounterDisplayDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) { writes.append(name) }
}

@Suite @MainActor struct EncounterDisplayTests {
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))! }

    @Test func consentCopyPreservesTheMockupAndExplainsDataSyncInBothLanguages() {
        let zh = L10n(language: .zhHans), en = L10n(language: .en)
        #expect(zh("settings.encounters") == "同城偶遇和数据同步")
        #expect(zh("encounter.consentTitle") == "开启同城偶遇")
        #expect(zh("encounter.consentBody") == "开启后，它到站时会向 Voyage Hub 登记“在哪座城、停到几点”。存档绑定这台设备，不需要账号。")
        #expect(zh("encounter.registeredValue") == "城市和停留时间")
        #expect(zh("encounter.notSentValue") == "名字、用量、信件")
        #expect(zh("encounter.canDelete") == "随时可以关闭并删除服务端的记录。")
        #expect(en("encounter.consentBody").contains("No account is needed"))
        #expect(en("encounter.syncedValue").contains("owned items"))
        #expect(zh("encounter.syncedValue").contains("城市 ID"))
        for key in ["settings.encounters", "settings.encountersHint", "encounter.consentTitle", "encounter.consentBody",
                    "encounter.registeredLabel", "encounter.registeredValue", "encounter.notSentLabel", "encounter.notSentValue",
                    "encounter.syncedLabel", "encounter.syncedValue", "encounter.canDelete", "encounter.cancel", "encounter.confirm",
                    "encounter.optOutTitle", "encounter.optOutBody", "encounter.disableKeep", "encounter.disableDelete",
                    "encounter.postcardTitle", "encounter.postcardCityTitle", "encounter.photoAccessibility"] {
            #expect(zh(key) != key && en(key) != key)
            #expect(!containsHan(en(key)))
        }
    }

    @Test(arguments: [Language.zhHans, .en])
    func encounterMailHasItsOwnTitleAndNeverChangesOrdinaryLetterNumbers(language: Language) throws {
        let l10n = L10n(language: language)
        let example = Snapshots.companionMailExamples(catalog: localizationCatalog, now: now, petName: "Pip")
        var encounter = Snapshots.encounterExample(catalog: localizationCatalog, now: now)
        // Imported encounter IDs need not remain above ordinary IDs to preserve numbering.
        encounter.id = 1
        let ordinary = try #require(example.journey.letters.last { $0.kind == .daily })
        let before = LetterComposer.number(for: ordinary, letters: example.journey.letters)
        let withEncounter = example.journey.letters + [encounter]
        #expect(LetterComposer.number(for: ordinary, letters: withEncounter) == before)
        #expect(LetterComposer.number(for: encounter, letters: withEncounter) == nil)
        let text = LetterComposer.text(for: encounter, l10n: l10n, petName: "Pip", catalog: localizationCatalog, letters: withEncounter)
        #expect(text.title == l10n("encounter.postcardCityTitle", l10n.cityName(localizationCatalog.city("quanzhou"))))
        #expect(text.voice == encounter.texts?[language.rawValue] && text.itinerary.isEmpty)
        #expect(LetterComposer.origin(for: encounter, letters: withEncounter, l10n: l10n, catalog: localizationCatalog)
                == l10n("collection.companionOrigin", l10n("encounter.postcardTitle")))
        #expect(LetterComposer.citation(for: encounter, letters: withEncounter, l10n: l10n)
                == l10n("memory.citedCompanion", l10n("encounter.postcardTitle")))
        #expect(MailFilter.postcards.includes(encounter) && !MailFilter.travel.includes(encounter))
    }

    @Test func artUsesActualFormSpritesAndUnknownSpeciesHaveTheSameNeutralSilhouette() throws {
        let theme = AppTheme(testThemes.standard(.dark))
        let letter = Snapshots.encounterExample(catalog: localizationCatalog, now: now)
        var encounter = try #require(letter.encounter)
        let known = EncounterPostcardArt.image(encounter, catalog: localizationCatalog, theme: theme)
        #expect(known.width == 96 && known.height == 48 && !known.shouldInterpolate)
        let bytes = known.dataProvider!.data! as Data
        for (appearance, center) in [(encounter.own, 31), (encounter.partner, 65)] {
            let sprite = Sprites.image(PetID(rawValue: appearance.species), .rest, catalog: localizationCatalog.pets,
                                       form: PetForm(rawValue: appearance.stage)!)
            let source = sprite.dataProvider!.data! as Data
            for index in 0..<(sprite.width * sprite.height) where source[index * 4 + 3] > 0 {
                let target = ((39 - sprite.height + index / sprite.width) * 96 + center - sprite.width / 2 + index % sprite.width) * 4
                #expect(bytes[target..<(target + 4)] == source[(index * 4)..<(index * 4 + 4)])
            }
        }
        encounter.partner.species = "new-species-one"
        let unknown = EncounterPostcardArt.image(encounter, catalog: localizationCatalog, theme: theme)
        encounter.partner.species = "new-species-two"
        encounter.partner.stage = "future-form"
        #expect(unknown.dataProvider!.data! as Data == EncounterPostcardArt.image(encounter, catalog: localizationCatalog, theme: theme).dataProvider!.data! as Data)
        #expect(unknown.dataProvider!.data! as Data != bytes)
        #expect(bytes != EncounterPostcardArt.image(try #require(letter.encounter), catalog: localizationCatalog,
                                                   theme: AppTheme(testThemes.standard(.light))).dataProvider!.data! as Data)
        encounter = try #require(letter.encounter)
        encounter.cityId = "london"
        #expect(bytes != EncounterPostcardArt.image(encounter, catalog: localizationCatalog, theme: theme).dataProvider!.data! as Data)
    }

    @Test func settingsConsentAndBothPostcardVariantsRenderOffscreenForEveryLanguageAndTheme() throws {
        #expect(Snapshots.encounterCases.count == 4)
        var outputs = Set<String>()
        for example in Snapshots.encounterCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-encounter-render-\(UUID())")
            let defaults = EncounterDisplayDefaults()
            let model = AppModel(isSnapshot: true, languageOverride: example.language, appearanceOverride: example.scheme,
                                 defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                                 now: { self.now }, runtimeEnabled: false)
            try model.withSnapshotEncountersAvailable {
                #expect(model.encountersAvailable && !model.encountersEnabled)
                model.requestEncountersEnabled(true)
                #expect(model.showingEncounterConsent && !model.encountersEnabled)
                model.showingEncounterConsent = false
                var settingsResult: Result<Void, Error> = .success(())
                model.withSnapshotState({ state in
                    state.startDate = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -1, to: self.now)!)
                    state.openDate = DayKey.string(from: self.now)
                }) {
                    settingsResult = Result {
                        try render(SettingsTab(model: model).padding(12).frame(width: 760)
                            .fixedSize(horizontal: false, vertical: true).background(model.theme.background)
                            .localized(using: model), width: 760, name: "settings-encounters-\(example.suffix)", outputs: &outputs)
                    }
                }
                try settingsResult.get()
            }
            #expect(!model.encountersAvailable)
            try render(EncounterConsentView(onConfirm: {}, onCancel: {}).localized(using: model), width: 480,
                       name: "encounter-consent-\(example.suffix)", outputs: &outputs)
            for unknown in [false, true] {
                let letter = Snapshots.encounterExample(catalog: localizationCatalog, now: now, unknownPartner: unknown)
                try render(LetterView(letter: letter, petName: "Pip", catalog: localizationCatalog)
                    .padding(16).frame(width: 580).background(model.theme.background).localized(using: model), width: 580,
                    name: "encounter-postcard-\(unknown ? "unknown" : "known")-\(example.suffix)", outputs: &outputs)
            }
            #expect(defaults.writes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
        #expect(outputs.count == 16)
    }

    private func render<Content: View>(_ view: Content, width: CGFloat, name: String, outputs: inout Set<String>) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == width && image.size.height > 200)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        #expect(outputs.insert(name).inserted)
        if let path = ProcessInfo.processInfo.environment["VOYAGE_TEST_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
