import Foundation
import Testing
@testable import VoyageCore

extension ContentSandbox {
    func editStories(_ edit: (inout [[String: Any]]) -> Void) throws {
        let file = directory.appendingPathComponent("stories/generic.json")
        var stories = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        edit(&stories)
        try JSONSerialization.data(withJSONObject: stories, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

@Suite struct StoryContentTests {
    @Test func repositoryHasEnoughOriginalBilingualStoriesAndTwoRepliesPerLetter() throws {
        #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
        let stories = testCatalog.stories.all
        #expect(stories.filter { $0.kind == "arrival" && $0.cityId == nil }.count >= 10)
        #expect(stories.filter { $0.kind == "transit" && $0.cityId == nil }.count >= 5)
        for habit in ["talkative", "observant"] {
            #expect(stories.filter { $0.kind == "fulfill" && $0.fulfillsHabit == habit && $0.lead != nil }.count >= 4)
        }
        for story in stories {
            #expect(story.replies.count == 2)
            #expect(Set(story.replies.map(\.habit)) == ["talkative", "observant"])
            #expect(story.replies.allSatisfy { $0.text["zh-Hans"]!.count <= 12 })
            #expect(story.rewards == .init() && story.factIds.isEmpty)
            for texts in [story.text] + (story.lead.map { [$0] } ?? []) + story.replies.map(\.text) {
                let chinese = try #require(texts["zh-Hans"])
                let english = try #require(texts["en"])
                #expect(!chinese.isEmpty && !english.isEmpty)
                #expect(chinese.range(of: #"\p{Han}"#, options: .regularExpression) != nil)
                #expect(english.range(of: #"\p{Han}"#, options: .regularExpression) == nil)
            }
        }
    }

    @Test func everyArrivalAndTransitReplyHasItsOwnGenericFulfillment() throws {
        let stories = testCatalog.stories.all
        let replies = stories.filter { ["arrival", "transit"].contains($0.kind) && $0.requires.item == nil }.flatMap(\.replies)
        #expect(replies.count == 30)
        let allReplyIds = stories.flatMap { $0.replies.map(\.id) }
        #expect(Set(allReplyIds).count == allReplyIds.count)
        for reply in replies {
            let matches = stories.filter { $0.kind == "fulfill" && $0.fulfills == [reply.id] && $0.cityId == nil }
            #expect(matches.count == 1, "Missing dedicated fulfillment for \(reply.id)")
            let story = try #require(matches.first)
            #expect(story.fulfillsHabit == nil && story.requires.isEmpty)
            for language in ["zh-Hans", "en"] {
                #expect(story.lead?[language]?.contains("{reply}") == true)
            }
        }
        for story in stories where story.kind == "fulfill" && story.cityId == nil {
            for text in Array(story.text.values) + Array(story.lead?.values ?? [:].values) {
                #expect(!StorySlots.names(in: text).contains("city"))
            }
        }
    }

    @Test(arguments: ["same-file", "another-file"])
    func duplicateReplyIdsAreRejectedAcrossStories(location: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        var other = engineStory("another-story")
        other.replies[0].id = testCatalog.stories.all[0].replies[0].id
        if location == "another-file" {
            try JSONEncoder().encode([other]).write(to: box.directory.appendingPathComponent("stories/another.json"))
        } else {
            try box.editStories { stories in
                var replies = stories[1]["replies"] as! [[String: Any]]
                replies[0]["id"] = (stories[0]["replies"] as! [[String: Any]])[0]["id"]
                stories[1]["replies"] = replies
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "replyID" })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: ["text", "lead"], ["zh-Hans", "en"])
    func citylessFulfillmentsCannotUseTheCitySlot(field: String, language: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            let index = stories.firstIndex { ($0["kind"] as? String) == "fulfill" }!
            var texts = stories[index][field] as! [String: String]
            texts[language] = "{city}"
            stories[index][field] = texts
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyCitySlot" })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test func citySpecificFulfillmentsCanStillUseTheCitySlot() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        var local = engineStory("local.payoff", kind: "fulfill", city: "shanghai")
        local.fulfills = [testCatalog.stories.all[0].replies[0].id]
        try JSONEncoder().encode([local]).write(to: box.directory.appendingPathComponent("stories/local.json"))
        #expect(ContentValidator.validate(directory: box.directory).isEmpty)
    }

    @Test(arguments: ["storyID", "storyVersion", "storyKind", "storyCity", "storyFacts", "storyTags", "requiredHabit", "fulfilledHabit", "replyHabit", "storySeason", "storyFulfills", "replyID"])
    func validatorReportsEveryStoryReferenceAndValueRule(rule: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            switch rule {
            case "storyID": stories.append(stories[0])
            case "storyVersion": stories[0]["version"] = 0
            case "storyKind": stories[0]["kind"] = "postcard"
            case "storyCity": stories[0]["cityId"] = "missing-city"
            case "storyFacts": stories[0]["factIds"] = ["missing-fact"]
            case "storyTags": stories[0]["tags"] = ["missing-tag"]
            case "requiredHabit": stories[0]["requires"] = ["habit": "adventurous"]
            case "fulfilledHabit": stories[0]["fulfillsHabit"] = "adventurous"
            case "replyHabit":
                var replies = stories[0]["replies"] as! [[String: Any]]
                replies[0]["habit"] = "adventurous"
                stories[0]["replies"] = replies
            case "storySeason": stories[0]["requires"] = ["season": "monsoon"]
            case "storyFulfills": stories[0]["fulfills"] = ["missing-reply"]
            default:
                var replies = stories[0]["replies"] as! [[String: Any]]
                replies.append(replies[0])
                stories[0]["replies"] = replies
            }
        }
        let expected = ["requiredHabit", "fulfilledHabit", "replyHabit"].contains(rule) ? "storyHabit" : rule
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == expected })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: ["text", "lead", "reply"], ["missing-zh", "blank-zh", "missing-en", "blank-en"])
    func everyLocalizedFieldRequiresBothNonemptyLanguages(field: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            let language = failure.hasSuffix("zh") ? "zh-Hans" : "en"
            var texts = ["zh-Hans": "小事一桩", "en": "A small thing"]
            texts[language] = failure.hasPrefix("missing") ? nil : " \n "
            if field == "reply" {
                var replies = stories[0]["replies"] as! [[String: Any]]
                replies[0]["text"] = texts
                stories[0]["replies"] = replies
            } else { stories[0][field] = texts }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyTranslation" })
    }

    @Test(arguments: ["mismatch", "unknown", "malformed", "target", "reply", "splice", "possessive"])
    func slotsAreMatchedAllowedContextualAndWholeWords(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            let text = switch failure {
            case "unknown": "{weather}"
            case "malformed": "{{pet}"
            case "target": "{target}"
            case "reply": "{reply}"
            case "splice": "{pet}s"
            case "possessive": "{pet}'s letter"
            default: "{pet}"
            }
            stories[0]["text"] = ["zh-Hans": text, "en": failure == "mismatch" ? "no slots" : text]
        }
        let expected = ["target": "storyTarget", "reply": "storyReply", "splice": "storySlotGrammar", "possessive": "storySlotGrammar"][failure] ?? "storySlots"
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == expected })
    }

    @Test(arguments: ["arrival", "transit", "talkative", "observant"])
    func missingGenericFallbacksAreRejected(category: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            stories.removeAll { ($0["kind"] as? String) == category || ($0["fulfillsHabit"] as? String) == category }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyBaseline" && $0.message.contains(category) })
    }

    @Test(arguments: ["talkative", "observant"])
    func dedicatedFulfillmentsCannotReplaceTheUnconditionalHabitFallback(habit: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editStories { stories in
            let replyId = (stories[0]["replies"] as! [[String: Any]])[0]["id"] as! String
            for index in stories.indices where stories[index]["fulfillsHabit"] as? String == habit {
                stories[index]["fulfills"] = [replyId]
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyBaseline" && $0.message.contains(habit) })
    }

    @Test(arguments: ["missing", "malformed", "object", "wrong-requirement-type"])
    func brokenStoryFilesUseTheExistingContentFailurePath(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("stories/generic.json")
        switch failure {
        case "missing": try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        case "malformed": try Data("[".utf8).write(to: file)
        case "object": try Data("{}".utf8).write(to: file)
        default: try box.editStories { $0[0]["requires"] = ["rainySeason": "sometimes"] }
        }
        #expect(!ContentValidator.validate(directory: box.directory).isEmpty)
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: [0, 13])
    func rainyMonthsMustBeInCalendarRange(month: Int) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit { $0["rainyMonths"] = [month] }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "rainyMonths" })
    }

    @Test func storyIdsAreUniqueAcrossFilesAndFactsBelongToTheirOwnCity() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let original = try Data(contentsOf: box.directory.appendingPathComponent("stories/generic.json"))
        let second = box.directory.appendingPathComponent("stories/second.json")
        try original.write(to: second)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyID" })
        try FileManager.default.removeItem(at: second)
        try box.edit { $0["facts"] = [["id": "window", "type": "place", "names": ["zh-Hans": "窗", "en": "Window"], "sources": ["https://en.wikipedia.org/wiki/Window"]]] }
        var story = engineStory("local.fact", city: "shanghai")
        story.factIds = ["window"]
        try JSONEncoder().encode([story]).write(to: second)
        #expect(ContentValidator.validate(directory: box.directory).isEmpty)
        story.cityId = "xian"
        try JSONEncoder().encode([story]).write(to: second)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "storyFacts" })
    }
}
