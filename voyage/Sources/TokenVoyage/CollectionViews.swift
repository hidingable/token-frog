import SwiftUI
import VoyageCore

struct ItemIcon: View {
    @Environment(\.petCatalog) private var catalog
    @Environment(\.theme) private var theme
    let item: Item
    var scale = 3
    var body: some View {
        if let catalog {
            PixelArtView(image: Sprites.item(item.icon, catalog: catalog), scale: scale)
                .fixedSize().accessibilityHidden(true)
        }
    }
}

private struct ItemTile: View {
    @Environment(\.theme) private var theme
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
            .foregroundStyle(selected ? theme.selectedText : theme.text)
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(8)
            .background(selected ? theme.selectedFill : theme.surfaceRaised)
            .pixelBorder(selected ? theme.selectedFill : theme.border, width: selected ? 3 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!owned)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ItemHeading: View {
    @Environment(\.theme) private var theme
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
    @Environment(\.theme) private var theme
    let content: Content
    let rare: Bool
    init(rare: Bool = false, @ViewBuilder content: () -> Content) {
        self.rare = rare
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .foregroundStyle(theme.paperText)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16).background(theme.paper).pixelBorder(theme.paperBorder, width: rare ? 4 : 2)
    }
}

struct BagItemPicker: View {
    @Environment(\.theme) private var theme
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
    @Environment(\.theme) private var theme
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
                        Text(l10n("collection.bagSource")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l10n("collection.carriedCount", model.carriedCount(selected.id))).font(Theme.pixel())
                        CollectionAction(title: care.bag.todayItem == selected.id ? l10n("collection.clearCarry") : l10n("collection.carryToday")) {
                            selectedItemID = selected.id
                            model.setTodayItem(care.bag.todayItem == selected.id ? nil : selected.id)
                        }
                        .disabled(model.isLocked)
                        Text(l10n("item.randomHint")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct SouvenirsCollectionView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedItemID: String?

    var body: some View {
        if let catalog = model.catalog, let care = model.care {
            let souvenirs = care.souvenirs.compactMap { saved in catalog.items.find(saved.id) }
            let selected = souvenirs.first { $0.id == selectedItemID } ?? souvenirs.first
            VStack(alignment: .leading, spacing: 24) {
                if souvenirs.isEmpty {
                    CollectionEmpty(l10n("collection.souvenirsEmpty"))
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
                                if let origin = ItemCollection.boxOrigin(for: saved, l10n: l10n) {
                                    Text(origin).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                                } else if let letterId = saved.letterId {
                                    ItemOrigin(model: model, letterId: letterId)
                                }
                                CollectionAction(title: saved.shelved ? l10n("collection.unshelve") : l10n("collection.shelve")) {
                                    model.setSouvenirShelved(saved.id, shelved: !saved.shelved)
                                }
                                .disabled(model.isLocked)
                                if let message = ItemCollection.shelfFullMessage(for: saved, care: care, l10n: l10n) {
                                    Text(message).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                let cities = care.trailClues.keys.filter { care.trailClues[$0, default: 0] > 0 }.sorted()
                if !cities.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l10n("collection.trailClues")).font(Theme.pixel(24)).foregroundStyle(theme.text)
                        ForEach(cities, id: \.self) { city in
                            Text(l10n("collection.cityClues", l10n.cityName(catalog.city(city)), care.trailClues[city]!))
                                .font(Theme.pixel()).foregroundStyle(theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

struct MenusCollectionView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedItemID: String?

    var body: some View {
        if let catalog = model.catalog, let care = model.care {
            let groups = ItemCollection.menuGroups(care: care, catalog: catalog, letters: model.state?.letters ?? [])
            let entries = groups.flatMap(\.entries)
            let selected = entries.first { $0.id == selectedItemID } ?? entries.first
            if groups.isEmpty {
                CollectionEmpty(l10n("collection.menusEmpty"))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups) { group in
                            Text(l10n.cityName(catalog.city(group.cityId))).font(Theme.pixel(24)).foregroundStyle(theme.text)
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
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let letterId: Int
    var body: some View {
        if let letter = model.state?.letters.first(where: { $0.id == letterId }), let catalog = model.catalog {
            Button { model.openCollectionLetter(letterId) } label: {
                Text(LetterComposer.origin(for: letter, letters: model.state?.letters ?? [], l10n: l10n, catalog: catalog))
                    .font(Theme.pixel()).underline().fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(letter.deliverAt > model.now)
        }
    }
}

struct CollectionAction: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.pixel()).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(theme.actionText).padding(12)
                .frame(maxWidth: .infinity).background(theme.actionFill).pixelBorder(theme.border)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CollectionEmpty: View {
    @Environment(\.theme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 14)).lineSpacing(4).foregroundStyle(theme.textMuted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
