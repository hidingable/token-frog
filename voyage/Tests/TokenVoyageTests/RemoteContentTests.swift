import Foundation
import Testing
@testable import VoyageCore
@testable import TokenVoyage

private let remotePack = LocalizationTestFiles.root.appendingPathComponent("Content")
private let remoteStoryID = "hub.hangzhou.tests.story"
private let remoteItemID = "hub.hangzhou.tests.souvenir"

private func remoteTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("voyage-remote-content-\(UUID().uuidString)")
}

private func remoteJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func remoteStory(cityID: String = "hangzhou", id: String = remoteStoryID) throws -> [String: Any] {
    let original = try #require(localizationCatalog.stories.all.first { $0.cityId == cityID && $0.kind == "arrival" })
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["id"] = id
    object["requires"] = [:] as [String: String]
    object["fulfills"] = [String]()
    object.removeValue(forKey: "fulfillsHabit")
    object.removeValue(forKey: "learned")
    object["rewards"] = ["itemIds": [String](), "menuIds": [String]()]
    object["replies"] = [
        ["id": id + ".talkative", "habit": "talkative", "text": ["zh-Hans": "聊聊路上的风景", "en": "Talk about the view"]],
        ["id": id + ".observant", "habit": "observant", "text": ["zh-Hans": "再看看路边", "en": "Look a little closer"]],
    ]
    return object
}

private func remoteItem(cityID: String = "hangzhou", id: String = remoteItemID) throws -> [String: Any] {
    let original = try #require(localizationCatalog.items.all.first { $0.cityId == cityID && $0.kind == "souvenir" && $0.source == nil })
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["id"] = id
    object["rarity"] = "common"
    return object
}

@Test func remoteContentAcceptsNativeStoryAndSouvenirAndMergesTheirCrossReference() throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var story = try remoteStory()
    story["rewards"] = ["itemIds": [remoteItemID], "menuIds": [String]()]
    let accepted = validator.accepting([try remoteJSON(story), try remoteJSON(remoteItem())], cityID: "hangzhou", into: RemoteCityContent())
    #expect(accepted.ids == [remoteStoryID, remoteItemID])
    #expect(accepted.stories[remoteStoryID]?.rewards.itemIds == [remoteItemID])
    let merged = accepted.merging(into: localizationCatalog)
    #expect(merged.stories.all.first { $0.id == remoteStoryID } == accepted.stories[remoteStoryID])
    #expect(merged.items.find(remoteItemID) == accepted.items[remoteItemID])
}

@Test(arguments: ["wrongCity", "unknownCity", "unknownFact", "foreignFact", "unknownTag", "unknownSlot", "missingTranslation", "badID", "emptyID", "duplicateReply", "replyCollision", "bundledCollision", "sponsor", "nestedSponsor", "invalidVersion", "missingReply"])
func remoteContentDropsInvalidStoryWithoutDroppingValidNeighbors(_ failure: String) throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var story = try remoteStory(id: "hub.hangzhou.tests.invalid")
    switch failure {
    case "wrongCity": story["cityId"] = "suzhou"
    case "unknownCity": story["cityId"] = "no-such-city"
    case "unknownFact": story["factIds"] = ["unverified-fact"]
    case "foreignFact":
        story["factIds"] = [try #require(localizationCatalog.city("suzhou").facts.first?.id)]
    case "unknownTag": story["tags"] = ["not-a-bundled-tag"]
    case "unknownSlot": story["text"] = ["zh-Hans": "看见{secret}了。", "en": "A view of {secret}."]
    case "missingTranslation": story["text"] = ["zh-Hans": "只有一种语言。"]
    case "badID": story["id"] = "hub.hangzhou.invalid/id"
    case "emptyID": story["id"] = ""
    case "duplicateReply":
        var replies = try #require(story["replies"] as? [[String: Any]])
        replies[1]["id"] = replies[0]["id"]
        story["replies"] = replies
    case "replyCollision":
        var replies = try #require(story["replies"] as? [[String: Any]])
        replies[0]["id"] = try #require(localizationCatalog.stories.all.first { !$0.replies.isEmpty }?.replies.first?.id)
        story["replies"] = replies
    case "bundledCollision": story["id"] = try #require(localizationCatalog.stories.all.first?.id)
    case "sponsor": story["sponsor"] = NSNull()
    case "nestedSponsor": story["extra"] = ["nested": [["sponsor": false]]]
    case "invalidVersion": story["version"] = 0
    default: story["replies"] = [String]()
    }
    let accepted = validator.accepting([try remoteJSON(story), try remoteJSON(remoteItem())], cityID: "hangzhou", into: RemoteCityContent())
    #expect(accepted.stories.isEmpty, "Invalid story: \(failure)")
    #expect(accepted.ids == [remoteItemID])
}

@Test(arguments: ["wrongCity", "badIcon", "unknownRarity", "missingTranslation", "slot", "badID", "bundledCollision", "source", "sponsor", "nestedSponsor"])
func remoteContentDropsInvalidItems(_ failure: String) throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var item = try remoteItem()
    switch failure {
    case "wrongCity": item["cityId"] = "suzhou"
    case "badIcon": item["icon"] = "not-a-bundled-icon"
    case "unknownRarity": item["rarity"] = "legendary"
    case "missingTranslation": item["names"] = ["en": "Only English"]
    case "slot": item["descriptions"] = ["en": "A {pet} souvenir", "zh-Hans": "{pet}的纪念品"]
    case "badID": item["id"] = "hub.hangzhou.bad item"
    case "bundledCollision": item["id"] = try #require(localizationCatalog.items.all.first?.id)
    case "source": item["source"] = "box"
    case "sponsor": item["sponsor"] = true
    default: item["extra"] = ["nested": ["sponsor": "advertiser"]]
    }
    #expect(validator.accepting([try remoteJSON(item)], cityID: "hangzhou", into: RemoteCityContent()).ids.isEmpty)
}

@Test func remoteContentBundledEntriesAlwaysWinEvenWhenMergeReceivesConflictingValues() throws {
    let bundledStory = try #require(localizationCatalog.stories.all.first)
    let bundledItem = try #require(localizationCatalog.items.all.first)
    var replacementStory = bundledStory
    replacementStory.text = ["en": "Unexpected replacement", "zh-Hans": "不应替换"]
    var replacementItem = bundledItem
    replacementItem.names = ["en": "Unexpected replacement", "zh-Hans": "不应替换"]
    let merged = localizationCatalog.addingRemoteContent(stories: [replacementStory], items: [replacementItem])
    #expect(merged.stories.all.first { $0.id == bundledStory.id } == bundledStory)
    #expect(merged.items.find(bundledItem.id) == bundledItem)
}

@Test func remoteArchiveKeepsFirstAcceptedEntriesAcrossUpdatesAndRestart() async throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("remote-content.json")
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let archive = RemoteContentStore(url: url, validator: validator, content: RemoteCityContent())
    let original = try await archive.accept([remoteJSON(remoteStory()), remoteJSON(remoteItem())], cityID: "hangzhou")
    #expect(Set(original.ids) == [remoteStoryID, remoteItemID])
    var edited = try remoteItem()
    edited["names"] = ["en": "A later server edit", "zh-Hans": "服务器后来改的名字"]
    let laterID = "hub.hangzhou.tests.later-item"
    _ = try await archive.accept([remoteJSON(edited), remoteJSON(remoteItem(id: laterID))], cityID: "hangzhou")
    let loaded = RemoteContentStore.load(url: url, validator: validator)
    #expect(loaded.ids == [remoteStoryID, remoteItemID, laterID])
    #expect(loaded.items[remoteItemID] == original.content.items[remoteItemID])
    #expect(loaded.stories[remoteStoryID] == original.content.stories[remoteStoryID])
    let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(document["schemaVersion"] as? Int == 1)
    #expect((document["entries"] as? [String: Any])?.count == 3)
}

@Test func remoteArchiveReloadRevalidatesEntriesAndRejectsUnknownVersions() throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("remote-content.json")
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var invalid = try remoteStory()
    invalid["factIds"] = ["unknown-fact"]
    try remoteJSON(["schemaVersion": 1, "entries": [remoteStoryID: invalid, remoteItemID: try remoteItem()] ]).write(to: url)
    #expect(RemoteContentStore.load(url: url, validator: validator).ids == [remoteItemID])
    try remoteJSON(["schemaVersion": 2, "entries": [remoteItemID: try remoteItem()]]).write(to: url)
    #expect(RemoteContentStore.load(url: url, validator: validator).ids.isEmpty)
    try Data("broken JSON".utf8).write(to: url)
    #expect(RemoteContentStore.load(url: url, validator: validator).ids.isEmpty)
}

@Test func persistedServerSouvenirResolvesInCollectionsAndOnTheShelfAfterSaveReload() async throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("remote-content.json")
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let archive = RemoteContentStore(url: url, validator: validator, content: RemoteCityContent())
    let accepted = try await archive.accept([remoteJSON(remoteItem())], cityID: "hangzhou")
    let initialCatalog = accepted.content.merging(into: localizationCatalog)
    let now = Date(timeIntervalSince1970: 1_794_276_000)
    let journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", now: now, catalog: initialCatalog)
    var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
    care.souvenirs = [.init(id: remoteItemID, letterId: 1, shelved: true)]
    let store = SaveStore(directory: directory, pets: initialCatalog.pets, items: initialCatalog.items,
                          journeyMigrations: .journey(catalog: initialCatalog))
    store.load()
    try store.save(journey)
    try store.save(care)
    let restartedCatalog = RemoteContentStore.load(url: url, validator: validator).merging(into: localizationCatalog)
    let restarted = SaveStore(directory: directory, pets: restartedCatalog.pets, items: restartedCatalog.items,
                              journeyMigrations: .journey(catalog: restartedCatalog))
    restarted.load()
    guard case .loaded(let restored) = restarted.care else { Issue.record("Care save did not reload"); return }
    let collection = restored.souvenirs.compactMap { restartedCatalog.items.find($0.id) }
    #expect(collection == [try #require(accepted.content.items[remoteItemID])])
    #expect(RoomLayout.shelf(restored).map(\.id) == [remoteItemID])
    #expect(ItemDisplay(try #require(collection.first), l10n: L10n(language: .en)).name == collection.first?.names["en"])
}

@Test func frozenTripCandidatesKeepStoryAndDropDeterministicAcrossArchiveGrowthAndRestart() async throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("remote-content.json")
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let archive = RemoteContentStore(url: url, validator: validator, content: RemoteCityContent())
    var firstStory = try remoteStory()
    firstStory["requires"] = ["tool": "codex"]
    firstStory["rewards"] = ["itemIds": [remoteItemID], "menuIds": [String]()]
    let first = try await archive.accept([remoteJSON(firstStory), remoteJSON(remoteItem())], cityID: "hangzhou")
    let firstCatalog = first.content.merging(into: localizationCatalog)
    let now = Date(timeIntervalSince1970: 1_794_276_000)
    var pending = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-10", now: now, catalog: firstCatalog)
    pending.remoteContentByTrip = [1: TripContentSnapshot(cityID: "hangzhou", entryIDs: first.ids)]
    pending.letters = [Letter(id: 1, kind: .daily, date: "2026-11-10", pet: pending.pet, cityId: "hangzhou",
                              arrivals: ["hangzhou"], tripNumber: 1, newCountries: [], fuel: 100,
                              compareToMedianPercent: nil, vehicles: [.init(client: "codex", percent: 100)],
                              isDeepVisit: false, deliverAt: now)]
    var initialCare = CareState(petName: "Pip", species: pending.pet, hatchedAt: pending.startDate)
    initialCare.bag.owned = []
    let save = SaveStore(directory: directory, pets: firstCatalog.pets, items: firstCatalog.items,
                         journeyMigrations: .journey(catalog: firstCatalog))
    save.load()
    try save.save(pending)
    try save.save(initialCare)
    var expectedJourney = pending
    var expectedCare = initialCare
    CareEngine.process(journey: &expectedJourney, care: &expectedCare, stories: firstCatalog.stories, catalog: firstCatalog)
    #expect(expectedJourney.letters.first?.storyId == remoteStoryID)

    var laterStory = try remoteStory(id: "hub.hangzhou.tests.later-story")
    laterStory["requires"] = ["tool": "codex"]
    _ = try await archive.accept([remoteJSON(laterStory), remoteJSON(remoteItem(id: "hub.hangzhou.tests.later-souvenir"))], cityID: "hangzhou")
    let restartedCatalog = RemoteContentStore.load(url: url, validator: validator).merging(into: localizationCatalog)
    let restarted = SaveStore(directory: directory, pets: restartedCatalog.pets, items: restartedCatalog.items,
                              journeyMigrations: .journey(catalog: restartedCatalog))
    restarted.load()
    guard case .loaded(var actualJourney) = restarted.journey, case .loaded(var actualCare) = restarted.care else {
        Issue.record("Frozen trip saves did not reload"); return
    }
    #expect(actualJourney.remoteContentByTrip?[1]?.entryIDs == first.ids)
    CareEngine.process(journey: &actualJourney, care: &actualCare, stories: restartedCatalog.stories, catalog: restartedCatalog)
    #expect(actualJourney == expectedJourney)
    #expect(actualCare == expectedCare)

    // Legacy trips and interrupted fetches always use the bundled pools, even when the archive has grown.
    for snapshot in [Optional<TripContentSnapshot>.none, TripContentSnapshot(cityID: "hangzhou", entryIDs: [])] {
        var bundledJourney = pending
        bundledJourney.remoteContentByTrip = snapshot.map { [1: $0] }
        var remoteJourney = bundledJourney
        var bundledCare = initialCare
        var remoteCare = initialCare
        CareEngine.process(journey: &bundledJourney, care: &bundledCare, stories: localizationCatalog.stories, catalog: localizationCatalog)
        CareEngine.process(journey: &remoteJourney, care: &remoteCare, stories: restartedCatalog.stories, catalog: restartedCatalog)
        #expect(remoteJourney == bundledJourney)
        #expect(remoteCare == bundledCare)
    }
}

@Test func remoteReplyReferencesUseOnlyOtherValidStories() throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let first = try remoteStory()
    var dependent = try remoteStory(id: "hub.hangzhou.dependent")
    dependent["fulfills"] = [remoteStoryID + ".talkative"]
    let both = validator.accepting([try remoteJSON(dependent), try remoteJSON(first)], cityID: "hangzhou", into: RemoteCityContent())
    #expect(both.stories.count == 2)
    var invalid = first
    invalid["tags"] = ["unknown"]
    let neither = validator.accepting([try remoteJSON(dependent), try remoteJSON(invalid)], cityID: "hangzhou", into: RemoteCityContent())
    #expect(neither.stories.isEmpty)
}

@Test func remoteArchiveWriteFailureDoesNotExposeOrRememberUnpersistedContent() async throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appendingPathComponent("blocked")
    try Data("not a directory".utf8).write(to: blocker)
    let url = blocker.appendingPathComponent("remote-content.json")
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let archive = RemoteContentStore(url: url, validator: validator, content: RemoteCityContent())
    await #expect(throws: (any Error).self) {
        try await archive.accept([remoteJSON(remoteStory())], cityID: "hangzhou")
    }
    try FileManager.default.removeItem(at: blocker)
    let accepted = try await archive.accept([remoteJSON(remoteItem())], cityID: "hangzhou")
    #expect(accepted.content.ids == [remoteItemID])
    #expect(RemoteContentStore.load(url: url, validator: validator).ids == [remoteItemID])
}

@Test func remoteArchiveNeverOverwritesAnUnsupportedFile() async throws {
    let directory = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("remote-content.json")
    let original = try remoteJSON(["schemaVersion": 2, "entries": [remoteItemID: try remoteItem()]])
    try original.write(to: url)
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let archive = RemoteContentStore(url: url, validator: validator, content: RemoteContentStore.load(url: url, validator: validator))
    await #expect(throws: (any Error).self) {
        try await archive.accept([remoteJSON(remoteStory())], cityID: "hangzhou")
    }
    #expect(try Data(contentsOf: url) == original)
}

private final class RemoteSettingsDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { defaultName == "language" ? "en" : nil }
    override func string(forKey defaultName: String) -> String? { defaultName == "language" ? "en" : nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

@Suite @MainActor struct RemoteSaveArchiveTests {
    private let archiveDate = Date(timeIntervalSince1970: 1_794_276_000)

    private func model(at directory: URL) -> AppModel {
        AppModel(defaults: RemoteSettingsDefaults(), directory: directory, catalog: localizationCatalog,
                 contentDirectory: remotePack, themes: testThemes, now: { archiveDate },
                 usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
                 enrichmentReader: { _ in Enrichment() }, hubClient: HubClient(baseURL: nil), runtimeEnabled: false)
    }

    private func seedSaves(at directory: URL, content: RemoteCityContent = RemoteCityContent()) throws {
        let catalog = content.merging(into: localizationCatalog)
        let store = SaveStore(directory: directory, pets: catalog.pets, items: catalog.items,
                              journeyMigrations: .journey(catalog: catalog))
        store.load()
        let journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: archiveDate),
                                   now: archiveDate, catalog: catalog)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        care.souvenirs = content.items.keys.sorted().enumerated().map {
            .init(id: $0.element, letterId: $0.offset + 1, shelved: $0.offset == 0)
        }
        care.roomPlacements = content.items.keys.sorted().dropFirst().map { .init(slot: "wall", itemID: $0) }
        try store.save(journey)
        try store.save(care)
    }

    private func archive(at directory: URL, member: Any? = nil) async throws -> URL {
        try seedSaves(at: directory)
        let app = model(at: directory)
        let file = directory.appendingPathComponent("export.json")
        await app.exportSave(to: file)
        #expect(app.archiveError == nil)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document["remote-content.json"] = member
        try remoteJSON(document).write(to: file)
        return file
    }

    @Test func roundTripKeepsServerItemsOnShelfInRoomAndInCollectionsAfterRestart() async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
        let remote = RemoteContentStore(url: source.appendingPathComponent("remote-content.json"),
                                        validator: validator, content: RemoteCityContent())
        let secondID = remoteItemID + ".wall"
        let accepted = try await remote.accept([remoteJSON(remoteStory()), remoteJSON(remoteItem()),
                                                remoteJSON(remoteItem(id: secondID))], cityID: "hangzhou")
        try seedSaves(at: source, content: accepted.content)
        let original = model(at: source)
        let file = source.appendingPathComponent("export.json")
        await original.exportSave(to: file)
        #expect(original.archiveError == nil)
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(document["format"] as? Int == 1)
        let member = try #require(document["remote-content.json"] as? [String: Any])
        #expect(member["schemaVersion"] as? Int == 1)
        #expect(Set((member["entries"] as? [String: Any] ?? [:]).keys) == accepted.content.ids)

        #expect(!FileManager.default.fileExists(atPath: target.path))
        let imported = model(at: target)
        let candidate = try imported.validateImport(at: file)
        #expect(candidate.care.roomPlacements == original.care?.roomPlacements)
        #expect(await imported.importSave(candidate))
        for app in [imported, model(at: target)] {
            let care = try #require(app.care)
            let catalog = try #require(app.catalog)
            #expect(care.souvenirs == original.care?.souvenirs)
            #expect(care.roomPlacements == original.care?.roomPlacements)
            #expect(RoomLayout.shelf(care).map(\.id) == [remoteItemID])
            #expect(RoomDecor.item(in: .wall, care: care) == secondID)
            #expect(catalog.stories.all.first { $0.id == remoteStoryID } == accepted.content.stories[remoteStoryID])
            for souvenir in care.souvenirs {
                let item = try #require(catalog.items.find(souvenir.id))
                #expect(item == accepted.content.items[souvenir.id])
                for language in Language.allCases {
                    #expect(ItemDisplay(item, l10n: L10n(language: language)).name == item.names[language.rawValue])
                }
            }
        }
        #expect(RemoteContentStore.load(url: target.appendingPathComponent("remote-content.json"), validator: validator).ids == accepted.content.ids)
    }

    @Test func oldArchiveWithoutRemoteMemberStillImports() async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let file = try await archive(at: source)
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(document["remote-content.json"] == nil)
        let app = model(at: target)
        let candidate = try app.validateImport(at: file)
        #expect(candidate.remoteContent == nil)
        #expect(await app.importSave(candidate))
        #expect(app.state == candidate.journey && app.care == candidate.care)
        #expect(!app.isLocked && app.archiveError == nil)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("remote-content.json").path))
    }

    @Test func importRevalidatesEachEntryAndKeepsValidNeighbors() async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        var story = try remoteStory()
        story["rewards"] = ["itemIds": [remoteItemID], "menuIds": [String]()]
        var entries: [String: Any] = [remoteStoryID: story, remoteItemID: try remoteItem()]
        let otherCityID = "hub.suzhou.archive.souvenir"
        entries[otherCityID] = try remoteItem(cityID: "suzhou", id: otherCityID)
        for failure in ["city", "facts", "bundledID", "replyID", "sponsor", "nestedSponsor", "keyMismatch", "malformed"] {
            let id = "hub.hangzhou.archive." + failure
            var invalid = try remoteStory(id: id)
            switch failure {
            case "city": invalid["cityId"] = "unknown-city"
            case "facts": invalid["factIds"] = ["unknown-fact"]
            case "bundledID": invalid["id"] = try #require(localizationCatalog.stories.all.first?.id)
            case "replyID":
                var replies = try #require(invalid["replies"] as? [[String: Any]])
                replies[0]["id"] = try #require(localizationCatalog.stories.all.first { !$0.replies.isEmpty }?.replies.first?.id)
                invalid["replies"] = replies
            case "sponsor": invalid["sponsor"] = NSNull()
            case "nestedSponsor": invalid["extra"] = ["sponsor": false]
            case "keyMismatch": invalid["id"] = id + ".different"
            default: invalid.removeValue(forKey: "text")
            }
            entries[invalid["id"] as? String ?? id] = invalid
            if failure == "keyMismatch" { entries[id] = entries.removeValue(forKey: id + ".different") }
        }
        entries["invalid-scalar"] = 42
        let file = try await archive(at: source, member: ["schemaVersion": 1, "entries": entries])
        let app = model(at: target)
        let candidate = try app.validateImport(at: file)
        // Preview validation does not install content before the user confirms.
        #expect(app.catalog?.items.find(remoteItemID) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("remote-content.json").path))
        #expect(await app.importSave(candidate))
        #expect(app.archiveError == nil)
        let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
        let loaded = RemoteContentStore.load(url: target.appendingPathComponent("remote-content.json"), validator: validator)
        #expect(loaded.ids == [remoteStoryID, remoteItemID, otherCityID])
        #expect(loaded.stories[remoteStoryID]?.rewards.itemIds == [remoteItemID])
        #expect(app.catalog?.items.find(otherCityID) == loaded.items[otherCityID])
    }

    @Test func localVersionsWinWhileNewArchivedEntriesMergeAndSurviveRestart() async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
        let remote = RemoteContentStore(url: target.appendingPathComponent("remote-content.json"),
                                        validator: validator, content: RemoteCityContent())
        let localOnlyID = remoteItemID + ".local"
        let local = try await remote.accept([remoteJSON(remoteStory()), remoteJSON(remoteItem()),
                                             remoteJSON(remoteItem(id: localOnlyID))], cityID: "hangzhou")
        var editedItem = try remoteItem()
        editedItem["names"] = ["en": "Archive replacement", "zh-Hans": "归档里的替换名字"]
        var editedStory = try remoteStory()
        editedStory["text"] = ["en": "Archive replacement", "zh-Hans": "归档里的替换情节"]
        let newID = remoteItemID + ".imported"
        let entries = [remoteStoryID: editedStory, remoteItemID: editedItem, newID: try remoteItem(id: newID)]
        let file = try await archive(at: source, member: ["schemaVersion": 1, "entries": entries])
        let app = model(at: target)
        #expect(await app.importSave(try app.validateImport(at: file)))
        for current in [app, model(at: target)] {
            #expect(current.catalog?.items.find(remoteItemID) == local.content.items[remoteItemID])
            #expect(current.catalog?.stories.all.first { $0.id == remoteStoryID } == local.content.stories[remoteStoryID])
            #expect(current.catalog?.items.find(localOnlyID) == local.content.items[localOnlyID])
            #expect(current.catalog?.items.find(newID) != nil)
        }
        #expect(RemoteContentStore.load(url: target.appendingPathComponent("remote-content.json"), validator: validator).ids == local.content.ids.union([newID]))
    }

    @Test(arguments: ["broken", "futureVersion", "missingVersion", "badEntries", "null"])
    func corruptRemoteMemberIsIgnoredWithoutFailingImport(problem: String) async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let member: Any
        switch problem {
        case "futureVersion": member = ["schemaVersion": 999, "entries": [remoteItemID: try remoteItem()]]
        case "missingVersion": member = ["entries": [remoteItemID: try remoteItem()]]
        case "badEntries": member = ["schemaVersion": 1, "entries": []] as [String: Any]
        case "null": member = NSNull()
        default: member = "{broken JSON"
        }
        let file = try await archive(at: source, member: member)
        let app = model(at: target)
        let candidate = try app.validateImport(at: file)
        #expect(await app.importSave(candidate))
        #expect(app.state == candidate.journey && app.care == candidate.care)
        #expect(!app.isLocked && app.archiveError == nil)
        #expect(app.catalog?.items.find(remoteItemID) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("remote-content.json").path))
    }

    @Test(arguments: [false, true])
    func remoteStoreFailureDoesNotBlockSaveImport(corruptLocalStore: Bool) async throws {
        let source = remoteTestDirectory(), target = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let file = try await archive(at: source, member: ["schemaVersion": 1, "entries": [remoteItemID: try remoteItem()]])
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let remoteURL = target.appendingPathComponent("remote-content.json")
        let corrupt = Data("preserve corrupt local store".utf8)
        if corruptLocalStore { try corrupt.write(to: remoteURL) }
        let app = model(at: target)
        if !corruptLocalStore { try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: false) }
        let candidate = try app.validateImport(at: file)
        #expect(await app.importSave(candidate))
        #expect(!app.isLocked && app.archiveError == nil)
        #expect(app.state == candidate.journey && app.care == candidate.care)
        #expect(app.catalog?.items.find(remoteItemID) == nil)
        if corruptLocalStore { #expect(try Data(contentsOf: remoteURL) == corrupt) }
    }
}

@MainActor private final class RemoteDepartureClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private actor RemoteDepartureTransport {
    let gated: Bool
    let failing: Bool
    private var requests: [URLRequest] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    init(gated: Bool = false, failing: Bool = false) { self.gated = gated; self.failing = failing }
    func contentCount() -> Int { requests.filter { $0.url?.path.contains("/cities/") == true }.count }
    func waitForContentRequest() async {
        if arrived { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func release() { gates.forEach { $0.resume() }; gates = [] }
    func releaseFirst() { if !gates.isEmpty { gates.removeFirst().resume() } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path == "/v1/config" {
            let data = try JSONEncoder().encode(HubConfig.defaults)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        arrived = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters = []
        if gated { await withCheckedContinuation { gates.append($0) } }
        if failing { throw URLError(.cannotConnectToHost) }
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let cityID = String(components.path.split(separator: "/")[2])
        let language = try #require(components.queryItems?.first { $0.name == "lang" }?.value)
        let envelope: [String: Any] = [
            "schemaVersion": 1, "cityId": cityID, "language": language, "disabled": false,
            "items": [try remoteStory(cityID: cityID, id: "hub.\(cityID).departure.story"),
                      try remoteItem(cityID: cityID, id: "hub.\(cityID).departure.souvenir")],
        ]
        return (try remoteJSON(envelope), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite @MainActor struct RemoteDepartureTests {
    private func model(at directory: URL, clock: RemoteDepartureClock, transport: RemoteDepartureTransport) -> AppModel {
        let hub = HubClient(baseURL: URL(string: "https://voyage.example.invalid")!,
                            transport: { try await transport.send($0) }, keyLoader: { Data(repeating: 7, count: 32) })
        return AppModel(defaults: RemoteSettingsDefaults(), directory: directory, catalog: localizationCatalog,
                        contentDirectory: remotePack, themes: testThemes, now: { clock.now }, onboardingSeed: 7,
                        usageReader: { _, _ in [] }, hoursReader: { _, _ in [] },
                        enrichmentReader: { _ in Enrichment() }, hubClient: hub, runtimeEnabled: false)
    }

    private func savePending(at directory: URL, now: Date) throws -> JourneyState {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: localizationCatalog)
        journey.phase = .pending
        journey.phaseSince = now
        journey.legFuel = outboundTokensPerKm
        var day = DayRecord()
        day.tokens = outboundTokensPerKm
        day.lastObservedAt = now
        journey.days[journey.openDate] = day
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, items: localizationCatalog.items,
                              journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate))
        return journey
    }

    @Test(arguments: [false, true])
    func pendingDeparturesFetchOnceWithoutDelayingTravel(immediate: Bool) async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let pending = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(immediate ? 60 : 30 * 60))
        let transport = RemoteDepartureTransport(gated: true)
        let app = model(at: directory, clock: clock, transport: transport)
        if immediate { app.departNow() } else { app.tick() }
        #expect(app.state?.phase == .outbound)
        #expect(app.state?.totalKm == 1)
        #expect(app.state?.days[pending.openDate]?.lastObservedAt == now)
        let task = try #require(app.departureContentTasks[1])
        await transport.waitForContentRequest()
        #expect(app.state?.phase == .outbound)
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs == [])
        app.tick()
        app.departNow()
        await transport.release()
        await task.value
        #expect(await transport.contentCount() == 1)
        let storyID = "hub.\(pending.targetCityId).departure.story"
        let itemID = "hub.\(pending.targetCityId).departure.souvenir"
        #expect(Set(app.state?.remoteContentByTrip?[1]?.entryIDs ?? []) == [storyID, itemID])
        #expect(app.catalog?.stories.all.contains { $0.id == storyID } == true)
        #expect(app.catalog?.items.find(itemID) != nil)
        let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
        #expect(RemoteContentStore.load(url: directory.appendingPathComponent("remote-content.json"), validator: validator).ids == [storyID, itemID])
        let restarted = model(at: directory, clock: clock, transport: transport)
        #expect(restarted.state?.remoteContentByTrip?[1]?.entryIDs == app.state?.remoteContentByTrip?[1]?.entryIDs)
        #expect(restarted.catalog?.items.find(itemID) != nil)
        #expect(await transport.contentCount() == 1)
    }

    @Test func failedDepartureFetchKeepsBundledTravelAndDoesNotRetryAfterRestart() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        _ = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(60))
        let transport = RemoteDepartureTransport(failing: true)
        let app = model(at: directory, clock: clock, transport: transport)
        app.departNow()
        let task = try #require(app.departureContentTasks[1])
        await task.value
        #expect(app.state?.phase == .outbound)
        #expect(app.state?.totalKm == 1)
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs == [])
        #expect(app.lastError == nil)
        #expect(app.catalog?.stories.all.count == localizationCatalog.stories.all.count)
        #expect(app.catalog?.items.all.count == localizationCatalog.items.all.count)
        app.tick()
        let restarted = model(at: directory, clock: clock, transport: transport)
        restarted.tick()
        #expect(await transport.contentCount() == 1)
    }

    @Test func usageScanAlsoRecordsAndFetchesThePendingDeparture() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        _ = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(30 * 60))
        let transport = RemoteDepartureTransport(gated: true)
        let app = model(at: directory, clock: clock, transport: transport)
        await app.scan()
        let task = try #require(app.departureContentTasks[1])
        await transport.waitForContentRequest()
        #expect(app.state?.phase == .outbound)
        await transport.release()
        await task.value
        #expect(await transport.contentCount() == 1)
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs?.count == 2)
    }

    @Test func changingFirstDayHomeFetchesTheReplacementDestinationAndDiscardsTheOldTask() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        _ = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(60))
        let transport = RemoteDepartureTransport(gated: true)
        let app = model(at: directory, clock: clock, transport: transport)
        app.departNow()
        let oldTask = try #require(app.departureContentTasks[1])
        await transport.waitForContentRequest()
        app.setStart("beijing")
        let replacement = try #require(app.departureContentTasks[1])
        let target = try #require(app.state?.remoteContentByTrip?[1]?.cityID)
        #expect(app.state?.homeCityId == "beijing")
        while await transport.contentCount() < 2 { await Task.yield() }
        await transport.releaseFirst()
        await oldTask.value
        #expect(app.departureContentTasks[1] != nil)
        await transport.release()
        await replacement.value
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs?.count == 2)
        #expect(app.catalog?.items.find("hub.\(target).departure.souvenir") != nil)
    }

    @Test func localTogglePreventsDepartureRequest() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        _ = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(60))
        let transport = RemoteDepartureTransport()
        let app = model(at: directory, clock: clock, transport: transport)
        app.cityContentEnabled = false
        app.departNow()
        #expect(app.state?.phase == .outbound)
        #expect(app.departureContentTasks.isEmpty)
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs == [])
        #expect(await transport.contentCount() == 0)
    }

    @Test func settlementBeforeResponseFreezesBundledCandidatesButStillArchivesContent() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let pending = try savePending(at: directory, now: now)
        let clock = RemoteDepartureClock(now.addingTimeInterval(60))
        let transport = RemoteDepartureTransport(gated: true)
        let app = model(at: directory, clock: clock, transport: transport)
        app.departNow()
        let task = try #require(app.departureContentTasks[1])
        await transport.waitForContentRequest()
        clock.now = now.addingTimeInterval(24 * 3600)
        await app.scan()
        let letter = try #require(app.state?.letters.first { $0.kind == .daily })
        #expect(letter.tripNumber == 1 && letter.storyId != nil)
        await transport.release()
        await task.value
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs == [])
        #expect(app.state?.letters.first { $0.kind == .daily } == letter)
        #expect(app.catalog?.items.find("hub.\(pending.targetCityId).departure.souvenir") != nil)
    }

    @Test func onboardingFirstTripSchedulesCityContentImmediately() async throws {
        let directory = remoteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let clock = RemoteDepartureClock(now)
        let transport = RemoteDepartureTransport(gated: true)
        let app = model(at: directory, clock: clock, transport: transport)
        let flow = try #require(app.onboarding)
        flow.selectEgg(localizationCatalog.pets.defaultID)
        while flow.step != .depart { flow.advance(l10n: app.l10n) }
        app.completeOnboarding()
        let task = try #require(app.departureContentTasks[1])
        await transport.waitForContentRequest()
        #expect(app.onboarding == nil)
        #expect(app.state != nil)
        await transport.release()
        await task.value
        #expect(await transport.contentCount() == 1)
        #expect(app.state?.remoteContentByTrip?[1]?.entryIDs?.count == 2)
    }
}

private var remotePartner: [String: Any] { ["id": "corner-shop", "label": ["zh-Hans": "路边小店", "en": "Corner Shop"]] }

@Test func remoteTopLevelSponsorPreservesBilingualShapeAndPartnerIDIsNotAContentID() throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var story = try remoteStory(), item = try remoteItem()
    story["sponsor"] = remotePartner; story["factIds"] = [String]()
    item["sponsor"] = remotePartner
    let result = validator.accepting([try remoteJSON(story), try remoteJSON(item)], cityID: "hangzhou", into: RemoteCityContent())
    #expect(result.ids == [remoteStoryID, remoteItemID])
    #expect(result.stories[remoteStoryID]?.sponsor?.label == remotePartner["label"] as? [String: String])
    #expect(result.items[remoteItemID]?.sponsor == result.stories[remoteStoryID]?.sponsor)
    // Reusing a partner across entries and responses cannot collide with the entry ID namespace.
    var second = try remoteItem(id: remoteItemID + ".second")
    second["sponsor"] = remotePartner
    let next = validator.accepting([try remoteJSON(second)], cityID: "hangzhou", into: result)
    #expect(next.ids.count == 3)
}

@Test(arguments: ["badID", "shortID", "longID", "newlineID", "emptyLabel", "longLabel", "missingLanguage", "extraKey", "extraLocale", "nested", "nestedInSponsor", "facts", "ordinaryNoFacts", "uncommon", "rare"])
func remoteSponsorShapeAndDeliveryConstraintsDropOnlyTheInvalidEntry(_ failure: String) throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var story = try remoteStory(), item = try remoteItem()
    var sponsor = remotePartner
    story["factIds"] = [String]()
    switch failure {
    case "badID": sponsor["id"] = "Corner_Shop"
    case "shortID": sponsor["id"] = "a"
    case "longID": sponsor["id"] = String(repeating: "a", count: 41)
    case "newlineID": sponsor["id"] = "ab\n"
    case "emptyLabel": sponsor["label"] = ["zh-Hans": " \n ", "en": "Shop"]
    case "longLabel": sponsor["label"] = ["zh-Hans": String(repeating: "店", count: 25), "en": "Shop"]
    case "missingLanguage": sponsor["label"] = ["en": "Shop"]
    case "extraKey": sponsor["url"] = "offline"
    case "extraLocale": sponsor["label"] = ["zh-Hans": "小店", "en": "Shop", "fr": "Magasin"]
    case "nested": story["metadata"] = ["nested": [["sponsor": remotePartner]]]
    case "nestedInSponsor": sponsor["sponsor"] = remotePartner
    case "facts": story["factIds"] = try remoteStory()["factIds"]
    case "uncommon", "rare": item["rarity"] = failure
    default: break
    }
    let invalidItem = ["uncommon", "rare"].contains(failure)
    if invalidItem { item["sponsor"] = sponsor }
    else if failure != "ordinaryNoFacts" { story["sponsor"] = sponsor }
    if invalidItem { story = try remoteStory() }
    let result = validator.accepting([try remoteJSON(story), try remoteJSON(item)], cityID: "hangzhou", into: RemoteCityContent())
    #expect(result.ids == (invalidItem ? [remoteStoryID] : [remoteItemID]), "Invalid: \(failure)")
}

@Test func sponsorLabelsCountCharactersRatherThanUnicodeScalarsOrBytes() throws {
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    var item = try remoteItem()
    let label = String(repeating: "e\u{301}", count: 24)
    item["sponsor"] = ["id": "ab", "label": ["zh-Hans": label, "en": label]]
    let result = validator.accepting([try remoteJSON(item)], cityID: "hangzhou", into: RemoteCityContent())
    #expect(result.items[remoteItemID]?.sponsor?.label["en"] == label)
}

@Test func partnerRemoteArchiveSurvivesExportImportAndFrozenTripReload() async throws {
    let source = remoteTestDirectory(), target = remoteTestDirectory()
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
    let validator = try RemoteContentValidator(directory: remotePack, catalog: localizationCatalog)
    let first = RemoteContentStore(url: source.appendingPathComponent("remote-content.json"), validator: validator, content: RemoteCityContent())
    var story = try remoteStory(), item = try remoteItem()
    story["sponsor"] = remotePartner; story["factIds"] = [String]()
    item["sponsor"] = remotePartner
    let accepted = try await first.accept([remoteJSON(story), remoteJSON(item)], cityID: "hangzhou")
    let exported = try #require(await first.exportArchiveData())
    let second = RemoteContentStore(url: target.appendingPathComponent("remote-content.json"), validator: validator, content: RemoteCityContent())
    let imported = try await second.mergeArchive(exported)
    #expect(imported.ids == accepted.content.ids)
    #expect(imported.stories == accepted.content.stories && imported.items == accepted.content.items)
    let restarted = RemoteContentStore.load(url: target.appendingPathComponent("remote-content.json"), validator: validator)
    #expect(restarted.stories == imported.stories && restarted.items == imported.items)
    #expect(try JSONSerialization.jsonObject(with: #require(await second.exportArchiveData())) as? NSDictionary
            == JSONSerialization.jsonObject(with: exported) as? NSDictionary)
}
