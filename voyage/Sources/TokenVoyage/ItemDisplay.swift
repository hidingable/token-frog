import VoyageCore

/// New companion mail uses saved item snapshots; legacy items resolve through the catalog.
struct ItemDisplay: Equatable, Identifiable {
    let item: Item
    let name: String
    let description: String
    let rarity: String?
    let isRare: Bool
    var id: String { item.id }

    init(_ item: Item, l10n: L10n, showCommon: Bool = false, rarity: String? = nil) {
        self.item = item
        name = l10n.itemName(item)
        description = l10n.itemDescription(item)
        let recordedRarity = rarity ?? item.rarity
        isRare = recordedRarity == "rare"
        switch recordedRarity {
        case "rare": self.rarity = l10n("item.rarityRare")
        case "uncommon": self.rarity = l10n("item.rarityUncommon")
        case "common" where showCommon: self.rarity = l10n("item.rarityCommon")
        default: self.rarity = nil
        }
    }
}

struct BroughtItems: Equatable {
    let items: [ItemDisplay]
    let menus: [ItemDisplay]
    let duplicateMessage: String?
    let clueProgress: String?
}

extension LetterComposer {
    static func brought(for letter: Letter, care: CareState?, catalog: CityCatalog, l10n: L10n) -> BroughtItems? {
        // The rarity stamp distinguishes these rewards from older saved letters.
        guard let rarity = letter.rewards.dropRarity else { return nil }
        let items = letter.rewards.itemIds.compactMap { id in letter.rewardItems.first { $0.id == id } ?? catalog.items.find(id) }.map { ItemDisplay($0, l10n: l10n, rarity: rarity) }
        let menus = letter.rewards.menuIds.compactMap { catalog.items.find($0) }.map { ItemDisplay($0, l10n: l10n) }
        let city = letter.rewards.duplicateClueCityId
        return BroughtItems(
            items: items, menus: menus,
            duplicateMessage: city.flatMap { _ in items.first.map { l10n("letter.duplicateItem", $0.name) } },
            clueProgress: city.flatMap { cityId in
                care.flatMap { TrailClueDisplay(cityId: cityId, care: $0, library: catalog.stories, l10n: l10n)?.summary }
            }
        )
    }
}

struct MenuGroup: Identifiable {
    struct Entry: Identifiable {
        let item: Item
        let letterId: Int
        var id: String { item.id }
    }
    let cityId: String
    let entries: [Entry]
    var id: String { cityId }
}

enum ItemCollection {
    static func menuGroups(care: CareState, catalog: CityCatalog, letters: [Letter]) -> [MenuGroup] {
        var groups: [String: [MenuGroup.Entry]] = [:]
        for menu in care.menus {
            guard let item = catalog.items.find(menu.id) else { continue }
            let city = item.cityId ?? letters.first { $0.id == menu.letterId }?.cityId ?? ""
            groups[city, default: []].append(.init(item: item, letterId: menu.letterId))
        }
        return groups.keys.sorted().map { city in
            MenuGroup(cityId: city, entries: groups[city]!.sorted { $0.id < $1.id })
        }
    }
}
