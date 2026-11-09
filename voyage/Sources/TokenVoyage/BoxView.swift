import AppKit
import SwiftUI
import VoyageCore

struct BoxView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var shaking = false
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 40)
                if let result = model.boxResult, !shaking {
                    resultView(result)
                    CollectionAction(title: model.boxFinishTitle) { model.finishBox() }
                        .frame(maxWidth: 280)
                } else {
                    Button {
                        if shaking { shaking = false; shakeOffset = 0 }
                    } label: {
                        if let catalog = model.catalog {
                            PixelArtView(image: Sprites.item("box", catalog: catalog.pets), scale: 6)
                                .frame(width: 72, height: 72).offset(x: shakeOffset)
                        }
                    }
                    .buttonStyle(.plain).disabled(!shaking)
                    .accessibilityLabel(l10n("box.skip"))
                    Text(l10n("box.title")).font(Theme.pixel(24))
                    Text(l10n("box.stamps", model.boxStampCount)).foregroundStyle(theme.textMuted)
                    CollectionAction(title: l10n(shaking ? "box.skip" : "box.open")) {
                        if shaking { shaking = false; shakeOffset = 0 }
                        else if model.openPresentedBox() != nil { shaking = true }
                    }
                    .frame(maxWidth: 280)
                }
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity, minHeight: 440).padding(24)
        }
        .font(Theme.pixel()).foregroundStyle(theme.text)
        .background(theme.surfaceRaised).pixelBorder(theme.border).padding(12)
        .task(id: shaking) {
            guard shaking else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for offset: CGFloat in [-6, 6, 0] {
                    shakeOffset = offset
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled else { return }
                }
            }
            shaking = false
            shakeOffset = 0
        }
    }

    @ViewBuilder private func resultView(_ result: BoxResult) -> some View {
        if let catalog = model.catalog {
            switch result {
            case .item(let id, let kind):
                if let item = catalog.items.find(id) {
                    ItemIcon(item: item, scale: 6)
                    Text(l10n.itemName(item)).font(Theme.pixel(24))
                        .foregroundStyle(kind == "bag" ? theme.newPlaceText : theme.text)
                    if kind == "bag" { Text(l10n("box.newBagItem")).foregroundStyle(theme.newPlaceText) }
                    Text(l10n.itemDescription(item)).font(.system(size: 14)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                }
            case .clue(let city):
                PixelArtView(image: Sprites.item("note", catalog: catalog.pets), scale: 6).fixedSize()
                Text(l10n("box.clue", l10n.cityName(catalog.city(city)))).font(Theme.pixel(24))
                    .fixedSize(horizontal: false, vertical: true)
                if let care = model.care,
                   let clues = TrailClueDisplay(cityId: city, care: care, library: catalog.stories, l10n: l10n) {
                    Text(clues.summary).foregroundStyle(theme.mileageText)
                }
            }
        }
    }
}
