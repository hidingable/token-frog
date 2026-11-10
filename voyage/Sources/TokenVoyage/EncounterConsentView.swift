import SwiftUI

/// Kept independent of AppModel so consent can be rendered without enabling any request.
struct EncounterConsentView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n("encounter.consentTitle")).font(Theme.pixel(24))
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("encounter.consentBody")).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                disclosure(l10n("encounter.registeredLabel"), l10n("encounter.registeredValue"))
                disclosure(l10n("encounter.notSentLabel"), l10n("encounter.notSentValue"))
                disclosure(l10n("encounter.syncedLabel"), l10n("encounter.syncedValue"))
            }
            .padding(14).background(theme.surface).pixelBorder(theme.border)
            Text(l10n("encounter.canDelete")).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button(l10n("encounter.cancel"), action: onCancel).buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    Text(l10n("encounter.confirm"))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(theme.actionText).background(theme.actionFill).pixelBorder(theme.border)
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("encounter.confirmConsent")
            }
        }
        .font(Theme.pixel()).foregroundStyle(theme.text)
        .padding(24).frame(width: 480).background(theme.surfaceRaised)
    }

    private func disclosure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(value).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
