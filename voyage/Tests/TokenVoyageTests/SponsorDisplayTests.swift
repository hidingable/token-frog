import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private let displaySponsor = Sponsor(id: "riverside-shop", label: ["zh-Hans": "河畔小店", "en": "Riverside Shop"])

@Test(arguments: [Language.zhHans, .en])
func deliveredSponsorLabelsAndItemTextUseSnapshotsAfterRemoteContentDisappears(language: Language) throws {
    let l10n = L10n(language: language)
    let expectedTag = language == .zhHans ? "合作 · 河畔小店" : "Partner · Riverside Shop"
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    var letter = journey.letters[0]
    letter.kind = .daily
    letter.storyId = "hub.shanghai.partner-story"
    letter.sponsor = displaySponsor
    letter.texts = ["zh-Hans": "在河边收到了一只杯子。", "en": "I received a cup by the river."]
    var item = try #require(localizationCatalog.items.all.first { $0.kind == "souvenir" && $0.rarity == "common" })
    item.id = "hub.shanghai.partner-cup"
    item.names = ["zh-Hans": "河畔杯", "en": "Riverside cup"]
    item.sponsor = displaySponsor
    letter.rewardItems = [item]
    letter.rewards.itemIds = [item.id]
    letter.rewards.dropRarity = "common"
    journey.letters = [letter]
    let saved = CareState.Souvenir(id: item.id, letterId: letter.id, shelved: true, sponsor: displaySponsor)

    // The current catalog no longer has either remote entry.
    #expect(localizationCatalog.items.find(item.id) == nil)
    #expect(!localizationCatalog.stories.all.contains { $0.id == letter.storyId })
    #expect(LetterComposer.sponsorTags(for: letter, l10n: l10n) == [expectedTag])
    let brought = try #require(LetterComposer.brought(for: letter, care: nil, catalog: localizationCatalog, l10n: l10n))
    #expect(brought.items.first?.sponsorTag == expectedTag)
    #expect(brought.items.first?.name == item.names[language.rawValue])
    let collectionItem = try #require(ItemCollection.souvenirItem(saved, letters: journey.letters, library: localizationCatalog.items))
    #expect(ItemDisplay(collectionItem, l10n: l10n).sponsorTag == expectedTag)
    #expect(collectionItem.names == item.names && collectionItem.descriptions == item.descriptions)

    // Saved attribution takes precedence over a later edit to another snapshot.
    letter.rewardItems[0].sponsor = Sponsor(id: "later-owner", label: ["zh-Hans": "后来的名称", "en": "Later name"])
    let unchanged = try #require(ItemCollection.souvenirItem(saved, letters: [letter], library: localizationCatalog.items))
    #expect(L10n(language: language).sponsorTag(unchanged.sponsor) == expectedTag)
}

@Test(arguments: [Language.zhHans, .en])
func letterAndMemoryDisplayRetainEarlierArrivalSponsorSnapshots(language: Language) throws {
    let l10n = L10n(language: language)
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    var letter = journey.letters[0]
    letter.kind = .daily
    letter.storyId = "ordinary-final-story"
    letter.sponsor = nil
    letter.deliverAt = .distantPast
    letter.arrivalStories = [.init(cityId: "hangzhou", storyId: "remote-partner-story", storyVersion: 1,
                                  isRevisit: false, texts: ["zh-Hans": "在河畔见面。", "en": "We met by the river."],
                                  sponsor: displaySponsor)]
    letter.replyOptions = [.init(id: "reply.sponsor-display", habit: "observant", text: ["zh-Hans": "记下杯子的样子", "en": "Remember the cup"])]
    journey.letters = [letter]
    var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
    care.memories = [.init(kind: "reply", date: letter.date, letterId: letter.id, replyId: "reply.sponsor-display")]
    let expected = [try #require(l10n.sponsorTag(displaySponsor))]
    #expect(LetterComposer.sponsorTags(for: letter, l10n: l10n) == expected)
    let memory = MemoryBookDisplay(journey: journey, care: care, now: .distantFuture, l10n: l10n, catalog: localizationCatalog)
    #expect(memory.entries.first?.sponsorTags == expected)
    letter.sponsor = displaySponsor
    #expect(LetterComposer.sponsorTags(for: letter, l10n: l10n) == expected)
}

@Test(arguments: [Language.zhHans, .en])
func ordinaryFulfillmentRetainsSourcePartnerLabelsThroughArchiveRoundTrip(language: Language) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-partner-reference-\(UUID())")
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-partner-reference-import-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: destination) }
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    var source = journey.letters[0]
    source.kind = .daily
    source.sponsor = displaySponsor
    source.replyOptions = [.init(id: "hub.reply.partner-cup", habit: "observant",
                                 text: ["zh-Hans": "看看河畔小店的杯子", "en": "Look at the Riverside Shop cup"])]
    source.selectedReplyId = source.replyOptions[0].id
    source.deliverAt = .distantPast
    var followUp = source
    followUp.id = source.id + 1
    followUp.sponsor = nil
    followUp.replyOptions = []
    followUp.selectedReplyId = nil
    followUp.fulfilledReplyId = source.selectedReplyId
    followUp.leadTexts = ["zh-Hans": "你说过：看看河畔小店的杯子。", "en": "You said: Look at the Riverside Shop cup."]
    journey.letters = [source, followUp]
    var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
    care.memories = [.init(kind: "reply", date: source.date, letterId: source.id, replyId: source.selectedReplyId),
                     .init(kind: "fulfilled", date: followUp.date, letterId: followUp.id, replyId: source.selectedReplyId)]
    let store = SaveStore(directory: directory, pets: localizationCatalog.pets,
                          journeyMigrations: .journey(catalog: localizationCatalog))
    store.load()
    try store.save(journey)
    try store.save(care)
    let exported = try store.exportArchive(appVersion: "1.0")
    let imported = SaveStore(directory: destination, pets: localizationCatalog.pets,
                             journeyMigrations: .journey(catalog: localizationCatalog))
    imported.load()
    let candidate = try imported.validateArchive(exported)
    try imported.importArchive(candidate)
    guard case .loaded(let restored) = imported.journey else { Issue.record("Archive did not import"); return }
    #expect(restored.letters == journey.letters)
    let l10n = L10n(language: language)
    let restoredFollowUp = try #require(restored.letters.first { $0.id == followUp.id })
    #expect(!restoredFollowUp.hasSponsoredContent)
    let expected = [try #require(l10n.sponsorTag(displaySponsor))]
    #expect(LetterComposer.sponsorTags(for: restoredFollowUp, l10n: l10n, letters: restored.letters) == expected)
    let memory = MemoryBookDisplay(journey: restored, care: candidate.care, now: .distantFuture, l10n: l10n, catalog: localizationCatalog)
    #expect(memory.entries.first { $0.category == .learned }?.sponsorTags == expected)
}

private final class SponsorSurfaceDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

private func sponsorLearnedJourney(sponsor: Sponsor) -> JourneyState {
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    var source = journey.letters[0]
    source.id = 1
    source.kind = .daily
    source.storyId = "hub.shanghai.removed-partner-story"
    source.sponsor = sponsor
    source.replyOptions = [.init(id: "hub.shanghai.partner-reply", habit: "observant", text: sponsor.label)]
    source.selectedReplyId = source.replyOptions[0].id
    var followUp = source
    followUp.id = 2
    followUp.storyId = "ordinary-fulfillment"
    followUp.sponsor = nil
    followUp.replyOptions = []
    followUp.selectedReplyId = nil
    followUp.fulfilledReplyId = source.selectedReplyId
    followUp.learnedTexts = ["zh-Hans": "记住河边的一只杯子。", "en": "Remember a cup by the river."]
    journey.letters = [source, followUp]
    return journey
}

@Test(arguments: [Language.zhHans, .en])
@MainActor func profileAndFloatingLearnedTextLabelTheRemovedSourceSnapshot(language: Language) {
    let journey = sponsorLearnedJourney(sponsor: displaySponsor)
    let care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
    let l10n = L10n(language: language)
    let expected = [l10n.sponsorTag(displaySponsor)!]
    #expect(!localizationCatalog.stories.all.contains { $0.id == journey.letters[0].storyId })
    #expect(!journey.letters[1].hasSponsoredContent)
    let profile = ProfileDisplay(journey: journey, care: care, l10n: l10n)
    #expect(profile.learned.first?.id == 2)
    #expect(profile.learned.first?.sponsorTags == expected)
    let model = AppModel(isSnapshot: true, languageOverride: language, defaults: SponsorSurfaceDefaults(),
                         catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
    model.withSnapshotState({ $0 = journey }) {
        #expect(model.floatingWords == journey.letters[1].learnedTexts[language.rawValue])
        #expect(model.floatingSponsorTags == expected)
    }
    model.withSnapshotState({ $0.letters = [] }) {
        #expect(model.floatingSponsorTags.isEmpty)
        #expect(L10n.floatingKeys.map { l10n($0) }.contains(model.floatingWords))
    }
}

@Test(arguments: [Language.zhHans, .en])
@MainActor func floatingPartnerLabelsRenderWrappedWithoutClippingAndKeepOrdinarySizes(language: Language) throws {
    let sponsor = Sponsor(id: "long-riverside-partner", label: ["zh-Hans": String(repeating: "旅", count: 24), "en": "Riverside Travel Partner"])
    let journey = sponsorLearnedJourney(sponsor: sponsor)
    #expect(!localizationCatalog.stories.all.contains { $0.id == journey.letters[0].storyId })
    let model = AppModel(isSnapshot: true, languageOverride: language, appearanceOverride: .light,
                         defaults: SponsorSurfaceDefaults(), catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
    var renderedSize: CGSize?
    var raster: Data?
    var measured = CGSize.zero
    var textStart = 0
    model.withSnapshotState({ $0 = journey }) {
        model.reactToFloatingClick()
        defer { model.endFloatingReaction() }
        let ordinary = FloatingLayout.reactionSize(text: model.floatingWords, form: model.petForm)
        measured = FloatingLayout.reactionSize(text: model.floatingWords, sponsorTags: model.floatingSponsorTags, form: model.petForm)
        #expect(measured.width >= ordinary.width && measured.height > ordinary.height)
        #expect(measured.height <= FloatingLayout.maximumReactionSize.height)
        if language == .zhHans { #expect(measured.height > 64) }
        #expect(FloatingLayout.reactionSize(text: "Hi!") == CGSize(width: 150, height: 48))
        #expect(FloatingLayout.reactionSize(text: String(repeating: "A lesson from the road. ", count: 20)).height <= 64)
        let renderer = ImageRenderer(content: FloatingView(model: model).localized(using: model))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: measured.width, height: measured.height)
        let image = renderer.nsImage
        renderedSize = image?.size
        // Materialize pixels before the model's snapshot/reaction state is restored.
        raster = image?.tiffRepresentation
        textStart = (model.petForm == .hatchling ? 50 : 58) + 6
    }
    #expect(renderedSize == measured)
    let tiff = try #require(raster)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(!png.isEmpty)
    let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 4)?.usingColorSpace(.deviceRGB))
    func inkRows(_ rows: Range<Int>) -> Int {
        rows.filter { y in
            var ink = 0
            for x in textStart..<(bitmap.pixelsWide - 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let contrast = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent) + abs(color.blueComponent - background.blueComponent)
                if contrast > 0.25 { ink += 1 }
            }
            return ink >= 8
        }.count
    }
    // Exclude the pet and outer border. Both the label and learned text must paint glyph rows;
    // a nonempty PNG containing only an unsupported-view placeholder must fail.
    #expect(inkRows(8..<Int(Double(bitmap.pixelsHigh) * 0.45)) >= 5, "Partner label must render above the learned text")
    #expect(inkRows(Int(Double(bitmap.pixelsHigh) * 0.55)..<(bitmap.pixelsHigh - 8)) >= 5, "Learned text must render below the partner label")
    if let outputPath = ProcessInfo.processInfo.environment["VOYAGE_TEST_RENDER_DIR"] {
        let directory = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("floating-sponsor-\(language.rawValue).png"))
    }
}
