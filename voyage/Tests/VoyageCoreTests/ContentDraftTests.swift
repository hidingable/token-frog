import Foundation
import Testing
@testable import VoyageCore

private struct DraftSandbox {
    let root: URL
    let pack: URL
    let drafts: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-draft-tests-\(UUID().uuidString)")
        pack = root.appendingPathComponent("Content")
        drafts = root.appendingPathComponent("drafts")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/draft-pack")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: pack)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func story() throws -> Story {
        var story = try JSONDecoder().decode([Story].self, from: Data(contentsOf: pack.appendingPathComponent("stories/harbor.json")))[0]
        story.id = "harbor.new-story"
        story.replies = story.replies.map { reply in
            var reply = reply
            reply.id = story.id + "." + reply.habit
            return reply
        }
        return story
    }

    func item() throws -> Item {
        var item = try JSONDecoder().decode([Item].self, from: Data(contentsOf: pack.appendingPathComponent("items/harbor.json")))[0]
        item.id = "harbor.new-item"
        return item
    }

    func write<T: Encodable>(_ entries: [T], kind: String, city: String = "harbor") throws {
        try writeData(JSONEncoder().encode(entries), kind: kind, city: city)
    }

    func writeData(_ data: Data, kind: String, city: String = "harbor") throws {
        let folder = drafts.appendingPathComponent(kind)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(city).json"))
    }

    var issues: [ContentIssue] { ContentValidator.validate(directory: pack, drafts: drafts) }
}

@Test func tinyDraftFixtureIsAValidContentPack() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    #expect(ContentValidator.validate(directory: box.pack).isEmpty)
}

@Test func draftsMergeStoriesAndItemsWithoutChangingTheSourcePack() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    let storyFile = box.pack.appendingPathComponent("stories/harbor.json")
    let itemFile = box.pack.appendingPathComponent("items/harbor.json")
    let originalStories = try Data(contentsOf: storyFile)
    let originalItems = try Data(contentsOf: itemFile)
    var story = try box.story()
    story.rewards.itemIds = ["harbor.new-item"]
    try box.write([story], kind: "stories")
    try box.write([box.item()], kind: "items")

    #expect(box.issues.isEmpty)
    #expect(try Data(contentsOf: storyFile) == originalStories)
    #expect(try Data(contentsOf: itemFile) == originalItems)
    #expect(ContentValidator.overlayDrafts(directory: box.pack, drafts: box.drafts).isEmpty)
    let stories = try JSONDecoder().decode([Story].self, from: Data(contentsOf: storyFile))
    let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: itemFile))
    #expect(stories.map(\.id) == ["harbor.arrival", "harbor.new-story"])
    #expect(items.map(\.id) == ["harbor.note", "harbor.new-item"])
    #expect(ContentValidator.validate(directory: box.pack).isEmpty)
}

@Test(arguments: ["harbor.arrival", "harbor.note", "harbor.arrival.talkative", "harbor", "harbor-river", "clue.0", "pet", "ribbon"])
func draftIDsCannotCollideWithAnyBundledNamespace(id: String) throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    var story = try box.story()
    story.id = id
    try box.write([story], kind: "stories")
    #expect(box.issues.contains { $0.rule == "draftID" && $0.message.contains(id) })
}

@Test func draftsCannotReusePublishedIDsEvenWhenTheirContentIsAbsent() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    try "harbor\nretired-id\n".write(to: box.pack.appendingPathComponent("published-ids.txt"), atomically: true, encoding: .utf8)
    var item = try box.item()
    item.id = "retired-id"
    try box.write([item], kind: "items")
    #expect(box.issues.contains { $0.rule == "draftID" && $0.message.contains("retired-id") })
}

@Test func draftIDsCannotReuseBaseCityTSVIdentifiers() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    let world = box.pack.appendingPathComponent("world")
    try FileManager.default.createDirectory(at: world, withIntermediateDirectories: true)
    try (CityContent.header + "\nq101\t31\t121\tCN\tasia\t2\tBase Harbor\t基础港\n")
        .write(to: world.appendingPathComponent("cities.tsv"), atomically: true, encoding: .utf8)
    var story = try box.story()
    story.id = "q101"
    try box.write([story], kind: "stories")
    #expect(box.issues.contains { $0.rule == "draftID" && $0.message.contains("q101") })
}

@Test func draftReplyIDsAndCrossKindIDsMustBeGloballyUnique() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    var story = try box.story()
    story.replies[0].id = "harbor.arrival.talkative"
    var item = try box.item()
    item.id = story.id
    try box.write([story], kind: "stories")
    try box.write([item], kind: "items")
    let issues = box.issues
    #expect(issues.contains { $0.rule == "draftID" && $0.message.contains("harbor.arrival.talkative") })
    #expect(issues.contains { $0.rule == "draftID" && $0.message.contains("Duplicate draft ID: harbor.new-story") })
}

@Test func draftFactsMustComeFromTheNamedCityFile() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    var story = try box.story()
    story.factIds = ["other-city-river"]
    try box.write([story], kind: "stories")
    #expect(box.issues.contains { $0.rule == "draftFacts" && $0.file == "stories/harbor.json" })
}

@Test(arguments: ["stories", "items"])
func draftCityMustMatchItsFilename(kind: String) throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    if kind == "stories" {
        var story = try box.story()
        story.cityId = nil
        try box.write([story], kind: kind)
    } else {
        var item = try box.item()
        item.cityId = nil
        try box.write([item], kind: kind)
    }
    #expect(box.issues.contains { $0.rule == "draftCity" && $0.file == "\(kind)/harbor.json" })
}

@Test(arguments: ["stories", "items"], ["top", "nested"])
func sponsorFieldsAreRejectedBeforeDecodingAtEveryDepth(kind: String, position: String) throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    let encoded = kind == "stories" ? try JSONEncoder().encode([box.story()]) : try JSONEncoder().encode([box.item()])
    var entries = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    let sponsor: [String: Any] = ["id": "corner-shop", "label": ["zh-Hans": "路边小店", "en": "Corner Shop"]]
    if position == "top" { entries[0]["sponsor"] = sponsor }
    else { entries[0]["metadata"] = ["nested": [["sponsor": NSNull()]]] }
    try box.writeData(JSONSerialization.data(withJSONObject: entries), kind: kind)
    #expect(box.issues.contains { $0.rule == "draftSponsor" })
}

@Test func draftsUseExistingSchemaValidationForTranslationsAndReferences() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    var story = try box.story()
    story.text.removeValue(forKey: "en")
    story.rewards.itemIds = ["missing-souvenir"]
    var item = try box.item()
    item.icon = "missing-icon"
    try box.write([story], kind: "stories")
    try box.write([item], kind: "items")
    let issues = box.issues
    #expect(issues.contains { $0.rule == "storyTranslation" })
    #expect(issues.contains { $0.rule == "storyItemReward" })
    #expect(issues.contains { $0.rule == "itemIcon" })
}

@Test func generatedStoryAndItemKindsAndReplyHabitsAreChecked() throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    var story = try box.story()
    story.kind = "fulfill"
    story.replies[1].habit = "talkative"
    var item = try box.item()
    item.kind = "menu"
    item.rarity = nil
    try box.write([story], kind: "stories")
    try box.write([item], kind: "items")
    let issues = box.issues
    #expect(issues.contains { $0.rule == "draftKind" && $0.file == "stories/harbor.json" })
    #expect(issues.contains { $0.rule == "draftKind" && $0.file == "items/harbor.json" })
    #expect(issues.contains { $0.rule == "draftReplies" })
}

@Test(arguments: ["{", "{}", "[42]"])
func malformedDraftFilesFailValidation(json: String) throws {
    let box = try DraftSandbox()
    defer { box.cleanUp() }
    try box.writeData(Data(json.utf8), kind: "stories")
    #expect(box.issues.contains { $0.rule == "draftJSON" })
}
