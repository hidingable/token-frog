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
                ScrollView {
                    Group {
                        switch flow.step {
                        case .eggs: eggs
                        case .home: home(availableWidth: proxy.size.width - 60)
                        case .hatch: hatch
                        case .logbook: logbook
                        case .depart: departure
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                }
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
                ForEach(PetKind.allCases, id: \.self) { pet in
                    Button { flow.selectEgg(pet) } label: {
                        VStack(spacing: 10) {
                            eggImage(pet, scale: 10)
                            Text(l10n(L10n.eggKeys[pet]!)).font(Theme.pixel())
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
            TextField(l10n("onboarding.search"), text: $flow.search)
                .textFieldStyle(.plain).padding(10).background(theme.surfaceRaised).pixelBorder(theme.border)
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(flow.cities(l10n: l10n)) { city in
                            Button { flow.homeCityId = city.id } label: {
                                Text(l10n.cityName(city)).font(Theme.pixel())
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(flow.homeCityId == city.id ? theme.selectedText : theme.text)
                                    .background(flow.homeCityId == city.id ? theme.selectedFill : theme.surfaceRaised)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 210, height: 250)
                VStack(alignment: .leading, spacing: 12) {
                    let city = flow.catalog.city(flow.homeCityId)
                    Text(l10n.cityName(city)).font(Theme.pixel(24))
                    PixelMapView(image: PixelMap.homeImage(city, theme: theme),
                                 availableWidth: availableWidth - 210 - 18, borderColor: theme.border)
                        .accessibilityLabel(l10n("onboarding.homeMap", l10n.cityName(city)))
                }
            }
            hint(l10n("onboarding.homeHint"))
        }
        .foregroundStyle(theme.text)
    }

    private var hatch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { flow.skipHatching() } label: {
                Group {
                    if flow.hatchFrame == 2 {
                        PixelArtView(image: Sprites.image(flow.species!, .rest), scale: 6).fixedSize()
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
            Text(l10n("onboarding.distance", Format.km(fuel: preview.legCost)))
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

    private func eggImage(_ pet: PetKind, scale: Int, cracked: Bool = false) -> some View {
        PixelArtView(image: Sprites.egg(pet, cracked: cracked), scale: scale).fixedSize()
    }
}
