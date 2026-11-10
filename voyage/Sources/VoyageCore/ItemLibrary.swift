import Foundation

public struct Item: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var cityId: String?
    public var rarity: String?
    public var icon: String
    public var habit: String?
    public var names: [String: String]
    public var descriptions: [String: String]
    public var source: String?
}

public struct BoxContents: Codable, Equatable, Sendable {
    public var souvenirIds: [String]
    public var bagItemIds: [String]
}

/// Loaded with the validated catalog. ID order, rather than file order, controls draws.
public struct ItemLibrary: Sendable {
    public let all: [Item]
    public let boxes: BoxContents
    private let byId: [String: Item]
    private var remoteIDs: Set<String> = []

    init(items: [Item], boxes: BoxContents = BoxContents(souvenirIds: [], bagItemIds: [])) {
        all = items.sorted { $0.id < $1.id }
        byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        self.boxes = boxes
    }

    public func find(_ id: String) -> Item? { byId[id] }

    func addingRemote(_ entries: [Item]) -> ItemLibrary {
        let additions = entries.filter { byId[$0.id] == nil }
        var result = ItemLibrary(items: all + additions, boxes: boxes)
        result.remoteIDs = remoteIDs.union(additions.map(\.id))
        return result
    }

    func availableForTrip(_ ids: Set<String>) -> ItemLibrary {
        guard !remoteIDs.isEmpty else { return self }
        return ItemLibrary(items: all.filter { !remoteIDs.contains($0.id) || ids.contains($0.id) }, boxes: boxes)
    }

    func drop(rewards: StoryRewards, letter: Letter, care: CareState, seed: UInt32) -> StoryRewards {
        let rarity = ItemDropRules.rarity(seed: seed, letterId: letter.id, pity: care.pity)
        let souvenirs = all.filter { $0.kind == "souvenir" && $0.source == nil && $0.rarity == rarity }
        let authored = souvenirs.filter { rewards.itemIds.contains($0.id) }
        let local = souvenirs.filter { $0.cityId == letter.cityId }
        let generic = souvenirs.filter { $0.cityId == nil }
        let owned = Set(care.souvenirs.map(\.id))
        let unseen = generic.filter { !owned.contains($0.id) }
        // Validation guarantees a generic fallback for every rarity.
        let candidates: [Item]
        if !authored.isEmpty { candidates = authored }
        else if !local.isEmpty { candidates = local }
        else { candidates = unseen.isEmpty ? generic : unseen }
        var random = SplitMix64(seed: seed, stopCount: letter.id, salt: .dropItem)
        let item = candidates[Int(random.next() % UInt64(candidates.count))]
        var result = StoryRewards()
        result.itemIds = [item.id]
        result.menuIds = rewards.menuIds
        result.dropRarity = rarity
        if owned.contains(item.id) { result.duplicateClueCityId = item.cityId ?? letter.cityId }
        return result
    }
}

/// Drop probabilities and the pity threshold share one configuration, independent of content.
enum ItemDropRules {
    static let rarePercent = 5
    static let uncommonPercent = 25
    static let pityThreshold = 8

    static func rarity(seed: UInt32, letterId: Int, pity: Int) -> String {
        if pity >= pityThreshold { return "rare" }
        var random = SplitMix64(seed: seed, stopCount: letterId, salt: .dropRarity)
        let roll = Int(random.next() % 100)
        if roll < rarePercent { return "rare" }
        return roll < rarePercent + uncommonPercent ? "uncommon" : "common"
    }
}
