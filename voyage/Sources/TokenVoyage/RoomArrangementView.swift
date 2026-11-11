import SwiftUI
import VoyageCore

/// Iteration deliberately tolerates duplicate IDs from a saved inventory.
func roomItems(care: CareState, catalog: CityCatalog, letters: [Letter] = []) -> [RoomSlot: Item] {
    guard RoomDecor.isUnlocked(care) else { return [:] }
    var items: [RoomSlot: Item] = [:]
    for placement in care.roomPlacements ?? [] {
        if let slot = RoomSlot(rawValue: placement.slot),
           let saved = care.souvenirs.first(where: { $0.id == placement.itemID }),
           let item = ItemCollection.souvenirItem(saved, letters: letters, library: catalog.items) {
            items[slot] = item
        }
    }
    return items
}

struct RoomArrangementView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedSlot: RoomSlot = .windowsill

    var body: some View {
        if model.canArrangeRoom, let care = model.care, let state = model.state, let catalog = model.catalog {
            let placed = roomItems(care: care, catalog: catalog, letters: state.letters)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(l10n("profile.back")) { model.openPostOffice() }.buttonStyle(.plain)
                    Spacer()
                    Text(l10n("room.arrange")).font(Theme.pixel(24))
                }
                Text(l10n("room.instructions")).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                PixelArtView(image: RoomArt.image(pet: state.pet, shelf: RoomLayout.shelf(care).compactMap { model.ownedItem($0.id) },
                                                  theme: theme, catalog: catalog.pets, form: model.petForm, placements: placed,
                                                  nightcap: model.nightcapNote != nil, petIsHome: state.petIsHome), scale: 2)
                    .frame(width: 480, height: 264).frame(maxWidth: .infinity)
                    .accessibilityLabel(l10n("room.preview"))
                HStack(spacing: 8) {
                    ForEach(RoomSlot.allCases, id: \.rawValue) { slot in
                        Button { selectedSlot = slot } label: {
                            VStack(spacing: 8) {
                                Text(l10n.roomSlot(slot))
                                if let item = placed[slot] {
                                    ItemIcon(item: item, scale: 2)
                                    Text(l10n.itemName(item)).fixedSize(horizontal: false, vertical: true)
                                    if let tag = l10n.sponsorTag(item.sponsor) { SponsorTag(text: tag) }
                                } else {
                                    Text(l10n("room.empty")).foregroundStyle(theme.textMuted)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 86).padding(8)
                            .foregroundStyle(selectedSlot == slot ? theme.selectedText : theme.text)
                            .background(selectedSlot == slot ? theme.selectedFill : theme.surfaceRaised)
                            .pixelBorder(selectedSlot == slot ? theme.text : theme.border)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n("room.placedItem", l10n.roomSlot(slot), placed[slot].map(l10n.itemName) ?? l10n("room.empty")))
                        .accessibilityAddTraits(selectedSlot == slot ? .isSelected : [])
                    }
                }
                HStack {
                    Text(l10n("room.chooseFor", l10n.roomSlot(selectedSlot)))
                    Spacer()
                    Button(l10n("room.clear")) { model.placeSouvenir(nil, in: selectedSlot) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n("room.clearSlot", l10n.roomSlot(selectedSlot)))
                }
                let owned = ownedItems(care: care, library: catalog.items, letters: state.letters)
                if owned.isEmpty {
                    Text(l10n("room.noSouvenirs")).foregroundStyle(theme.textMuted)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(owned) { item in
                        Button { model.placeSouvenir(item.id, in: selectedSlot) } label: {
                            HStack(spacing: 12) {
                                ItemIcon(item: item, scale: 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(l10n.itemName(item)).fixedSize(horizontal: false, vertical: true)
                                    if let tag = l10n.sponsorTag(item.sponsor) { SponsorTag(text: tag) }
                                    if let location = location(item.id, care: care) {
                                        Text(location).foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.padding(10).background(theme.surfaceRaised).pixelBorder(theme.border)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(l10n("room.placeItem", l10n.itemName(item), l10n.roomSlot(selectedSlot)))
                    }
                }
            }.font(Theme.pixel()).foregroundStyle(theme.text)
        }
    }

    private func ownedItems(care: CareState, library: ItemLibrary, letters: [Letter]) -> [Item] {
        var seen: Set<String> = []
        return care.souvenirs.compactMap {
            guard seen.insert($0.id).inserted,
                  let item = ItemCollection.souvenirItem($0, letters: letters, library: library), item.kind == "souvenir" else { return nil }
            return item
        }
    }

    private func location(_ id: String, care: CareState) -> String? {
        if care.souvenirs.contains(where: { $0.id == id && $0.shelved }) { return l10n("room.onShelf") }
        if let slot = (care.roomPlacements ?? []).first(where: { $0.itemID == id }).flatMap({ RoomSlot(rawValue: $0.slot) }) {
            return l10n.roomSlot(slot)
        }
        return nil
    }
}
