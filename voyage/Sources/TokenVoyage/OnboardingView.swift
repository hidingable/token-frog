import SwiftUI
import VoyageCore

struct OnboardingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    @Bindable var flow: OnboardingFlow
    var onDepart: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(flow.step.rawValue) / 5").foregroundStyle(theme.mileageText)
                    Text(l10n.onboardingTitle(flow)).foregroundStyle(theme.text)
                }
                .font(Theme.pixel(24))
                Group {
                    if flow.step == .home {
                        home(availableWidth: proxy.size.width - 60)
                    } else {
                        ScrollView {
                            Group {
                                switch flow.step {
                                case .eggs: eggs
                                case .home: EmptyView()
                                case .hatch: hatch
                                case .logbook: logbook
                                case .depart: departure
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Button {
                    if flow.step == .depart { onDepart() } else { flow.advance(l10n: l10n) }
                } label: {
                    Text(flow.step == .depart ? l10n("onboarding.go") : l10n("action.continue"))
                        .font(Theme.pixel())
                        .foregroundStyle(flow.canContinue ? theme.selectedText : theme.textMuted)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(flow.canContinue ? theme.selectedFill : theme.surfaceRaised)
                        .pixelBorder(theme.border)
                }
                .buttonStyle(.plain)
                .disabled(!flow.canContinue)
                if flow.step == .depart {
                    Text(l10n("onboarding.tomorrow")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.background)

        }
    }

    private var eggs: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(flow.eggs) { definition in
                    let pet = definition.id
                    Button { flow.selectEgg(pet) } label: {
                        VStack(spacing: 10) {
                            eggImage(pet, scale: 10)
                            Text(l10n.eggName(pet, catalog: flow.catalog.pets)).font(Theme.pixel())
                        }
                        .padding(16).frame(maxWidth: .infinity)
                        .foregroundStyle(flow.species == pet ? theme.selectedText : theme.text)
                        .background(flow.species == pet ? theme.selectedFill : theme.surfaceRaised)
                        .pixelBorder(flow.species == pet ? theme.selectedFill : theme.border)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(flow.species == pet ? .isSelected : [])
                }
            }
            hint(l10n("onboarding.eggHint"))
        }
    }

    private func home(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                CitySearchList(catalog: flow.catalog, selection: $flow.homeCityId, search: $flow.search)
                    .frame(width: 240)
                VStack(alignment: .leading, spacing: 12) {
                    let city = flow.catalog.city(flow.homeCityId)
                    let map = PixelMap.homeImage(city, theme: theme)
                    let scale = RoomLayout.scale(availableWidth: availableWidth - 240 - 18, pixelWidth: map.width)
                    Text(l10n.cityName(city)).font(Theme.pixel(24))
                    PixelMapView(image: map, availableWidth: CGFloat(map.width * scale), borderColor: theme.border)
                        .accessibilityLabel(l10n("onboarding.homeMap", l10n.cityName(city)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            hint(l10n("onboarding.homeHint"))
        }
        .padding(2)
        .foregroundStyle(theme.text)
    }

    private var hatch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { flow.skipHatching() } label: {
                Group {
                    if flow.hatchFrame == 2 {
                        PixelArtView(image: Sprites.image(flow.species!, .rest, catalog: flow.catalog.pets), scale: 6).fixedSize()
                    } else {
                        eggImage(flow.species!, scale: 6, cracked: flow.hatchFrame == 1)
                            .offset(x: flow.hatchFrame == 0 ? -4 : 4)
                    }
                }
                .padding(24).frame(maxWidth: .infinity).background(theme.paper)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n("onboarding.skipHatch"))
            .task { await flow.hatch() }
            TextField(l10n("onboarding.name"), text: $flow.petName)
                .textFieldStyle(.plain).font(Theme.pixel(24)).foregroundStyle(theme.text)
                .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
            hint(l10n("onboarding.nameHint"))
            if let problem = flow.nameProblem {
                hint(problem == .empty ? l10n("onboarding.nameEmpty") : l10n("onboarding.nameLong"))
            }
        }
    }

    private var logbook: some View {
        VStack(alignment: .leading, spacing: 16) {
            if flow.isReading { hint(l10n("onboarding.reading")) }
            LetterView(letter: flow.preview.letters[0], photoURL: nil, petName: flow.trimmedName, catalog: flow.catalog)
        }
    }

    private var departure: some View {
        let preview = flow.preview
        return VStack(alignment: .leading, spacing: 18) {
            Text(l10n("onboarding.firstStop", l10n.cityName(flow.catalog.city(preview.targetCityId))))
                .font(Theme.pixel(24)).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("onboarding.distance", Format.km(preview.legKm)))
                .font(Theme.pixel()).foregroundStyle(theme.mileageText)
            hint(l10n("item.randomHint"))
            BagItemPicker(items: flow.catalog.items.all.filter { CareState.Bag().owned.contains($0.id) }, selection: flow.todayItem) { selected in
                if let selected { flow.toggleItem(selected) }
                else if let current = flow.todayItem { flow.toggleItem(current) }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func eggImage(_ pet: PetID, scale: Int, cracked: Bool = false) -> some View {
        PixelArtView(image: Sprites.egg(pet, cracked: cracked, catalog: flow.catalog.pets), scale: scale).fixedSize()
    }
}
