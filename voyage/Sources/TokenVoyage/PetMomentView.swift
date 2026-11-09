import SwiftUI
import VoyageCore

struct PetMomentView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let stage: Stage

    var body: some View {
        if let catalog = model.catalog, let state = model.state {
            let card = catalog.petMoments.card(for: stage)
            VStack(spacing: 20) {
                Text(model.petName).font(Theme.pixel(24))
                PixelArtView(image: Sprites.image(state.pet, .rest, catalog: catalog.pets,
                                                  form: stage == .juvenile ? .juvenile : .teen), scale: 8)
                    .fixedSize().padding(16).background(theme.paper).pixelBorder(theme.paperBorder)
                    .accessibilityLabel(l10n.stage(stage))
                Text(LetterComposer.localized(card.title, l10n: l10n) ?? "")
                    .font(Theme.pixel(24)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n.stage(stage)).font(Theme.pixel()).foregroundStyle(theme.companionText)
                Text(LetterComposer.localized(card.body, l10n: l10n) ?? "")
                    .font(.system(size: 15)).lineSpacing(6).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                HStack(spacing: 24) {
                    Button(l10n("moment.skip")) { model.dismissPetMoment() }.buttonStyle(.plain)
                    CollectionAction(title: l10n("moment.continue")) { model.dismissPetMoment() }
                }.font(Theme.pixel())
            }.padding(28).frame(maxWidth: .infinity)
                .foregroundStyle(theme.text).background(theme.surfaceRaised).pixelBorder(theme.border)
                .onAppear { model.petMomentDidDisplay(stage) }
        }
    }
}
