import SwiftUI
import VoyageCore

struct JourneyStatusDisplay {
    let title: String
    let detail: String
    let progress: Double?

    init(journey: JourneyState, now: Date, catalog: CityCatalog, l10n: L10n) {
        let home = l10n.cityName(catalog.city(journey.homeCityId))
        let target = l10n.cityName(catalog.city(journey.targetCityId))
        switch journey.phase {
        case .home:
            title = l10n("journey.status.home", home)
            detail = l10n("journey.status.next", target, Format.km(journey.legKm))
            progress = nil
        case .pending:
            title = l10n("journey.status.pending", home, target)
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(30 * 60).timeIntervalSince(now) / 60)))
            detail = l10n("journey.status.departure", Format.km(journey.legKm), minutes)
            progress = nil
        case .outbound:
            title = l10n("journey.status.outbound", home, target)
            detail = l10n("journey.remaining", Format.km(journey.remainingKm))
            progress = journey.legProgress
        case .staying:
            title = l10n("journey.status.staying", l10n.cityName(catalog.city(journey.currentCityId)))
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(6 * 3600).timeIntervalSince(now) / 60)))
            detail = l10n("journey.status.stayTime", minutes / 60, minutes % 60)
            progress = nil
        case .returning:
            title = l10n("journey.status.returning", l10n.cityName(catalog.city(journey.currentCityId)), home)
            detail = l10n("journey.remaining", Format.km(journey.remainingKm))
            progress = journey.legProgress
        }
    }
}

struct MapLegend: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { labels }
            VStack(alignment: .leading, spacing: 6) { labels }
        }
        .font(Theme.pixel()).foregroundStyle(theme.textMuted)
    }

    @ViewBuilder private var labels: some View {
        label(l10n("map.home"), color: theme.mapMarker, size: 9)
        label(l10n("map.current"), color: theme.mapPosition, size: 6)
        label(l10n("map.stayed"), color: theme.mapStayed, size: 3)
    }

    private func label(_ text: String, color: Color, size: CGFloat) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: size, height: size).frame(width: 9, height: 9)
            Text(text)
        }
    }
}

struct JourneyMetric: View {
    @Environment(\.theme) private var theme
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.pixel()).foregroundStyle(theme.textMuted)
            Text(value).font(Theme.pixel(24)).foregroundStyle(color)
            Text(detail).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
    }
}

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
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
    }
}
