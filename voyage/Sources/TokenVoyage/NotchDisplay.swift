import Foundation
import VoyageCore

struct NotchDisplay {
    let status: String
    let destination: String
    let showsFlag: Bool
    let petFacesLeft: Bool
    let pending: Pending?

    struct Pending {
        let destination: String
        let distanceAndBand: String
        let countdown: String
        let carriedItemID: String?
    }

    func accessibilityLabel(unread: Int, l10n: L10n) -> String {
        unread > 0 ? status + " · " + l10n("compact.mail", Format.grouped(unread)) : status
    }

    init(journey: JourneyState, care: CareState?, now: Date, catalog: CityCatalog, l10n: L10n) {
        let city = l10n.cityName(catalog.city(journey.targetCityId))
        let remaining = Format.km(journey.remainingKm)
        destination = city
        showsFlag = journey.phase == .staying || (journey.phase == .outbound && NotchStatus.isNearArrival(remainingKm: journey.remainingKm))
        petFacesLeft = journey.phase == .returning
        var preview: Pending?
        switch journey.phase {
        case .home:
            status = l10n("home.status.home")
        case .pending:
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(30 * 60).timeIntervalSince(now) / 60)))
            status = l10n("notch.pending", city, minutes)
            let band = DestinationPicker.previewBand(
                distanceKm: journey.homeCoordinate.distanceKm(to: catalog.city(journey.targetCityId).coordinate),
                medianKm: journey.homecoming?.medianKm ?? 0)
            let bandLabel = l10n(band == .reachableToday ? "notch.band.reachableToday" : "notch.band.wander")
            preview = Pending(destination: city,
                              distanceAndBand: l10n("notch.distanceAndBand", Format.km(journey.legKm), bandLabel),
                              countdown: l10n("notch.departureCountdown", minutes),
                              carriedItemID: care.flatMap {
                                  CareEngine.carriedItem(bag: $0.bag, seed: journey.seed, letterId: journey.nextLetterID)
                              })
        case .outbound:
            status = NotchStatus.isNearArrival(remainingKm: journey.remainingKm)
                ? l10n("journey.remaining", remaining) : l10n("compact.destination", city)
        case .staying:
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(6 * 3600).timeIntervalSince(now) / 60)))
            status = l10n("notch.staying", l10n.cityName(catalog.city(journey.currentCityId)), minutes / 60, minutes % 60)
        case .returning:
            status = l10n("notch.returning", remaining)
        }
        pending = preview
    }
}
