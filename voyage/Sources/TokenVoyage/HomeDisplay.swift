import Foundation
import VoyageCore

struct HomeStatusDisplay {
    let title: String
    let detail: String
    let fund: String?

    init(journey: JourneyState, care: CareState, now: Date, catalog: CityCatalog, l10n: L10n) {
        let city = l10n.cityName(catalog.city(journey.targetCityId))
        let fundText = l10n("home.status.fund", Format.km(journey.travelFundKm))
        switch journey.phase {
        case .home:
            title = journey.homecoming.map { l10n("home.status.returned", l10n.cityName(catalog.city($0.cityId))) }
                ?? l10n("home.status.home")
            let count = HomeFloor.parcels(journey: journey, care: care).count
            detail = count > 0 ? l10n(count == 1 ? "home.status.broughtOne" : "home.status.brought", count) : l10n("home.status.nextTrip")
            fund = fundText
        case .pending:
            title = l10n("home.status.pending", city)
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(30 * 60).timeIntervalSince(now) / 60)))
            let itemID = CareEngine.carriedItem(bag: care.bag, seed: journey.seed, letterId: journey.nextLetterID)
            let item = itemID.flatMap { catalog.items.find($0) }.map(l10n.itemName) ?? l10n("home.status.emptyBag")
            detail = l10n("home.status.departure", minutes, item)
            fund = nil
        case .outbound:
            title = l10n("home.status.outbound", city)
            detail = l10n("journey.remaining", Format.km(journey.remainingKm))
            fund = nil
        case .staying:
            let minutes = max(0, Int(ceil(journey.phaseSince.addingTimeInterval(6 * 3600).timeIntervalSince(now) / 60)))
            title = l10n("home.status.staying", l10n.cityName(catalog.city(journey.currentCityId)), minutes / 60, minutes % 60)
            detail = fundText
            fund = nil
        case .returning:
            title = l10n("home.status.returning", Format.km(journey.remainingKm))
            detail = fundText
            fund = nil
        }
    }
}

struct HomeFloorDisplay {
    struct Patch: Identifiable, Equatable {
        let id: String
        let firstStay: String
        var colorIndex: Int { HomeFloor.rugColorIndex(cityID: id) }
    }
    struct OldLine {
        let text: String
        let date: String
    }
    enum Crate: Equatable { case nailed(stampsNeeded: Int), ready, opened }

    let parcels: [HomeFloor.Parcel]
    let footprintLevel: Int
    let patches: [Patch]
    let looseBoard: OldLine?
    let crate: Crate

    init(journey: JourneyState, care: CareState, now: Date, catalog: CityCatalog, l10n: L10n, calendar: Calendar = .current) {
        let homecoming = journey.petIsHome ? journey.homecoming : nil
        let opened = Set(homecoming?.openedParcelIDs ?? [])
        parcels = Array(HomeFloor.parcels(journey: journey, care: care).filter { !opened.contains($0.id) }.prefix(3))
        if let homecoming {
            let ratio = homecoming.distanceKm / homecoming.medianKm
            footprintLevel = ratio <= 0.8 ? 1 : ratio <= 2 ? 2 : 3
        } else {
            footprintLevel = 0
        }

        var firstDates: [String: String] = [:]
        for (date, record) in journey.days.sorted(by: { $0.key < $1.key }) {
            for city in record.arrivals where firstDates[city] == nil { firstDates[city] = date }
        }
        for letter in journey.letters.sorted(by: { $0.date < $1.date }) {
            for city in letter.arrivals { firstDates[city] = min(firstDates[city] ?? letter.date, letter.date) }
        }
        var seen: Set<String> = []
        patches = Array(journey.route.compactMap { city -> Patch? in
            guard seen.insert(city).inserted, let date = firstDates[city] else { return nil }
            return Patch(id: city, firstStay: date)
        }.suffix(8))

        var oldLines: [OldLine] = []
        if let homecoming {
            let date = DayKey.string(from: homecoming.returnedAt, calendar: calendar)
            oldLines = MemoryBookDisplay(journey: journey, care: care, now: min(now, homecoming.returnedAt), l10n: l10n, catalog: catalog)
                .entries.filter { $0.date < date && $0.text != l10n("memory.unavailable") }
                .map { OldLine(text: $0.text, date: $0.date) }
            if oldLines.isEmpty {
                oldLines = journey.letters.filter { $0.date < date && $0.deliverAt <= min(now, homecoming.returnedAt) }
                    .sorted { $0.id < $1.id }.compactMap { letter in
                        LetterComposer.localized(letter.learnedTexts, l10n: l10n)
                            .flatMap { $0.components(separatedBy: .newlines).first }
                            .map { OldLine(text: $0, date: letter.date) }
                        ?? LetterComposer.localized(letter.texts ?? [:], l10n: l10n)
                            .flatMap { $0.components(separatedBy: .newlines).first }
                            .flatMap { $0.isEmpty ? nil : OldLine(text: $0, date: letter.date) }
                    }
            }
        }
        let roll = HomeFloor.looseBoardRoll(seed: journey.seed, tripCount: homecoming?.tripNumber ?? journey.tripCount)
        looseBoard = homecoming != nil && roll % 5 == 0 && !oldLines.isEmpty
            ? oldLines[Int(roll / 5 % UInt64(oldLines.count))] : nil

        let week = WeekDisplay(care: care, now: now, l10n: l10n, calendar: calendar)
        if week.pendingBoxes > 0 { crate = .ready }
        else if week.stampCount < 4 { crate = .nailed(stampsNeeded: 4 - week.stampCount) }
        else if week.stampCount < 6 { crate = .nailed(stampsNeeded: 6 - week.stampCount) }
        else { crate = .opened }
    }

    func crateLabel(l10n: L10n) -> String {
        switch crate {
        case .nailed(let count): l10n(count == 1 ? "floor.crate.nailedOne" : "floor.crate.nailed", count)
        case .ready: l10n("floor.crate.ready")
        case .opened: l10n("floor.crate.opened")
        }
    }
}
