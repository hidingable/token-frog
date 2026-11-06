import Foundation

public enum CareEngine {
    public static func process(
        journey: inout JourneyState, care: inout CareState, stories: StoryLibrary,
        catalog: CityCatalog, wishTags: Set<String> = []
    ) {
        let indices = journey.letters.indices.sorted { journey.letters[$0].id < journey.letters[$1].id }
        for index in indices {
            var letter = journey.letters[index]
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
                    dueReply: due ? reply : nil, recent: recent, seed: journey.seed
                )
                snapshot(story, letter: &letter, petName: care.petName, reply: due ? reply : nil, catalog: catalog)
                if due { letter.fulfilledReplyId = promise!.replyId }
                journey.letters[index] = letter
            }

            // A saved story is authoritative even if the content pack has since changed.
            // Replaying only the care side repairs a crash between the two atomic save writes.
            if let fulfilled = letter.fulfilledReplyId, let promise, promise.replyId == fulfilled {
                care.pendingPromises.removeFirst()
                care.memories.append(.init(kind: "fulfilled", date: letter.date, letterId: letter.id, replyId: fulfilled))
            }
            care.processedLetterIds.append(letter.id)
        }
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

    public static func markCompanion(date: String, care: inout CareState) {
        if !care.companionDays.contains(date) { care.companionDays.append(date) }
    }

    private static func promiseDelay(_ promise: CareState.Promise, seed: UInt32, care: CareState) -> Int {
        if !care.memories.contains(where: { $0.kind == "fulfilled" }) { return 1 }
        var random = SplitMix64(seed: seed, stopCount: promise.letterId)
        return Int(random.next() % 3) + 1
    }

    private static func choose(
        letter: Letter, care: CareState, stories: StoryLibrary, catalog: CityCatalog, wishTags: Set<String>,
        dueReply: StoryReply?, recent: Set<String>, seed: UInt32
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
            // A city payoff must not fulfill early merely because it also matches a tool or wish.
            let ordinary = eligible.filter { $0.kind == kind && $0.fulfills.isEmpty }
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
        if let item = requires.item, item != care.bag.todayItem { return false }
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
        letter.texts = render(story.text)
        letter.leadTexts = story.lead.map(render) ?? [:]
        letter.replyOptions = story.replies.map { option in
            var option = option
            option.text = render(option.text)
            return option
        }
        letter.facts = story.factIds.map { id in
            let fact = city.facts.first { $0.id == id }!
            return .init(id: fact.id, names: fact.names, sources: fact.sources)
        }
        // Rewards are introduced in the next step; content cannot grant them yet.
        letter.rewards = StoryRewards()
    }
}
