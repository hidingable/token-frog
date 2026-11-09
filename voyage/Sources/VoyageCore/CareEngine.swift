import Foundation

public enum CareEngine {
    public static func process(
        journey: inout JourneyState, care: inout CareState, stories: StoryLibrary,
        catalog: CityCatalog, wishTags: Set<String> = []
    ) {
        let indices = journey.letters.indices.sorted { journey.letters[$0].id < journey.letters[$1].id }
        for index in indices {
            var letter = journey.letters[index]
            if [.postcard, .reunion].contains(letter.kind) {
                guard !care.processedLetterIds.contains(letter.id) else { continue }
                if letter.storyId == nil {
                    snapshotCompanionMail(letter: &letter, journey: journey, care: care, stories: stories, catalog: catalog)
                    journey.letters[index] = letter
                }
                applyRewards(letter, care: &care)
                care.processedLetterIds.append(letter.id)
                continue
            }
            guard letter.kind == .daily, !care.processedLetterIds.contains(letter.id) else { continue }
            // Migrated daily letters remain template letters, without retroactive replies or effects.
            guard letter.texts != nil || letter.storyId != nil else {
                care.processedLetterIds.append(letter.id)
                continue
            }

            let promise = care.pendingPromises.first.flatMap { $0.letterId < letter.id ? $0 : nil }
            if promise != nil { care.pendingPromises[0].attempts += 1 }
            let due = promise.map {
                care.pendingPromises[0].attempts >= promiseDelay($0, seed: journey.seed, care: care)
            } ?? false

            if letter.storyId == nil {
                letter.carriedItem = carriedItem(bag: care.bag, seed: journey.seed, letterId: letter.id)
                let trigger = itemTrigger(seed: journey.seed, letterId: letter.id)
                if let cityId = letter.arrivals.last(where: { id in stories.all.contains { $0.cityId == id } })
                    ?? letter.arrivals.last {
                    letter.cityId = cityId
                }
                let reply = promise.flatMap { promise in
                    journey.letters.first { $0.id == promise.letterId }?.replyOptions.first { $0.id == promise.replyId }
                }
                let recent = Set(journey.letters.filter { $0.id < letter.id }.sorted { $0.id < $1.id }.suffix(10).compactMap(\.storyId))
                let story = choose(
                    letter: letter, care: care, stories: stories, catalog: catalog, wishTags: wishTags,
                    dueReply: due ? reply : nil, itemTrigger: trigger, recent: recent, seed: journey.seed,
                    hasPriorStay: journey.letters.contains {
                        $0.kind == .daily && $0.date < letter.date && !$0.arrivals.isEmpty && $0.cityId == letter.cityId
                    }
                )
                snapshot(story, letter: &letter, petName: care.petName, reply: due ? reply : nil, catalog: catalog)
                for note in letter.usageEventNotes ?? [] {
                    for language in Language.allCases {
                        letter.texts?[language.rawValue, default: ""] += "\n\n" + note.texts[language.rawValue]!
                    }
                }
                if due { letter.fulfilledReplyId = promise!.replyId }
                letter.itemTriggered = trigger && !due && letter.carriedItem.flatMap { catalog.items.find($0)?.habit } != nil
                letter.rewards = catalog.items.drop(rewards: story.rewards, letter: letter, care: care, seed: journey.seed)
                if let wish = care.wishResolution, care.wish != nil, wish.tags.isEmpty, wish.explanationLetterId == nil {
                    for language in Language.allCases {
                        letter.texts?[language.rawValue, default: ""] += "\n\n" + catalog.wishes.unmatched[language.rawValue]!
                    }
                    letter.wishExplanationAt = wish.parsedAt
                }
                journey.letters[index] = letter
            }

            // A saved story is authoritative even if the content pack has since changed.
            // Replaying only the care side repairs a crash between the two atomic save writes.
            if letter.isRevisit == true, let storyId = letter.storyId,
               !(care.toldRevisitStoryIds ?? []).contains(storyId) {
                care.toldRevisitStoryIds = (care.toldRevisitStoryIds ?? []) + [storyId]
            }
            if let explainedAt = letter.wishExplanationAt, explainedAt == care.wishResolution?.parsedAt {
                care.wishResolution?.explanationLetterId = letter.id
            }
            if let fulfilled = letter.fulfilledReplyId, let promise, promise.replyId == fulfilled {
                care.pendingPromises.removeFirst()
                care.memories.append(.init(kind: "fulfilled", date: letter.date, letterId: letter.id, replyId: fulfilled))
            }
            if letter.itemTriggered == true, let item = letter.carriedItem, let habit = catalog.items.find(item)?.habit {
                if habit == "talkative" {
                    care.habits.talkative = min(100, care.habits.talkative + 3)
                } else {
                    care.habits.observant = min(100, care.habits.observant + 3)
                }
            }
            applyRewards(letter, care: &care)
            care.bag.todayItem = nil
            care.processedLetterIds.append(letter.id)
        }
        MemoryBook.backfill(journey: journey, care: &care)
    }

    @discardableResult
    public static func reply(
        letterId: Int, replyId: String, date: String, journey: inout JourneyState, care: inout CareState
    ) -> Bool {
        guard let index = journey.letters.firstIndex(where: { $0.id == letterId }),
              journey.letters[index].selectedReplyId == nil,
              let option = journey.letters[index].replyOptions.first(where: { $0.id == replyId }) else { return false }
        if option.habit == "talkative" {
            care.habits.talkative = min(100, care.habits.talkative + 10)
        } else {
            care.habits.observant = min(100, care.habits.observant + 10)
        }
        journey.letters[index].selectedReplyId = replyId
        care.pendingPromises.append(.init(replyId: replyId, letterId: letterId))
        care.memories.append(.init(kind: "reply", date: date, letterId: letterId, replyId: replyId))
        return true
    }

    public struct Learned: Equatable, Sendable {
        public var letterId: Int
        public var learnedTexts: [String: String]
    }

    public static func recentLearned(journey: JourneyState, limit: Int) -> [Learned] {
        journey.letters.filter { !$0.learnedTexts.isEmpty }.sorted { $0.id > $1.id }
            .prefix(max(0, limit)).map { Learned(letterId: $0.id, learnedTexts: $0.learnedTexts) }
    }

    static func itemTrigger(seed: UInt32, letterId: Int) -> Bool {
        var random = SplitMix64(seed: seed, stopCount: letterId, salt: .itemTrigger)
        return random.next() % 2 == 0
    }

    private static func carriedItem(bag: CareState.Bag, seed: UInt32, letterId: Int) -> String? {
        if let chosen = bag.todayItem, bag.owned.contains(chosen) { return chosen }
        let owned = bag.owned.sorted()
        guard !owned.isEmpty else { return nil }
        var random = SplitMix64(seed: seed, stopCount: letterId, salt: .carriedItem)
        return owned[Int(random.next() % UInt64(owned.count))]
    }

    private static func applyRewards(_ letter: Letter, care: inout CareState) {
        // No rarity stamp means this is an older story snapshot: never backfill its drop.
        if let rarity = letter.rewards.dropRarity {
            if letter.kind != .reunion { care.pity = rarity == "rare" ? 0 : care.pity + 1 }
            if let city = letter.rewards.duplicateClueCityId {
                care.trailClues[city, default: 0] += 1
            } else {
                for id in letter.rewards.itemIds where !care.souvenirs.contains(where: { $0.id == id }) {
                    care.souvenirs.append(.init(id: id, letterId: letter.id, shelved: false))
                }
            }
        }
        for id in letter.rewards.menuIds where !care.menus.contains(where: { $0.id == id }) {
            care.menus.append(.init(id: id, letterId: letter.id))
        }
    }

    private static func promiseDelay(_ promise: CareState.Promise, seed: UInt32, care: CareState) -> Int {
        if !care.memories.contains(where: { $0.kind == "fulfilled" }) { return 1 }
        var random = SplitMix64(seed: seed, stopCount: promise.letterId)
        return Int(random.next() % 3) + 1
    }

    private static func choose(
        letter: Letter, care: CareState, stories: StoryLibrary, catalog: CityCatalog, wishTags: Set<String>,
        dueReply: StoryReply?, itemTrigger: Bool, recent: Set<String>, seed: UInt32, hasPriorStay: Bool
    ) -> Story {
        let kind = letter.arrivals.isEmpty ? "transit" : "arrival"
        let city = catalog.city(letter.cityId)
        let eligible = stories.all.filter {
            ($0.cityId == nil || $0.cityId == city.id) && satisfies($0.requires, letter: letter, care: care, city: city)
        }
        var tiers: [[Story]] = []
        if let reply = dueReply {
            tiers += [
                eligible.filter { $0.cityId == city.id && $0.fulfills.contains(reply.id) },
                eligible.filter { $0.cityId == nil && $0.fulfills.contains(reply.id) },
                eligible.filter { $0.cityId == nil && $0.kind == "fulfill" && $0.fulfills.isEmpty && $0.fulfillsHabit == reply.habit },
                eligible.filter { $0.cityId == nil && $0.kind == "fulfill" && $0.fulfills.isEmpty && $0.fulfillsHabit != nil },
            ]
        } else {
            if !letter.arrivals.isEmpty, hasPriorStay,
               let revisit = RevisitStories.next(in: city.id, care: care, library: stories) {
                tiers.append([revisit])
            }
            // A city payoff must not fulfill early merely because it also matches a tool or wish.
            let matching = eligible.filter { $0.kind == kind && $0.fulfills.isEmpty }
            if itemTrigger {
                tiers += [
                    matching.filter { $0.requires.item != nil && $0.cityId == city.id },
                    matching.filter { $0.requires.item != nil && $0.cityId == nil },
                ]
            }
            let ordinary = matching.filter { $0.requires.item == nil }
            tiers += [
                ordinary.filter { $0.requires.tool != nil || $0.requires.season != nil || $0.requires.rainySeason != nil },
                ordinary.filter { $0.requires.habit != nil },
                ordinary.filter { !wishTags.isDisjoint(with: $0.tags) },
                ordinary.filter { $0.cityId == city.id && $0.requires.isEmpty },
                ordinary.filter { $0.cityId == nil && $0.requires.isEmpty },
            ]
        }
        let tier = tiers.first { !$0.isEmpty }!
        let unseen = tier.filter { !recent.contains($0.id) }
        let candidates = (unseen.isEmpty ? tier : unseen).sorted { $0.id < $1.id }
        var random = SplitMix64(seed: seed, stopCount: letter.id)
        return candidates[Int(random.next() % UInt64(candidates.count))]
    }

    private static func satisfies(_ requires: Story.Requirements, letter: Letter, care: CareState, city: City) -> Bool {
        if let habit = requires.habit {
            let value = habit == "talkative" ? care.habits.talkative : care.habits.observant
            if value < 10 { return false }
        }
        if let item = requires.item, item != letter.carriedItem { return false }
        if let tool = requires.tool, tool != letter.vehicles.first?.client { return false }
        let month = Int(letter.date.split(separator: "-")[1])!
        if let expected = requires.season {
            let seasons = ["winter", "spring", "summer", "autumn"]
            let index = (month % 12 / 3 + (city.lat < 0 ? 2 : 0)) % 4
            if seasons[index] != expected { return false }
        }
        if let rainy = requires.rainySeason, city.rainyMonths.contains(month) != rainy { return false }
        return true
    }

    private static func snapshot(_ story: Story, letter: inout Letter, petName: String, reply: StoryReply?, catalog: CityCatalog) {
        let city = catalog.city(letter.cityId)
        func render(_ texts: [String: String]) -> [String: String] {
            texts.reduce(into: [:]) { result, entry in
                let (language, template) = entry
                func localized(_ texts: [String: String]) -> String {
                    texts[language] ?? texts["en"] ?? texts["zh-Hans"] ?? ""
                }
                result[language] = StorySlots.render(template, values: [
                    "pet": petName,
                    "city": localized(city.names),
                    "target": localized(catalog.city(letter.transitTargetId ?? letter.cityId).names),
                    "reply": reply.map { localized($0.text) } ?? "",
                ])
            }
        }
        letter.storyId = story.id
        letter.storyVersion = story.version
        letter.isRevisit = story.kind == "revisit" ? true : nil
        letter.texts = render(story.text)
        letter.leadTexts = story.lead.map(render) ?? [:]
        letter.learnedTexts = story.learned ?? [:]
        letter.replyOptions = story.replies.map { option in
            var option = option
            option.text = render(option.text)
            return option
        }
        letter.facts = story.factIds.map { id in
            let fact = city.facts.first { $0.id == id }!
            return .init(id: fact.id, names: fact.names, sources: fact.sources, summary: fact.summary)
        }
    }
}
