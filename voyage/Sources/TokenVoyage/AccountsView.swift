import SwiftUI
import VoyageCore

struct AccountsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(l10n("accounts.title"))
                Spacer()
                Chip(title: l10n("action.close"), isOn: false) { model.showingAccounts = false }
            }
            Text(l10n("accounts.privacy")).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(QuotaSource.allCases) { source in
                let account = model.quotaRuntime.account(source)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(source.name(l10n))
                        Spacer()
                        Text(account.linked ? l10n("accounts.linked") : l10n("accounts.notLinked"))
                            .foregroundStyle(theme.textMuted)
                        if account.linked || account.isRefreshing {
                            Chip(title: l10n("accounts.disconnect"), isOn: false) { model.quotaRuntime.disconnect(source) }
                        } else {
                            Chip(title: l10n("accounts.link"), isOn: false) { Task { await model.linkQuota(source) } }
                        }
                    }
                    Text(l10n.quotaStatus(account.status, source: source))
                        .foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    if account.isRefreshing { Text(l10n("quota.loading")).foregroundStyle(theme.textMuted) }
                    if !account.linked {
                        Text(source == .otherTools ? l10n("accounts.tokscaleConsent") : l10n("accounts.localConsent", source.name(l10n)))
                            .foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
                        if source == .claude {
                            Text(l10n("accounts.keychainConsent")).foregroundStyle(theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .background(theme.surfaceRaised)
                .pixelBorder(theme.border)
            }
        }
        .font(Theme.pixel())
        .foregroundStyle(theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }
}

extension L10n {
    func quotaStatus(_ status: QuotaStatus, source: QuotaSource) -> String {
        switch status {
        case .notLinked: self("quota.notLinked")
        case .ok: self("quota.ok")
        case .stale(let date): self("quota.stale", quotaTimestamp(date))
        case .expired: self("quota.expired", source.name(self))
        case .rateLimited(let until): until.map { self("quota.rateLimitedUntil", quotaTimestamp($0)) } ?? self("quota.rateLimited")
        case .unavailable(let reason):
            self("quota.failed", quotaReason(reason))
        }
    }

    func quotaReason(_ reason: QuotaUnavailable) -> String {
        switch reason {
        case .missingLogin: self("quota.missingLogin")
        case .invalidResponse: self("quota.invalidResponse")
        case .network: self("quota.network")
        case .timedOut: self("quota.timedOut")
        case .service: self("quota.service")
        case .localSource: self("quota.localSource")
        }
    }

    func quotaWindow(_ kind: QuotaWindowKind) -> String {
        switch kind {
        case .session: self("quota.session")
        case .weekly: self("quota.weekly")
        case .daily: self("quota.daily")
        case .monthly: self("quota.monthly")
        case .weeklySonnet: self("quota.weeklySonnet")
        case .weeklyOpus: self("quota.weeklyOpus")
        case .other: self("quota.otherWindow")
        }
    }

    func quotaTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
