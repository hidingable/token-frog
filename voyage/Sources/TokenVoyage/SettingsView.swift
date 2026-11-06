import SwiftUI
import VoyageCore

struct SettingsTab: View {
    @Environment(\.l10n) private var l10n
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("settings.language")).foregroundStyle(Theme.dusk)
                HStack {
                    Text(l10n("settings.interfaceAndLetters"))
                    Spacer()
                    Menu {
                        Picker(l10n("settings.language"), selection: $model.languagePreference) {
                            ForEach(LanguagePreference.allCases, id: \.self) { preference in
                                Text(l10n(L10n.languageKeys[preference]!)).tag(preference)
                            }
                        }
                    } label: {
                        Text(l10n(L10n.languageKeys[model.languagePreference]!))
                            .padding(8).pixelBorder(Theme.dusk)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("settings.display")).foregroundStyle(Theme.dusk)
                Toggle(l10n("settings.notch"), isOn: $model.notchEnabled)
                Toggle(l10n("settings.floating"), isOn: $model.floatingEnabled)
            }
            .toggleStyle(PixelToggleStyle())
            if model.canChangeStart, let state = model.state {
                HStack(alignment: .top) {
                    Text(l10n("settings.home"))
                    Spacer()
                    Picker(l10n("settings.home"), selection: Binding(get: { state.route[0] }, set: { model.setStart($0) })) {
                        ForEach(model.startCities) { Text(l10n.cityName($0)).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 250)
                }
                Text(l10n("onboarding.homeHint")).foregroundStyle(Theme.dusk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.pixel())
        .foregroundStyle(Theme.paper)
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.inkRaised)
        .pixelBorder(Theme.dusk)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PixelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack {
                    Rectangle().fill(configuration.isOn ? Theme.paper : Theme.ink)
                    if configuration.isOn { Text("✓").foregroundStyle(Theme.ink) }
                }
                .frame(width: 20, height: 20)
                .pixelBorder(Theme.dusk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "1" : "0"))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
