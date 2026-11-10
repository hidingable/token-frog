import Foundation
import VoyageCore

struct NotchDisplay {
    let status: String
    let compactStatus: String
    let pending: Pending?
    let remainingAndFund: String

    struct Pending {
        let destination: String
        let distanceAndBand: String
        let countdown: String
        let carriedItemID: String?
    }

    init(journey: JourneyState, care: CareState?, now: Date, catalog: CityCatalog, l10n: L10n) {
        let city = l10n.cityName(catalog.city(journey.targetCityId))
        let remaining = Format.km(journey.remainingKm)
        remainingAndFund = l10n("notch.remainingAndFund", remaining, Format.km(journey.travelFundKm))
        var preview: Pending?
        switch journey.phase {
        case .home:
            status = l10n("home.status.home")
            compactStatus = status
        case .pending:
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(30 * 60).timeIntervalSince(now) / 60)))
            status = l10n("notch.pending", city, minutes)
            compactStatus = l10n("notch.departureCountdown", minutes)
            let band = DestinationPicker.previewBand(
                distanceKm: journey.homeCoordinate.distanceKm(to: catalog.city(journey.targetCityId).coordinate),
                medianKm: journey.homecoming?.medianKm ?? 0)
            let bandLabel = l10n(band == .reachableToday ? "notch.band.reachableToday" : "notch.band.wander")
            preview = Pending(destination: city,
                              distanceAndBand: l10n("notch.distanceAndBand", Format.km(journey.legKm), bandLabel),
                              countdown: l10n("notch.departureCountdown", minutes),
                              carriedItemID: care.flatMap {
                                  CareEngine.carriedItem(bag: $0.bag, seed: journey.seed, letterId: (journey.letters.map(\.id).max() ?? 0) + 1)
                              })
        case .outbound:
            status = NotchStatus.isNearArrival(remainingKm: journey.remainingKm)
                ? l10n("journey.remaining", remaining) : l10n("compact.destination", city)
            compactStatus = l10n("journey.remaining", remaining)
        case .staying:
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(6 * 3600).timeIntervalSince(now) / 60)))
            status = l10n("notch.staying", l10n.cityName(catalog.city(journey.currentCityId)), minutes / 60, minutes % 60)
            compactStatus = l10n("notch.stayCountdown", minutes / 60, minutes % 60)
        case .returning:
            status = l10n("notch.returning", remaining)
            compactStatus = status
        }
        pending = preview
    }
}
