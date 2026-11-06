import SwiftUI
import VoyageCore

struct SettingsTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    @Bindable var model: AppModel
    @State private var homeSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(l10n("accounts.title"))
                Spacer()
                Chip(title: l10n("accounts.manage"), isOn: false) { model.showingAccounts = true }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("settings.language")).foregroundStyle(theme.textMuted)
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
                            .padding(8).pixelBorder(theme.border)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("settings.appearance")).foregroundStyle(theme.textMuted)
                Picker(l10n("settings.appearance"), selection: $model.appearancePreference) {
                    ForEach(AppearancePreference.standard, id: \.self) { preference in
                        Text(l10n(L10n.appearanceKeys[preference]!)).tag(preference)
                    }
                    if let themes = model.themes {
                        ForEach(themes.all.filter { $0.id != "night" && $0.id != "day" }) { theme in
                            Text(theme.names[l10n.language.rawValue]!).tag(AppearancePreference.theme(theme.id))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("settings.display")).foregroundStyle(theme.textMuted)
                Toggle(l10n("settings.notch"), isOn: $model.notchEnabled)
                Toggle(l10n("settings.floating"), isOn: $model.floatingEnabled)
            }
            .toggleStyle(PixelToggleStyle())
            if model.canChangeStart, let state = model.state, let catalog = model.catalog {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n("settings.home"))
                    CitySearchList(catalog: catalog,
                                   selection: Binding(get: { state.route[0] }, set: { model.setStart($0) }), search: $homeSearch)
                        .frame(height: 300)
                }
                Text(l10n("onboarding.homeHint")).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.pixel())
        .foregroundStyle(theme.text)
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(theme.surfaceRaised)
        .pixelBorder(theme.border)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PixelToggleStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack {
                    Rectangle().fill(configuration.isOn ? theme.selectedFill : theme.background)
                    if configuration.isOn { Text("✓").foregroundStyle(theme.selectedText) }
                }
                .frame(width: 20, height: 20)
                .pixelBorder(theme.border)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "1" : "0"))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
