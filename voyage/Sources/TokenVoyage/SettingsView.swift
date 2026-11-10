import AppKit
import SwiftUI
import VoyageCore

struct SettingsTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    @Bindable var model: AppModel
    @State private var homeSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("settings.language") {
                row("settings.interfaceAndLetters") {
                    Picker(l10n("settings.language"), selection: $model.languagePreference) {
                        ForEach(LanguagePreference.allCases, id: \.self) { preference in
                            Text(l10n(L10n.languageKeys[preference]!)).tag(preference)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }
            group("settings.appearance") {
                row("settings.appearance") {
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
                    .labelsHidden().pickerStyle(.menu)
                }
            }
            group("settings.display") {
                Toggle(l10n("settings.notch"), isOn: $model.notchEnabled)
                Toggle(l10n("settings.floating"), isOn: $model.floatingEnabled)
                Toggle(l10n("settings.login"), isOn: Binding(get: { model.loginItem.enabled }, set: { model.loginItem.setEnabled($0) }))
                if let key = model.loginItem.explanationKey { explanation(key) }
            }
            group("settings.notifications") {
                Toggle(l10n("settings.morningMail"), isOn: $model.morningNotificationsEnabled)
                row("settings.deliveryTime") {
                    Picker(l10n("settings.deliveryTime"), selection: $model.deliveryTime) {
                        ForEach(DeliveryTime.allCases, id: \.self) { time in Text(time.rawValue).tag(time) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                explanation("settings.deliveryHint")
                Text(l10n(Self.authorizationKey(model.notifications.authorization)))
                    .fixedSize(horizontal: false, vertical: true)
                if model.notifications.authorization == .denied || model.notifications.authorization == .unavailable {
                    action("settings.openSystemSettings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .task { if !model.isSnapshotMode { await model.notifications.refreshAuthorization() } }
            group("settings.accountPrivacy") {
                action("accounts.manage") { model.showingAccounts = true }
                Toggle(l10n("settings.cityContent"), isOn: $model.cityContentEnabled)
                    .accessibilityLabel(l10n("settings.cityContent"))
                    .accessibilityHint(l10n("settings.cityContentHint"))
                    .accessibilityIdentifier("settings.cityContentEnabled")
                Toggle(l10n("settings.wishResolve"), isOn: $model.wishResolveEnabled)
                    .accessibilityLabel(l10n("settings.wishResolve"))
                    .accessibilityHint(l10n("settings.wishResolveHint"))
                    .accessibilityIdentifier("settings.wishResolveEnabled")
                if model.encountersAvailable {
                    Toggle(l10n("settings.encounters"), isOn: Binding(
                        get: { model.encountersEnabled },
                        set: { model.requestEncountersEnabled($0) }
                    ))
                    .accessibilityHint(l10n("settings.encountersHint"))
                    .accessibilityIdentifier("settings.encountersEnabled")
                }
            }
            if model.canChangeStart, let state = model.state, let catalog = model.catalog {
                group("settings.home") {
                    CitySearchList(catalog: catalog,
                                   selection: Binding(get: { state.homeCityId }, set: { model.setStart($0) }), search: $homeSearch)
                        .frame(height: 300)
                    let home = catalog.city(state.homeCityId)
                    GeometryReader { geometry in
                        PixelMapView(image: PixelMap.homeImage(home, theme: theme), availableWidth: geometry.size.width,
                                     borderColor: theme.mapBorder)
                            .accessibilityLabel(l10n("onboarding.homeMap", l10n.cityName(home)))
                    }
                    .frame(height: 200)
                    explanation("onboarding.homeHint")
                }
            }
            group("settings.data") {
                action("settings.export") { SaveArchivePanels.exportSave(model: model) }
                action("settings.import") { SaveArchivePanels.importSave(model: model) }
                explanation("settings.exportHint")
                action("settings.openDataFolder") { model.openDataFolder() }
                if let error = model.archiveError {
                    Text(l10n.archiveError(error)).foregroundStyle(theme.quotaLowText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            group("settings.about") {
                Text(l10n("settings.version", AppModel.appVersion))
                DisclosureGroup(l10n("settings.licenses")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Link("tokscale · MIT", destination: URL(string: "https://github.com/junhoyeo/tokscale/blob/main/LICENSE")!)
                        Link("Fusion Pixel · OFL-1.1", destination: URL(string: "https://github.com/TakWolf/fusion-pixel-font/blob/master/LICENSE-OFL")!)
                        Link(l10n("settings.naturalEarth"), destination: URL(string: "https://www.naturalearthdata.com/about/terms-of-use/")!)
                        Link("Wikipedia · CC BY-SA 4.0", destination: URL(string: "https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                explanation("settings.privacy")
            }
        }
        .toggleStyle(PixelToggleStyle())
        .font(Theme.pixel())
        .foregroundStyle(theme.text)
        .frame(maxWidth: 580, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.showingEncounterConsent) {
            EncounterConsentView(onConfirm: { model.confirmEncounterConsent() },
                                 onCancel: { model.showingEncounterConsent = false })
                .localized(using: model)
        }
        .confirmationDialog(l10n("encounter.optOutTitle"), isPresented: $model.showingEncounterOptOut,
                            titleVisibility: .visible) {
            Button(l10n("encounter.disableKeep")) { model.disableEncounters(deleteRecords: false) }
            Button(l10n("encounter.disableDelete"), role: .destructive) { model.disableEncounters(deleteRecords: true) }
            Button(l10n("encounter.cancel"), role: .cancel) {}
        } message: {
            Text(l10n("encounter.optOutBody"))
        }
    }

    static func authorizationKey(_ status: NotificationAuthorization) -> String {
        switch status {
        case .notDetermined: "settings.authorizationNotRequested"
        case .authorized: "settings.authorizationGranted"
        case .denied: "settings.authorizationDenied"
        case .unavailable: "settings.authorizationUnavailable"
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n(title)).foregroundStyle(theme.textMuted)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised).pixelBorder(theme.border)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(l10n(title)).fixedSize(); Spacer(minLength: 12); control().fixedSize() }
            VStack(alignment: .leading, spacing: 8) { Text(l10n(title)); control() }
        }
    }

    private func explanation(_ key: String) -> some View {
        Text(l10n(key)).foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
    }

    private func action(_ key: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(l10n(key)).fixedSize(horizontal: false, vertical: true)
                .padding(8).pixelBorder(theme.border)
        }
        .buttonStyle(.plain)
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
