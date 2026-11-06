import Foundation
import Testing
@testable import VoyageCore

extension ContentSandbox {
    func editItems(_ edit: (inout [Item]) -> Void) throws {
        let files = try ContentValidator.itemFiles(directory: directory)
        var items = try ContentValidator.readItems(directory: directory).flatMap(\.items)
        edit(&items)
        for file in files { try FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("items/test.json"))
    }

    func editItemStories(_ edit: (inout [Story]) -> Void) throws {
        let file = directory.appendingPathComponent("stories/items.json")
        var stories = try JSONDecoder().decode([Story].self, from: Data(contentsOf: file))
        edit(&stories)
        try JSONEncoder().encode(stories).write(to: file)
    }
}

@Suite struct ItemContentTests {
    @Test func repositoryContainsTheFiveBagsAndEnoughBilingualGenericSouvenirs() throws {
        #expect(ContentValidator.validate(directory: contentDirectory).isEmpty)
        let library = testCatalog.items
        #expect(library.all.map(\.id) == library.all.map(\.id).sorted())
        let bags = library.all.filter { $0.kind == "bag" }
        #expect(Set(bags.map(\.id)) == ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"])
        for id in ["sketchbook", "old-camera"] { #expect(library.find(id)?.habit == "observant") }
        for id in ["note-slip", "lunchbox"] { #expect(library.find(id)?.habit == "talkative") }
        #expect(library.find("raincoat")?.habit == nil)
        for (rarity, minimum) in [("common", 12), ("uncommon", 6), ("rare", 4)] {
            #expect(library.all.filter { $0.kind == "souvenir" && $0.cityId == nil && $0.rarity == rarity }.count >= minimum)
        }
        #expect(!library.all.contains { $0.kind == "menu" }) // Sourced dishes arrive in step 11.
        for item in library.all {
            #expect(testCatalog.pets.icons[item.icon] != nil)
            for texts in [item.names, item.descriptions] {
                let chinese = try #require(texts["zh-Hans"])
                let english = try #require(texts["en"])
                #expect(!chinese.isEmpty && !english.isEmpty)
                #expect(chinese.range(of: #"\p{Han}"#, options: .regularExpression) != nil)
                #expect(english.range(of: #"\p{Han}"#, options: .regularExpression) == nil)
            }
        }
        #expect(library.find("missing") == nil)
    }

    @Test func everyHabitBagHasArrivalAndTransitStoriesAndRaincoatHasRainStories() {
        let stories = testCatalog.stories.all.filter { $0.requires.item != nil }
        for item in ["sketchbook", "note-slip", "old-camera", "lunchbox"] {
            #expect(stories.filter { $0.requires.item == item && $0.kind == "arrival" }.count >= 3)
            #expect(stories.filter { $0.requires.item == item && $0.kind == "transit" }.count >= 2)
        }
        let rain = stories.filter { $0.requires.item == "raincoat" }
        #expect(rain.filter { $0.kind == "arrival" }.count >= 2)
        #expect(rain.allSatisfy { $0.requires.rainySeason == true })
        for story in stories {
            #expect(story.cityId == nil && story.replies.count == 2)
            #expect(Set(story.replies.map(\.habit)) == ["talkative", "observant"])
            #expect(story.fulfills.isEmpty && story.fulfillsHabit == nil)
        }
    }

    @Test(arguments: ["empty", "same-file", "another-file"])
    func itemIdsMustBeNonemptyAndUnique(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        if failure == "another-file" {
            try JSONEncoder().encode([testCatalog.items.all[0]]).write(to: box.directory.appendingPathComponent("items/duplicate.json"))
        } else {
            try box.editItems { items in
                if failure == "empty" { items[0].id = "" } else { items.append(items[0]) }
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemID" })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }

    @Test(arguments: ["kind", "rarity", "souvenir-rarity", "bag-rarity", "menu-rarity", "habit", "souvenir-habit", "menu-habit", "icon", "city"])
    func invalidItemValuesAndKindSpecificFieldsAreRejected(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            let bag = items.firstIndex { $0.id == "sketchbook" }!
            let souvenir = items.firstIndex { $0.kind == "souvenir" }!
            switch failure {
            case "kind": items[souvenir].kind = "postcard"
            case "rarity": items[souvenir].rarity = "legendary"
            case "souvenir-rarity": items[souvenir].rarity = nil
            case "bag-rarity": items[bag].rarity = "common"
            case "menu-rarity": items.append(engineItem("menu.invalid", kind: "menu"))
            case "habit": items[bag].habit = "curious"
            case "souvenir-habit": items[souvenir].habit = "observant"
            case "menu-habit":
                var menu = engineItem("menu.invalid", kind: "menu", rarity: nil)
                menu.habit = "talkative"
                items.append(menu)
            case "icon": items[souvenir].icon = "unknown"
            default: items[souvenir].cityId = "missing-city"
            }
        }
        let rule = ["kind": "itemKind", "rarity": "itemRarity", "souvenir-rarity": "itemRarity", "bag-rarity": "itemRarity", "menu-rarity": "itemRarity", "habit": "itemHabit", "souvenir-habit": "itemHabit", "menu-habit": "itemHabit", "icon": "itemIcon", "city": "itemCity"][failure]!
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
    }

    @Test(arguments: ["names", "descriptions"], ["missing-zh", "missing-en", "blank-zh", "blank-en"])
    func itemNamesAndDescriptionsRequireBothLanguages(field: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            let language = failure.hasSuffix("zh") ? "zh-Hans" : "en"
            if field == "names" { items[0].names[language] = failure.hasPrefix("missing") ? nil : " \n " }
            else { items[0].descriptions[language] = failure.hasPrefix("missing") ? nil : " \n " }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemTranslation" })
    }

    @Test(arguments: ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"])
    func allFiveBagIdsMustExistWithBagKind(id: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { $0.removeAll { $0.id == id } }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "bagBaseline" && $0.message.contains(id) })
    }

    @Test(arguments: ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"])
    func fixedBagHabitsCannotChangeTheMeaningOfSavedTriggerFlags(id: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            let index = items.firstIndex { $0.id == id }!
            items[index].habit = items[index].habit == "talkative" ? "observant" : "talkative"
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemHabit" && $0.message.contains(id) })
    }

    @Test(arguments: ["common", "uncommon", "rare"])
    func everyRarityRequiresAGenericSouvenir(rarity: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItems { items in
            for index in items.indices where items[index].rarity == rarity { items[index].cityId = "shanghai" }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemBaseline" && $0.message.contains(rarity) })
    }

    @Test(arguments: ["requirement", "item", "menu"], ["missing", "bag", "souvenir", "menu"])
    func storyItemReferencesMustExistAndHaveTheRightKind(field: String, target: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let menu = engineItem("menu.valid", kind: "menu", rarity: nil)
        try JSONEncoder().encode([menu]).write(to: box.directory.appendingPathComponent("items/menu.json"))
        let reference = switch target {
        case "bag": "sketchbook"
        case "souvenir": testCatalog.items.all.first { $0.kind == "souvenir" }!.id
        case "menu": menu.id
        default: "missing-item"
        }
        var story = engineStory("local.reference", city: "shanghai")
        switch field {
        case "requirement": story.requires.item = reference
        case "item": story.rewards.itemIds = [reference]
        default: story.rewards.menuIds = [reference]
        }
        try JSONEncoder().encode([story]).write(to: box.directory.appendingPathComponent("stories/reference.json"))
        let expectedKind = ["requirement": "bag", "item": "souvenir", "menu": "menu"][field]!
        let rule = ["requirement": "storyItemRequirement", "item": "storyItemReward", "menu": "storyMenuReward"][field]!
        let issues = ContentValidator.validate(directory: box.directory)
        if target == expectedKind { #expect(issues.isEmpty) }
        else { #expect(issues.contains { $0.rule == rule }) }
    }

    @Test(arguments: ["arrival", "transit"], ["missing", "habit", "season", "tool", "rain", "city", "fulfills"])
    func habitItemFallbacksMustWorkWithoutAdditionalConditions(kind: String, failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.editItemStories { stories in
            if failure == "missing" { stories.removeAll { $0.requires.item == "sketchbook" && $0.kind == kind } }
            else {
                for index in stories.indices where stories[index].requires.item == "sketchbook" && stories[index].kind == kind {
                    switch failure {
                    case "habit": stories[index].requires.habit = "observant"
                    case "season": stories[index].requires.season = "autumn"
                    case "tool": stories[index].requires.tool = "codex"
                    case "rain": stories[index].requires.rainySeason = true
                    case "city": stories[index].cityId = "shanghai"
                    default: stories[index].fulfills = [testCatalog.stories.all.first!.replies[0].id]
                    }
                }
            }
        }
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "itemStoryBaseline" && $0.message.contains(kind) && $0.message.contains("sketchbook") })
    }

    @Test(arguments: ["missing", "malformed", "object", "wrong-type"])
    func brokenItemFilesFailCatalogLoading(failure: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        if failure == "missing" { try FileManager.default.removeItem(at: box.directory.appendingPathComponent("items")) }
        else {
            let content = failure == "malformed" ? "[" : failure == "object" ? "{}" : "[{\"id\":42}]"
            try Data(content.utf8).write(to: box.directory.appendingPathComponent("items/broken.json"))
        }
        let rule = failure == "missing" ? "items" : "itemJSON"
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == rule })
        #expect(throws: ContentValidationError.self) { try validateContent(directory: box.directory) }
    }
}
