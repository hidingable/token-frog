import SwiftUI
import VoyageCore

struct FootprintsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let footprints: Footprints
    let catalog: CityCatalog
    let openPassport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(l10n("footprints.title")).font(Theme.pixel(24))
                Spacer()
                Button(action: openPassport) { Text(l10n("footprints.passport")).font(Theme.pixel()).underline() }
                    .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                tile(l10n("footprints.mostVisited"), city: footprints.mostVisited.cityId,
                     detail: footprints.mostVisited.count == 0 ? nil
                        : footprints.mostVisited.count == 1 ? l10n("footprints.stay", "1")
                        : l10n("footprints.stays", Format.grouped(footprints.mostVisited.count)))
                tile(l10n("footprints.farthest"), city: footprints.farthest?.cityId,
                     detail: footprints.farthest.map { l10n("footprints.distance", Format.km($0.km)) },
                     empty: l10n("footprints.farthestEmpty"))
                tile(l10n("footprints.mostMemorable"), city: footprints.mostMemorable?.cityId,
                     detail: footprints.mostMemorable.map { $0.count == 1 ? l10n("footprints.memory", "1") : l10n("footprints.memories", Format.grouped($0.count)) },
                     empty: l10n("footprints.memorableEmpty"))
            }
        }
        .foregroundStyle(theme.text)
        .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
    }

    private func tile(_ title: String, city: String?, detail: String?, empty: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.pixel()).foregroundStyle(theme.textMuted)
            Text(city.map { l10n.cityName(catalog.city($0)) } ?? empty).font(.system(size: 16, weight: .semibold))
            if let detail { Text(detail).font(Theme.pixel()).foregroundStyle(theme.textMuted) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct RoadClueView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n("journey.roadClue")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
            Text(text ?? l10n("journey.roadClueEmpty")).font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
    }
}
