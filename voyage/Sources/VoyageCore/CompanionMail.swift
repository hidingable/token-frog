import Foundation

extension CareEngine {
    /// Called for a real main-window open, never by usage collection or catch-up.
    public static func open(
        at now: Date, journey: inout JourneyState, care: inout CareState,
        catalog: CityCatalog, calendar: Calendar = .current, sponsorContentEnabled: Bool = false
    ) {
        let date = DayKey.string(from: now, calendar: calendar)
        guard date >= journey.startDate, date > (journey.lastOpenedDate ?? "") else { return }
        if let previous = journey.lastOpenedDate,
           let from = DayKey.date(from: previous, calendar: calendar),
           let to = DayKey.date(from: date, calendar: calendar),
           let days = calendar.dateComponents([.day], from: from, to: to).day, days >= 3 {
            appendCompanionMail(.reunion, date: date, now: now, journey: &journey, care: care, catalog: catalog)
        }
        journey.lastOpenedDate = date
        journey.days[date, default: DayRecord()].mainWindowOpened = true
        process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog,
                sponsorContentEnabled: sponsorContentEnabled, calendar: calendar)
    }

    private static func appendCompanionMail(
        _ kind: Letter.Kind, date: String, now: Date, journey: inout JourneyState,
        care: CareState, catalog: CityCatalog
    ) {
        let id = journey.nextLetterID
        var letter = Letter(
            id: id, kind: kind, date: date, pet: journey.pet, cityId: journey.currentCityId,
            arrivals: [], newCountries: [], fuel: 0, vehicles: [], isDeepVisit: false,
            deliverAt: now, enrichmentDone: true
        )
        snapshotCompanionMail(letter: &letter, journey: journey, care: care, stories: catalog.stories, catalog: catalog)
        journey.letters.append(letter)
    }

    static func snapshotCompanionMail(letter: inout Letter, journey: JourneyState, care: CareState, stories: StoryLibrary, catalog: CityCatalog) {
        let id = letter.id, date = letter.date, kind = letter.kind
        // A stable date key, unlike Swift's process-randomized Hasher.
        let datedSeed = date.utf8.reduce(journey.seed) { ($0 &* 31) &+ UInt32($1) }
        var random = SplitMix64(seed: datedSeed, stopCount: id)
        let recent = Set(journey.letters.filter { $0.id < id }.suffix(10).compactMap(\.storyId))
        let pool = stories.all.filter { $0.kind == kind.rawValue && $0.sponsor == nil }
        let unseen = pool.filter { !recent.contains($0.id) }
        let candidates = unseen.isEmpty ? pool : unseen
        let story = candidates[Int(random.next() % UInt64(candidates.count))]
        func render(_ texts: [String: String], memory: [String: String] = [:]) -> [String: String] {
            texts.reduce(into: [:]) { result, entry in
                // Leads supply their own sentence punctuation outside the quotation.
                var quote = (memory[entry.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                while let last = quote.last, ".。".contains(last) { quote.removeLast() }
                result[entry.key] = StorySlots.render(entry.value, values: [
                    "pet": care.petName, "memory": quote,
                ])
            }
        }
        letter.storyId = story.id
        letter.storyVersion = story.version
        letter.texts = render(story.text)
        let memories = care.memories.filter { ["reply", "fulfilled"].contains($0.kind) && $0.date <= date }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.letterId != $1.letterId { return $0.letterId > $1.letterId }
                return $0.kind < $1.kind
            }.compactMap { memory -> (CareState.Memory, [String: String])? in
                guard let source = journey.letters.first(where: { $0.id == memory.letterId }),
                      source.deliverAt <= letter.deliverAt, !source.hasSponsoredContent else { return nil }
                let texts = memory.kind == "fulfilled" ? source.learnedTexts
                    : source.replyOptions.first { $0.id == memory.replyId }?.text ?? [:]
                guard ["zh-Hans", "en"].allSatisfy({ texts[$0]?.isEmpty == false }) else { return nil }
                return (memory, texts)
            }
        if let lead = story.memoryLead, !memories.isEmpty {
            let (reference, texts) = memories[Int(random.next() % UInt64(memories.count))]
            letter.memoryReference = reference
            letter.leadTexts = render(lead, memory: texts)
        }
        let rarity = kind == .postcard ? ItemDropRules.rarity(seed: datedSeed, letterId: id, pity: care.pity) : "common"
        let items = catalog.items.all.filter { $0.source == kind.rawValue && $0.rarity == rarity && $0.sponsor == nil }
        let owned = Set(care.souvenirs.map(\.id))
        let newItems = items.filter { !owned.contains($0.id) }
        let drops = newItems.isEmpty ? items : newItems
        let item = drops[Int(random.next() % UInt64(drops.count))]
        letter.rewards.itemIds = [item.id]
        letter.rewards.dropRarity = rarity
        letter.rewardItems = [item]
        if owned.contains(item.id) { letter.rewards.duplicateClueCityId = letter.cityId }
    }
}
