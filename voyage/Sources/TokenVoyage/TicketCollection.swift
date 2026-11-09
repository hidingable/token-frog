import SwiftUI
import VoyageCore

struct TicketCollection: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let tickets: [ToolTicket]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("tickets.title")).font(Theme.pixel(24))
            if tickets.isEmpty {
                Text(l10n("tickets.empty")).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let ordered = tickets.sorted { $0.date == $1.date ? $0.toolID < $1.toolID : $0.date < $1.date }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { _, ticket in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "ticket").font(.system(size: 24)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Vehicle.toolName(ticket.toolID)).font(Theme.pixel(24))
                                Text(l10n("tickets.firstVoyage", l10n.day(ticket.date, full: true)))
                                    .foregroundStyle(theme.paperMuted)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).foregroundStyle(theme.paperText)
                        .background(theme.paper).pixelBorder(theme.paperBorder)
                    }
                }
            }
        }
        .font(Theme.pixel()).foregroundStyle(theme.text)
        .padding(.top, 12)
    }
}
