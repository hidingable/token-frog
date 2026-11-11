import Foundation

public struct ContentIssue: Equatable, Sendable {
    public let file: String
    public let rule: String
    public let message: String
}

public struct ContentValidationError: Error, Sendable {
    public let issues: [ContentIssue]
}

public enum ContentValidator {
    private struct Manifest: Decodable {
        let formatVersion: Int
        let packVersion: Int
        let minAppVersion: String
    }

    static func parseManifest(directory: URL) throws {
        _ = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    static func cityFiles(directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("cities"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readCities(directory: URL) throws -> [(file: URL, city: City)] {
        try cityFiles(directory: directory).map { ($0, try JSONDecoder().decode(City.self, from: Data(contentsOf: $0))) }
    }

    static func readCountries(directory: URL) throws -> [String: [String: String]] {
        try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: directory.appendingPathComponent("countries.json")))
    }

    static func storyFiles(directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("stories"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readStories(directory: URL) throws -> [(file: URL, stories: [Story])] {
        try storyFiles(directory: directory).map { ($0, try JSONDecoder().decode([Story].self, from: Data(contentsOf: $0))) }
    }

    static func itemFiles(directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("items"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readItems(directory: URL) throws -> [(file: URL, items: [Item])] {
        try itemFiles(directory: directory).map { ($0, try JSONDecoder().decode([Item].self, from: Data(contentsOf: $0))) }
    }

    static func readBoxes(directory: URL) throws -> BoxContents {
        try JSONDecoder().decode(BoxContents.self, from: Data(contentsOf: directory.appendingPathComponent("boxes.json")))
    }

    public static func validate(directory: URL) -> [ContentIssue] {
        var issues = validatePets(directory: directory)
        // Inspect raw JSON before Codable can discard unknown fields. Bundled content is never sponsored.
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "json" {
                if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)), containsSponsor(object) {
                    issues.append(ContentIssue(file: file.path.replacingOccurrences(of: directory.path + "/", with: ""),
                                               rule: "sponsor", message: "Sponsor fields are not allowed in bundled content"))
                }
            }
        }
        do { _ = try EncounterPostcardContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "encounter-postcards.json", rule: "encounterPostcards", message: "Invalid encounter postcards: \(error)")) }
        do { _ = try WeeklyMailContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "weekly-mail.json", rule: "weeklyMail", message: "Invalid weekly mail: \(error)")) }
        do { _ = try WishContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "wish.json", rule: "wish", message: "Invalid wish content: \(error)")) }
        do { _ = try RoadClueContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "road-clues.json", rule: "roadClues", message: "Invalid road clues: \(error)")) }
        do { _ = try UsageEventContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "usage-events.json", rule: "usageEvents", message: "Invalid usage events: \(error)")) }
        do { _ = try PetMomentContent.load(directory: directory) }
        catch { issues.append(ContentIssue(file: "pet-moments.json", rule: "petMoments", message: "Invalid pet moments: \(error)")) }
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        let decoder = JSONDecoder()
        let regions = Set(Locale.Region.isoRegions.map(\.identifier))
        func complete(_ names: [String: String]) -> Bool {
            ["zh-Hans", "en"].allSatisfy { !(names[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        do {
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            if manifest.formatVersion != 1 || manifest.packVersion < 1
                || manifest.minAppVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil {
                report("manifest.json", "manifest", "Unsupported or invalid manifest fields")
            }
        } catch { report("manifest.json", "manifest", "Cannot read a complete manifest: \(error)") }

        var tags: Set<String> = []
        do {
            let values = try decoder.decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("tags.json")))
            tags = Set(values)
            if tags.isEmpty || tags.count != values.count || tags.contains("") {
                report("tags.json", "tags", "Tags must be nonempty and unique")
            }
        } catch { report("tags.json", "tags", "Cannot read tags: \(error)") }

        var countries: [String: [String: String]] = [:]
        do {
            countries = try readCountries(directory: directory)
            for code in countries.keys.sorted() {
                if !regions.contains(code) || code.count != 2 {
                    report("countries.json", "countryCode", "Invalid ISO region code: \(code)")
                }
                if !complete(countries[code]!) {
                    report("countries.json", "countryNames", "Country \(code) requires zh-Hans and en names")
                }
            }
        } catch { report("countries.json", "countries", "Cannot read country names: \(error)") }

        var published: Set<String> = []
        do {
            let text = try String(contentsOf: directory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
            published = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        } catch { report("published-ids.txt", "published", "Cannot read published IDs: \(error)") }

        let files: [URL]
        do { files = try cityFiles(directory: directory) }
        catch {
            report("cities", "cities", "Cannot read cities: \(error)")
            return issues
        }
        var ids: Set<String> = []
        var cities: [String: City] = [:]
        let continents: Set<String> = ["asia", "europe", "africa", "north-america", "south-america", "oceania"]
        var entries: [(path: String, city: City, detail: Bool)] = []
        do {
            entries += try CityContent.readBase(directory: directory).map { ("world/cities.tsv", $0, false) }
        } catch { report("world/cities.tsv", "cityTSV", "Cannot read base cities: \(error)") }
        for file in files {
            do { entries.append(("cities/\(file.lastPathComponent)", try decoder.decode(City.self, from: Data(contentsOf: file)), true)) }
            catch { report("cities/\(file.lastPathComponent)", "cityJSON", "Cannot decode city: \(error)") }
        }
        var baseIDs: Set<String> = []
        var detailIDs: Set<String> = []
        var detailWikis: Set<String> = []
        for (path, city, detail) in entries {
            if city.id.isEmpty || (detail && path != "cities/\(city.id).json") {
                report(path, "filename", "Filename must equal the city ID")
            }
            let unique = detail ? detailIDs.insert(city.id).inserted : baseIDs.insert(city.id).inserted
            if !unique { report(path, "uniqueID", "Duplicate city ID") }
            if let wiki = city.wikidata {
                if wiki.range(of: #"^q[1-9][0-9]*$"#, options: .regularExpression) == nil {
                    report(path, "wikidata", "Invalid Wikidata ID")
                }
                if detail && !detailWikis.insert(wiki).inserted { report(path, "uniqueID", "Duplicate Wikidata identity") }
            }
            if !detail && city.id != city.wikidata { report(path, "wikidata", "Base ID must equal Wikidata ID") }
            if !(1...4).contains(city.tier) { report(path, "tier", "Tier must be in 1...4") }
            ids.insert(city.id)
            cities[city.id] = city
            if !city.rainyMonths.allSatisfy({ (1...12).contains($0) }) {
                report(path, "rainyMonths", "Rainy months must be in 1...12")
            }
            if !["active", "retired"].contains(city.status) { report(path, "status", "Invalid city status") }
            if !["basic", "facts", "full"].contains(city.level) { report(path, "level", "Invalid city level") }
            if !continents.contains(city.continent) { report(path, "continent", "Invalid continent") }
            if !(-90...90).contains(city.lat) || !(-180...180).contains(city.lon) {
                report(path, "coordinate", "Coordinates are out of range")
            }
            if !regions.contains(city.countryCode) || city.countryCode.count != 2 {
                report(path, "countryCode", "Invalid ISO region code")
            } else if countries[city.countryCode] == nil {
                report(path, "countryCode", "Country code is missing from countries.json: \(city.countryCode)")
            }
            if ((detail || city.level != "basic") && city.tags.isEmpty) || !Set(city.tags).isSubset(of: tags) { report(path, "cityTags", "Missing or unknown city tags") }
            if !complete(city.names) { report(path, "names", "City names require zh-Hans and en") }
            if city.names["zh-Hans"]?.range(of: #"\p{Han}"#, options: .regularExpression) == nil {
                report(path, "names", "Chinese names require a Han character")
            }
            if (detail || city.level != "basic") && !complete(city.wikipedia) { report(path, "wikipedia", "Wikipedia titles require zh-Hans and en") }
            var facts: Set<String> = []
            for fact in city.facts {
                if fact.id.isEmpty || !facts.insert(fact.id).inserted { report(path, "factID", "Fact IDs must be nonempty and unique within a city") }
                if !complete(fact.names) { report(path, "factNames", "Fact names require zh-Hans and en") }
                if city.level != "basic", !complete(fact.summary ?? [:]) {
                    report(path, "factSummary", "Non-basic city facts require zh-Hans and en summaries")
                }
                if fact.sources.isEmpty || !fact.sources.allSatisfy(validSource) { report(path, "factSources", "Facts require a public HTTPS source") }
            }
        }
        for id in published.subtracting(ids).sorted() { report("published-ids.txt", "publishedMissing", "Published city is missing: \(id)") }
        for id in ids.subtracting(published).sorted() { report("published-ids.txt", "unpublished", "City is not registered: \(id)") }
        let itemValidation = validateItems(directory: directory, cities: cities, icons: Set((try? PetCatalog.readIcons(directory: directory))?.keys.map { $0 } ?? []))
        issues += itemValidation.issues
        issues += validateBoxes(directory: directory, items: itemValidation.items)
        issues += validateStories(directory: directory, cities: cities, tags: tags, items: itemValidation.items)
        return issues
    }

    private static func validateItems(directory: URL, cities: [String: City], icons: Set<String>) -> (items: [String: Item], issues: [ContentIssue]) {
        var issues: [ContentIssue] = []
        var items: [String: Item] = [:]
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        let files: [URL]
        do { files = try itemFiles(directory: directory) }
        catch { return (items, [ContentIssue(file: "items", rule: "items", message: "Cannot read items: \(error)")]) }
        for file in files {
            let path = "items/\(file.lastPathComponent)"
            let entries: [Item]
            do { entries = try JSONDecoder().decode([Item].self, from: Data(contentsOf: file)) }
            catch { report(path, "itemJSON", "Cannot decode items: \(error)"); continue }
            for item in entries {
                if item.id.isEmpty || items[item.id] != nil { report(path, "itemID", "Item IDs must be nonempty and unique: \(item.id)") }
                items[item.id] = item
                issues += validate(item: item, cities: cities, icons: icons).map { ContentIssue(file: path, rule: $0.rule, message: $0.message) }
            }
        }
        // These fixed bag habits also determine which bonus a saved itemTriggered flag replays.
        let bags: [(id: String, habit: String?)] = [
            ("sketchbook", "observant"), ("note-slip", "talkative"), ("raincoat", nil),
            ("old-camera", "observant"), ("lunchbox", "talkative"),
        ]
        for bag in bags {
            if let item = items[bag.id], item.kind == "bag" {
                if item.habit != bag.habit { report("items", "itemHabit", "Incorrect habit for fixed bag item: \(bag.id)") }
            } else {
                report("items", "bagBaseline", "Missing bag item: \(bag.id)")
            }
        }
        for rarity in ["common", "uncommon", "rare"] where !items.values.contains(where: { $0.kind == "souvenir" && $0.source == nil && $0.cityId == nil && $0.rarity == rarity }) {
            report("items", "itemBaseline", "Missing generic \(rarity) souvenir")
        }
        for rarity in ["common", "uncommon", "rare"] where !items.values.contains(where: { $0.source == "postcard" && $0.rarity == rarity }) {
            report("items", "postcardBaseline", "Missing postcard souvenir for \(rarity)")
        }
        if !items.values.contains(where: { $0.source == "reunion" }) {
            report("items", "reunionBaseline", "Missing reunion gift")
        }
        return (items, issues)
    }

    /// Shared semantic checks for bundled and untrusted remote items.
    static func validate(item: Item, cities: [String: City], icons: Set<String>) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        let path = "items"
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        if let source = item.source, !["box", "postcard", "reunion"].contains(source) || item.kind != "souvenir"
            || (source != "postcard" && item.rarity != "common")
            || (source != "box" && item.cityId != nil) {
            report(path, "itemSource", "Source must be box/postcard/reunion on a souvenir; companion pools must be cityless and box/reunion must be common")
        }
        if item.sponsor != nil && (item.kind != "souvenir" || item.rarity != "common" || item.source != nil) {
            report(path, "itemSponsor", "Partner items must be ordinary common souvenirs")
        }
        if !["bag", "souvenir", "menu"].contains(item.kind) { report(path, "itemKind", "Invalid item kind") }
        if let rarity = item.rarity, !["common", "uncommon", "rare"].contains(rarity) {
            report(path, "itemRarity", "Invalid item rarity")
        }
        if (item.kind == "souvenir" && item.rarity == nil) || (item.kind != "souvenir" && item.rarity != nil) {
            report(path, "itemRarity", "Only souvenirs require a rarity; bag and menu items must have none")
        }
        if let habit = item.habit, item.kind != "bag" || !["talkative", "observant"].contains(habit) {
            report(path, "itemHabit", "Only bag items may have a talkative or observant habit")
        }
        if !icons.contains(item.icon) { report(path, "itemIcon", "Unknown item icon") }
        if let city = item.cityId, cities[city] == nil { report(path, "itemCity", "Unknown item city: \(city)") }
        for texts in [item.names, item.descriptions] {
            if texts.values.contains(where: { $0.contains("{") || $0.contains("}") }) {
                report(path, "itemSlots", "Item names and descriptions are literal text and cannot contain slots")
            }
            if !["zh-Hans", "en"].allSatisfy({ !(texts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                report(path, "itemTranslation", "Item names and descriptions require nonempty zh-Hans and en")
            }
        }
        return issues
    }

    private static func validateBoxes(directory: URL, items: [String: Item]) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        func report(_ rule: String, _ message: String) {
            issues.append(ContentIssue(file: "boxes.json", rule: rule, message: message))
        }
        do {
            let boxes = try readBoxes(directory: directory)
            let ids = boxes.souvenirIds + boxes.bagItemIds
            if Set(ids).count != ids.count { report("boxDuplicate", "Box item IDs must not repeat") }
            for id in boxes.souvenirIds where items[id]?.kind != "souvenir" || items[id]?.source != "box" {
                report("boxSouvenir", "Box souvenirs must reference a souvenir with source box: \(id)")
            }
            for id in boxes.bagItemIds where items[id]?.kind != "bag" {
                report("boxBag", "Box bag items must reference a bag: \(id)")
            }
        } catch { report("boxes", "Cannot read boxes: \(error)") }
        return issues
    }

    private static func validateStories(directory: URL, cities: [String: City], tags: Set<String>, items: [String: Item]) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        let files: [URL]
        do { files = try storyFiles(directory: directory) }
        catch { return [ContentIssue(file: "stories", rule: "stories", message: "Cannot read stories: \(error)")] }
        var entries: [(file: String, story: Story)] = []
        for file in files {
            let path = "stories/\(file.lastPathComponent)"
            do {
                entries += try JSONDecoder().decode([Story].self, from: Data(contentsOf: file)).map { (path, $0) }
            } catch { report(path, "storyJSON", "Cannot decode stories: \(error)") }
        }
        let habits: Set<String> = ["talkative", "observant"]
        let replyIds = Set(entries.flatMap { $0.story.replies.map(\.id) })
        var ids: Set<String> = []
        var seenReplyIds: Set<String> = []
        for (file, story) in entries {
            if story.id.isEmpty || !ids.insert(story.id).inserted { report(file, "storyID", "Story IDs must be nonempty and unique: \(story.id)") }
            for reply in story.replies where !seenReplyIds.insert(reply.id).inserted {
                report(file, "replyID", "Reply IDs must be globally unique: \(reply.id)")
            }
            issues += validate(story: story, cities: cities, tags: tags, items: items, replyIds: replyIds)
                .map { ContentIssue(file: file, rule: $0.rule, message: $0.message) }
        }
        let generic = entries.map(\.story).filter { $0.cityId == nil && $0.requires.isEmpty }
        for city in cities.values.sorted(by: { $0.id < $1.id }) where city.level == "full" {
            if !entries.contains(where: { $0.story.kind == "revisit" && $0.story.cityId == city.id }) {
                report("stories/\(city.id).json", "revisitBaseline", "Full city requires a revisit story: \(city.id)")
            }
        }
        for kind in ["arrival", "transit"] where !generic.contains(where: { $0.kind == kind && $0.fulfills.isEmpty }) {
            report("stories", "storyBaseline", "Missing unconditional generic \(kind) story")
        }
        for kind in ["postcard", "reunion"] where !generic.contains(where: { $0.kind == kind }) {
            report("stories", "companionBaseline", "Missing generic \(kind) story")
        }
        for habit in habits.sorted() where !generic.contains(where: { $0.kind == "fulfill" && $0.fulfills.isEmpty && $0.fulfillsHabit == habit }) {
            report("stories", "storyBaseline", "Missing unconditional generic fulfillment for \(habit)")
        }
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.kind == "bag" && item.habit != nil {
            for kind in ["arrival", "transit"] where !entries.contains(where: {
                let story = $0.story
                let requires = story.requires
                return story.cityId == nil && story.kind == kind && story.fulfills.isEmpty
                    && requires.item == item.id && requires.habit == nil && requires.season == nil
                    && requires.tool == nil && requires.rainySeason == nil
            }) {
                report("stories", "itemStoryBaseline", "Missing unconditional generic \(kind) story for \(item.id)")
            }
        }
        return issues
    }

    /// Shared semantic checks; callers own global ID uniqueness and pack baselines.
    static func validate(story: Story, cities: [String: City], tags: Set<String>, items: [String: Item], replyIds: Set<String>) -> [ContentIssue] {
        var issues: [ContentIssue] = []
        let file = "stories"
        let habits: Set<String> = ["talkative", "observant"]
        let seasons: Set<String> = ["spring", "summer", "autumn", "winter"]
        var seenReplyIds: Set<String> = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        if story.sponsor != nil && (!story.factIds.isEmpty || !["arrival", "transit"].contains(story.kind)) {
            report(file, "storySponsor", "Partner stories must be arrival/transit stories without verified facts")
        }
        if story.version < 1 { report(file, "storyVersion", "Story version must be positive") }
        if !["arrival", "transit", "fulfill", "postcard", "reunion", "revisit"].contains(story.kind) { report(file, "storyKind", "Invalid story kind") }
        if story.kind == "revisit" {
            if story.cityId == nil { report(file, "revisitCity", "Revisit stories require a cityId") }
            if story.lead == nil || story.replies.count != 2 || Set(story.replies.map(\.habit)) != habits {
                report(file, "revisitFormat", "Revisit stories require a lead and one reply per habit")
            }
            if !story.requires.isEmpty || !story.fulfills.isEmpty || story.fulfillsHabit != nil || story.rewards != StoryRewards() {
                report(file, "revisitRules", "Revisit stories are unconditional and use ordinary travel drops")
            }
        }
        let companion = ["postcard", "reunion"].contains(story.kind)
        if companion && (story.cityId != nil || !story.requires.isEmpty || !story.factIds.isEmpty
            || !story.replies.isEmpty || !story.fulfills.isEmpty || story.fulfillsHabit != nil
            || story.lead != nil || story.learned != nil || !story.rewards.itemIds.isEmpty || !story.rewards.menuIds.isEmpty) {
            report(file, "companionStory", "Companion mail must be unconditional, cityless and free of replies, fulfillment and authored rewards")
        }
        if companion && story.memoryLead == nil {
            report(file, "memoryLead", "Companion mail requires an optional memory lead template")
        }
        if !companion && story.memoryLead != nil { report(file, "memoryLead", "Memory leads belong to companion mail") }
        if let id = story.cityId, cities[id] == nil { report(file, "storyCity", "Unknown story city: \(id)") }
        let facts = Set(story.cityId.flatMap { cities[$0] }?.facts.map(\.id) ?? [])
        if !Set(story.factIds).isSubset(of: facts) { report(file, "storyFacts", "Unknown facts in story city") }
        if !Set(story.tags).isSubset(of: tags) { report(file, "storyTags", "Unknown story tags") }
        if let habit = story.requires.habit, !habits.contains(habit) { report(file, "storyHabit", "Invalid required habit") }
        if let habit = story.fulfillsHabit, !habits.contains(habit) { report(file, "storyHabit", "Invalid fulfillment habit") }
        if let season = story.requires.season, !seasons.contains(season) { report(file, "storySeason", "Invalid required season") }
        if let item = story.requires.item, items[item]?.kind != "bag" { report(file, "storyItemRequirement", "Required item must reference a bag item: \(item)") }
        for id in story.rewards.itemIds where items[id]?.kind != "souvenir" || items[id]?.source != nil {
            report(file, "storyItemReward", "Item rewards must reference ordinary travel souvenirs: \(id)")
        }
        for id in story.rewards.menuIds where items[id]?.kind != "menu" {
            report(file, "storyMenuReward", "Menu rewards must reference menus: \(id)")
        }
        if !Set(story.fulfills).isSubset(of: replyIds) { report(file, "storyFulfills", "Unknown fulfilled reply ID") }
        if let learned = story.learned {
            if !["zh-Hans", "en"].allSatisfy({ learned[$0] != nil })
                || learned.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                report(file, "storyLearnedTranslation", "Learned texts require nonempty zh-Hans and en")
            }
            if learned.values.contains(where: { $0.contains("{") || $0.contains("}") }) {
                report(file, "storyLearnedSlots", "Learned texts cannot contain slots")
            }
            if let chinese = learned["zh-Hans"], chinese.count > 16 {
                report(file, "storyLearnedLength", "Chinese learned text must be at most 16 characters")
            }
        }
        for reply in story.replies {
            if reply.id.isEmpty || !seenReplyIds.insert(reply.id).inserted { report(file, "replyID", "Reply IDs must be nonempty and globally unique: \(reply.id)") }
            if !habits.contains(reply.habit) { report(file, "storyHabit", "Invalid reply habit") }
        }
        let localizedTexts = [story.text] + (story.lead.map { [$0] } ?? []) + story.replies.map(\.text) + (story.memoryLead.map { [$0] } ?? [])
        for texts in localizedTexts {
            if !["zh-Hans", "en"].allSatisfy({ texts[$0] != nil })
                || texts.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                report(file, "storyTranslation", "Story, lead and replies require nonempty zh-Hans and en")
            }
            let sets = texts.values.map { StorySlots.names(in: $0) }
            if let first = sets.first, !sets.allSatisfy({ $0 == first }) { report(file, "storySlots", "Slots must match in every language") }
            for text in texts.values {
                let names = StorySlots.names(in: text)
                let stripped = StorySlots.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                let memoryLead = story.memoryLead == texts
                let allowed: Set<String> = companion ? (memoryLead ? ["pet", "memory"] : ["pet"]) : ["pet", "city", "target", "reply"]
                if memoryLead && !names.contains("memory") { report(file, "memoryLead", "Memory lead must quote the memory slot") }
                if !names.isSubset(of: allowed) || stripped.contains("{") || stripped.contains("}") {
                    report(file, "storySlots", "Unknown or malformed slot")
                }
                if names.contains("target") && story.kind != "transit" { report(file, "storyTarget", "Target is only allowed in transit stories") }
                if names.contains("city") && story.kind == "fulfill" && story.cityId == nil {
                    report(file, "storyCitySlot", "Cityless fulfillment stories cannot use the city slot")
                }
                if names.contains("reply") && story.kind != "fulfill" && story.fulfills.isEmpty {
                    report(file, "storyReply", "Reply requires a fulfillment story")
                }
                if text.range(of: #"[A-Za-z0-9_]\{|\}[A-Za-z0-9_]|\}['’]s\b"#, options: .regularExpression) != nil {
                    report(file, "storySlotGrammar", "Slots cannot form part of a word or possessive")
                }
            }
        }
        return issues
    }

    private static func validSource(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let blocked = ["localhost", "example.org", "example.com", "127.0.0.1", "::1", "[::1]"]
        return !blocked.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
