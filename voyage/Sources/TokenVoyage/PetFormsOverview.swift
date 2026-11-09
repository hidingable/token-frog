import SwiftUI
import VoyageCore

/// Snapshot-only art sheet: every sprite uses its native grid at exactly eight times size.
struct PetFormsOverview: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let catalog: PetCatalog
    var nightcap = false
    private var forms: [PetForm] { nightcap ? [.juvenile, .teen] : PetForm.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(nightcap ? l10n("snapshot.petNightcaps") : l10n("snapshot.petForms")).font(Theme.pixel(24))
            HStack(spacing: 16) {
                Color.clear.frame(width: 100, height: 24)
                ForEach(forms, id: \.rawValue) { form in
                    Text(l10n.stage(stage(form))).frame(width: 184)
                }
            }
            ForEach(catalog.all) { pet in
                HStack(spacing: 16) {
                    Text(l10n.defaultPetName(pet.id, catalog: catalog)).frame(width: 100, alignment: .leading)
                    ForEach(forms, id: \.rawValue) { form in
                        PixelArtView(image: Sprites.image(pet.id, .rest, catalog: catalog, form: form, nightcap: nightcap), scale: 8)
                            .fixedSize().frame(width: 160, height: 168, alignment: .bottom)
                            .padding(12).background(theme.paper).pixelBorder(theme.paperBorder)
                    }
                }
            }
        }.font(Theme.pixel()).foregroundStyle(theme.text).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(theme.background)
    }

    private func stage(_ form: PetForm) -> Stage {
        switch form {
        case .hatchling: .hatchling
        case .juvenile: .juvenile
        case .teen: .teen
        }
    }
}
