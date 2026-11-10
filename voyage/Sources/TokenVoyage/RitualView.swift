import SwiftUI
import VoyageCore

struct RitualView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let letter = model.ritualLetter, let catalog = model.catalog {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(l10n("ritual.title")).font(Theme.pixel(24)).foregroundStyle(theme.text)
                    LetterView(letter: letter, photoURL: model.photoURL(letter), petName: model.petName, catalog: catalog, model: model)
                    RitualEndingView(model: model)
                }
                .padding(12)
            }
            .id(letter.id)
            .task(id: "\(letter.id)-\(l10n.language.rawValue)") { await model.enrichPlace(letterId: letter.id) }
        }
    }
}

struct RitualEndingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let care = model.care, let catalog = model.catalog {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(l10n("ritual.now")).font(Theme.pixel(24))
                    let status = HomeStatusDisplay(journey: state, care: care, now: model.now, catalog: catalog, l10n: l10n)
                    Text(status.title).font(Theme.pixel())
                    Text(status.detail).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                }
                .foregroundStyle(theme.text).padding(16).background(theme.surfaceRaised).pixelBorder(theme.border)
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n("ritual.chooseItem")).font(Theme.pixel(24))
                    BagItemPicker(items: catalog.items.all.filter { model.care?.bag.owned.contains($0.id) == true },
                                  selection: model.care?.bag.todayItem) { model.setTodayItem($0) }
                    Text(l10n("ritual.itemHint")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.text).padding(16).background(theme.surfaceRaised).pixelBorder(theme.border)
                HStack(alignment: .top, spacing: 12) {
                    CollectionAction(title: model.ritualFinishTitle) {
                        model.advanceRitual()
                    }
                    if model.ritualRemainingCount > 0 {
                        CollectionAction(title: l10n("ritual.collectAll")) { model.collectAllRitualLetters() }
                    }
                }
                .disabled(model.isLocked)
            }
        }
    }
}

struct BroughtItemsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let brought: BroughtItems

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("letter.broughtItems")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
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
                .padding(12).background(theme.paper)
                .pixelBorder(theme.paperBorder, width: display.isRare ? 4 : 2)
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
