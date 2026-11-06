import SwiftUI
import VoyageCore

struct RitualView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let letter = model.ritualLetter, let catalog = model.catalog, let state = model.state {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(l10n("ritual.title")).font(Theme.pixel(24)).foregroundStyle(Theme.paper)
                    LetterView(letter: letter, photoURL: model.photoURL(letter), petName: model.petName, catalog: catalog, model: model)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l10n("ritual.chooseItem")).font(Theme.pixel(24))
                        BagItemPicker(items: catalog.items.all.filter { model.care?.bag.owned.contains($0.id) == true },
                                      selection: model.care?.bag.todayItem) { model.setTodayItem($0) }
                        Text(l10n("item.randomHint")).font(Theme.pixel()).foregroundStyle(Theme.dusk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.paper).padding(16).background(Theme.inkRaised).pixelBorder(Theme.dusk)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n("ritual.nextStop", l10n.cityName(catalog.city(state.targetCityId))))
                            .font(Theme.pixel(24)).foregroundStyle(Theme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l10n("journey.remaining", Format.km(fuel: state.remainingFuel)))
                            .font(Theme.pixel()).foregroundStyle(Theme.amber)
                    }
                    .padding(16)
                    HStack(alignment: .top, spacing: 12) {
                        CollectionAction(title: model.ritualRemainingCount > 0
                                         ? l10n("ritual.nextLetter", model.ritualRemainingCount) : l10n("ritual.sendOff")) {
                            model.advanceRitual()
                        }
                        if model.ritualRemainingCount > 0 {
                            CollectionAction(title: l10n("ritual.collectAll")) { model.collectAllRitualLetters() }
                        }
                    }
                    .disabled(model.isLocked)
                }
                .padding(12)
            }
            .id(letter.id)
            .task(id: "\(letter.id)-\(l10n.language.rawValue)") { await model.enrichPlace(letterId: letter.id) }
        }
    }
}

struct BroughtItemsView: View {
    @Environment(\.l10n) private var l10n
    let brought: BroughtItems

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("letter.broughtItems")).font(Theme.pixel()).foregroundStyle(Theme.brown)
            ForEach(brought.items) { display in
                HStack(alignment: .top, spacing: 12) {
                    ItemIcon(item: display.item)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(display.name).font(Theme.pixel())
                        if let rarity = display.rarity { Text(rarity).font(Theme.pixel()) }
                        Text(display.description).font(.system(size: 14)).lineSpacing(4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12).background(Theme.paper)
                .pixelBorder(Theme.ink, width: display.isRare ? 4 : 2)
            }
            if let duplicate = brought.duplicateMessage {
                Text(duplicate).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            }
            if let progress = brought.clueProgress { Text(progress).font(Theme.pixel()) }
            ForEach(brought.menus) { menu in
                HStack(spacing: 12) {
                    ItemIcon(item: menu.item, scale: 2)
                    Text(l10n("letter.menuCollected", menu.name)).font(Theme.pixel())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
