import SwiftUI
import VoyageCore

struct HomeTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            HStack(alignment: .top, spacing: 16) {
                SpriteView(pet: state.pet, scale: 8, moving: model.isMoving)
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(Theme.inkRaised)
                    .pixelBorder(Theme.dusk)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.petName).font(Theme.pixel(24)).foregroundStyle(Theme.paper)
                        Text(l10n("home.hometown", l10n.cityName(catalog.city(state.route[0]))))
                            .foregroundStyle(Theme.dusk)
                    }
                    .padding(12)

                    Button { model.activateHomeAction() } label: {
                        Text(model.unread > 0 ? l10n("home.openMail") : l10n("home.findPet"))
                            .foregroundStyle(model.unread > 0 ? Theme.ink : Theme.paper)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(model.unread > 0 ? Theme.red : Theme.inkRaised)
                            .pixelBorder(model.unread > 0 ? Theme.red : Theme.dusk)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n("home.now")).foregroundStyle(Theme.dusk)
                        Text(l10n("home.onRoad", l10n.cityName(catalog.city(state.targetCityId))))
                        BlockProgress(progress: state.legProgress, blocks: 16, size: 8)
                        Text(l10n("home.today", Format.km(fuel: model.todayFuel))).foregroundStyle(Theme.amber)
                        Text(l10n("journey.remaining", Format.km(fuel: state.remainingFuel))).foregroundStyle(Theme.dusk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.inkRaised)
                    .pixelBorder(Theme.dusk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.pixel())
            .foregroundStyle(Theme.paper)
        }
    }
}
