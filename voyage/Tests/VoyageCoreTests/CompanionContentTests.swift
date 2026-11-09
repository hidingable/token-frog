import Foundation
import Testing
@testable import VoyageCore

@Suite struct CompanionContentTests {
    @Test func originalBilingualContentMeetsTheMinimums() {
        #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
        for (kind, minimum) in [("postcard", 12), ("reunion", 6)] {
            let stories = testCatalog.stories.all.filter { $0.kind == kind }
            #expect(stories.count >= minimum)
            #expect(Set(stories.compactMap { $0.text["en"] }).count == stories.count)
            #expect(Set(stories.compactMap { $0.text["zh-Hans"] }).count == stories.count)
            for story in stories {
                #expect(story.cityId == nil && story.factIds.isEmpty && story.replies.isEmpty)
                #expect(story.fulfills.isEmpty && story.fulfillsHabit == nil && story.requires.isEmpty)
                for language in ["en", "zh-Hans"] {
                    #expect(story.memoryLead?[language]?.contains("{memory}") == true)
                    #expect(!story.text[language]!.contains("{memory}"))
                }
            }
        }
        #expect(testCatalog.items.all.filter { $0.source == "postcard" }.count >= 8)
        #expect(testCatalog.items.all.filter { $0.source == "reunion" }.count >= 4)
        for kind in ["postcard", "reunion"] {
            for item in testCatalog.items.all where item.source == kind {
                #expect(item.kind == "souvenir" && item.cityId == nil && item.habit == nil)
            }
        }
    }

    @Test(arguments: ["translation", "mismatch", "unknown", "city", "reply", "no-memory", "no-postcard", "no-reunion"])
    func invalidCompanionStoriesAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("stories/companionship.json")
        var stories = try JSONDecoder().decode([Story].self, from: Data(contentsOf: file))
        switch failure {
        case "translation": stories[0].text.removeValue(forKey: "en")
        case "mismatch": stories[0].memoryLead?["en"] = "{pet}"
        case "unknown": stories[0].text = ["en": "{unsupported}", "zh-Hans": "{unsupported}"]
        case "city": stories[0].cityId = "shanghai"
        case "reply": stories[0].replies = engineStory("reply").replies
        case "no-memory": stories[0].memoryLead = nil
        case "no-postcard": stories.removeAll { $0.kind == "postcard" }
        default: stories.removeAll { $0.kind == "reunion" }
        }
        try JSONEncoder().encode(stories).write(to: file)
        #expect(!ContentValidator.validate(directory: box.directory).isEmpty)
    }

    @Test(arguments: ["source", "gift-rarity", "no-common", "no-uncommon", "no-rare", "no-gift", "translation", "slots"])
    func invalidPoolsAndItemTranslationsAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("items/companionship.json")
        var items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: file))
        switch failure {
        case "source": items[0].source = "unknown"
        case "gift-rarity": items[items.firstIndex { $0.source == "reunion" }!].rarity = "rare"
        case "no-gift": items.removeAll { $0.source == "reunion" }
        case "slots": items[0].names["en"] = "{pet}"
        case "translation": items[0].descriptions.removeValue(forKey: "en")
        default: items.removeAll { $0.source == "postcard" && $0.rarity == String(failure.dropFirst(3)) }
        }
        try JSONEncoder().encode(items).write(to: file)
        #expect(!ContentValidator.validate(directory: box.directory).isEmpty)
    }

    @Test func ordinaryTravelCannotDrawCompanionOrBoxItems() {
        var (journey, care) = engineState()
        for id in 1...200 {
            journey.letters.append(engineLetter(id))
            CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
            #expect(journey.letters.last!.rewards.itemIds.allSatisfy { testCatalog.items.find($0)?.source == nil })
        }
    }
}
