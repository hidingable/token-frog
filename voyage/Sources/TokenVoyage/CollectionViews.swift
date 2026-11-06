import SwiftUI
import VoyageCore

struct ItemIcon: View {
    let item: Item
    var scale = 3
    var body: some View {
        PixelArtView(image: Sprites.item(item.icon), scale: scale)
            .fixedSize().accessibilityHidden(true)
    }
}

private struct ItemTile: View {
    @Environment(\.l10n) private var l10n
    let item: Item
    var owned = true
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                if owned {
                    ItemIcon(item: item)
                    Text(l10n.itemName(item)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("?").font(Theme.pixel(36)).frame(height: 36)
                    Text(l10n("item.unknown"))
                }
            }
            .font(Theme.pixel())
            .foregroundStyle(selected ? Theme.ink : Theme.paper)
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(8)
            .background(selected ? Theme.paper : Theme.inkRaised)
            .pixelBorder(selected ? Theme.paper : Theme.dusk, width: selected ? 3 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!owned)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ItemHeading: View {
    let display: ItemDisplay
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ItemIcon(item: display.item, scale: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(display.name).font(Theme.pixel(24)).fixedSize(horizontal: false, vertical: true)
                if let rarity = display.rarity { Text(rarity).font(Theme.pixel()) }
            }
        }
    }
}

private struct ItemPaper<Content: View>: View {
    let content: Content
    let rare: Bool
    init(rare: Bool = false, @ViewBuilder content: () -> Content) {
        self.rare = rare
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16).background(Theme.paper).pixelBorder(Theme.ink, width: rare ? 4 : 2)
    }
}

struct BagItemPicker: View {
    let items: [Item]
    let selection: String?
    let select: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(items) { item in
                ItemTile(item: item, selected: selection == item.id) {
                    select(selection == item.id ? nil : item.id)
                }
            }
        }
    }
}

struct BagCollectionView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedItemID: String?

    var body: some View {
        if let catalog = model.catalog, let care = model.care {
            let items = catalog.items.all.filter { $0.kind == "bag" }
            let selected = items.first { $0.id == selectedItemID && care.bag.owned.contains($0.id) }
                ?? items.first { $0.id == care.bag.todayItem }
                ?? items.first { care.bag.owned.contains($0.id) }
            HStack(alignment: .top, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        ItemTile(item: item, owned: care.bag.owned.contains(item.id), selected: selected?.id == item.id) {
                            selectedItemID = item.id
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if let selected {
                    ItemPaper {
                        ItemHeading(display: ItemDisplay(selected, l10n: l10n))
                        Text(l10n.itemDescription(selected)).font(.system(size: 14)).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l10n("collection.bagSource")).font(Theme.pixel()).foregroundStyle(Theme.brown)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l10n("collection.carriedCount", model.carriedCount(selected.id))).font(Theme.pixel())
                        CollectionAction(title: care.bag.todayItem == selected.id ? l10n("collection.clearCarry") : l10n("collection.carryToday")) {
                            selectedItemID = selected.id
                            model.setTodayItem(care.bag.todayItem == selected.id ? nil : selected.id)
                        }
                        .disabled(model.isLocked)
                        Text(l10n("item.randomHint")).font(Theme.pixel()).foregroundStyle(Theme.brown)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct SouvenirsCollectionView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedItemID: String?

    var body: some View {
        if let catalog = model.catalog, let care = model.care {
            let souvenirs = care.souvenirs.compactMap { saved in catalog.items.find(saved.id) }
            let selected = souvenirs.first { $0.id == selectedItemID } ?? souvenirs.first
            VStack(alignment: .leading, spacing: 24) {
                if souvenirs.isEmpty {
                    collectionEmpty(l10n("collection.souvenirsEmpty"))
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                            ForEach(souvenirs) { item in
                                ItemTile(item: item, selected: selected?.id == item.id) { selectedItemID = item.id }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if let selected, let saved = care.souvenirs.first(where: { $0.id == selected.id }) {
                            ItemPaper(rare: selected.rarity == "rare") {
                                ItemHeading(display: ItemDisplay(selected, l10n: l10n, showCommon: true))
                                Text(l10n.itemDescription(selected)).font(.system(size: 14)).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let letterId = saved.letterId {
                                    ItemOrigin(model: model, letterId: letterId)
                                }
                                CollectionAction(title: saved.shelved ? l10n("collection.unshelve") : l10n("collection.shelve")) {
                                    model.setSouvenirShelved(saved.id, shelved: !saved.shelved)
                                }
                                .disabled(model.isLocked)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                let cities = care.trailClues.keys.filter { care.trailClues[$0, default: 0] > 0 }.sorted()
                if !cities.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l10n("collection.trailClues")).font(Theme.pixel(24)).foregroundStyle(Theme.paper)
                        ForEach(cities, id: \.self) { city in
                            Text(l10n("collection.cityClues", l10n.cityName(catalog.city(city)), care.trailClues[city]!))
                                .font(Theme.pixel()).foregroundStyle(Theme.dusk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

struct MenusCollectionView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedItemID: String?

    var body: some View {
        if let catalog = model.catalog, let care = model.care {
            let groups = ItemCollection.menuGroups(care: care, catalog: catalog, letters: model.state?.letters ?? [])
            let entries = groups.flatMap(\.entries)
            let selected = entries.first { $0.id == selectedItemID } ?? entries.first
            if groups.isEmpty {
                collectionEmpty(l10n("collection.menusEmpty"))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups) { group in
                            Text(l10n.cityName(catalog.city(group.cityId))).font(Theme.pixel(24)).foregroundStyle(Theme.paper)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                                ForEach(group.entries) { entry in
                                    ItemTile(item: entry.item, selected: selected?.id == entry.id) { selectedItemID = entry.id }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if let selected {
                        ItemPaper {
                            ItemHeading(display: ItemDisplay(selected.item, l10n: l10n))
                            Text(l10n.itemDescription(selected.item)).font(.system(size: 14)).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            ItemOrigin(model: model, letterId: selected.letterId)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct ItemOrigin: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let letterId: Int
    var body: some View {
        if let letter = model.state?.letters.first(where: { $0.id == letterId }), let catalog = model.catalog {
            Button { model.openCollectionLetter(letterId) } label: {
                Text(l10n("collection.origin", letterId, l10n.cityName(catalog.city(letter.cityId))))
                    .font(Theme.pixel()).underline().fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(letter.deliverAt > model.now)
        }
    }
}

struct CollectionAction: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.pixel()).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Theme.paper).padding(12)
                .frame(maxWidth: .infinity).background(Theme.ink).pixelBorder(Theme.dusk)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private func collectionEmpty(_ text: String) -> some View {
    Text(text).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Theme.dusk)
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
}
