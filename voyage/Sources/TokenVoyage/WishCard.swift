import SwiftUI
import VoyageCore

struct WishCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let care: CareState
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HomeCard {
            HStack(alignment: .top) {
                Text(l10n("wish.title"))
                Spacer(minLength: 8)
                Text(l10n("wish.optional")).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editing {
                TextField(l10n("wish.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain)
                    .disabled(model.isSavingWish)
                    .padding(10).background(theme.background).pixelBorder(theme.border)
                    .accessibilityLabel(l10n("wish.title"))
                    .onChange(of: draft) { _, value in
                        if value.count > WishEngine.characterLimit { draft = String(value.prefix(WishEngine.characterLimit)) }
                    }
                HStack {
                    Text(l10n("wish.count", draft.count, WishEngine.characterLimit)).foregroundStyle(theme.textMuted)
                    Spacer()
                    Button(l10n("wish.cancel")) { editing = false }
                    Button(l10n(model.isSavingWish ? "wish.saving" : "wish.save")) {
                        Task { if await model.setWish(draft) { editing = false } }
                    }
                }
                .disabled(model.isSavingWish)
            } else {
                Text(verbatim: care.wish ?? l10n("wish.empty"))
                    .foregroundStyle(care.wish == nil ? theme.textMuted : theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(theme.background).pixelBorder(theme.border)
                HStack {
                    Button(l10n(care.wish == nil ? "wish.write" : "wish.edit")) {
                        draft = care.wish ?? ""
                        editing = true
                    }
                    if care.wish != nil {
                        Button(l10n("wish.clear")) { Task { await model.setWish("") } }
                    }
                }
                .disabled(model.isSavingWish)
            }
            Text(l10n("wish.hint")).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("wish.privacy")).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: care.wishResolution?.weekStart) { _, _ in
            // An open editor follows the local Monday reset as well.
            if care.wish == nil { draft = ""; editing = false }
        }
    }
}
