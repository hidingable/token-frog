import Foundation
import VoyageCore

struct LetterText: Equatable, Sendable {
    var title: String
    var voice: String
    var lead: String? = nil
    var signature: String
    var itinerary: [String]
}

/// Story snapshots and legacy semantic templates both render in the current language.
enum LetterComposer {
    /// Encounter mail has its own ID space and never occupies an ordinary mail number.
    static func number(for letter: Letter, letters: [Letter]) -> Int? {
        guard ![.postcard, .reunion, .weekly, .identity, .adventure].contains(letter.kind) else { return nil }
        let companions = Set(letters.filter { $0.encounter == nil && [.postcard, .reunion, .weekly, .identity, .adventure].contains($0.kind) && $0.id < letter.id }.map(\.id))
        return letter.id - companions.count
    }

    static func origin(for letter: Letter, letters: [Letter], l10n: L10n, catalog: CityCatalog) -> String {
        if let number = number(for: letter, letters: letters) {
            return l10n("collection.origin", number, l10n.cityName(catalog.city(letter.cityId)))
        }
        return l10n("collection.companionOrigin", companionTitle(letter, l10n: l10n))
    }

    static func citation(for letter: Letter, letters: [Letter], l10n: L10n) -> String {
        if let number = number(for: letter, letters: letters) { return l10n("memory.citedLetter", number) }
        return l10n("memory.citedCompanion", companionTitle(letter, l10n: l10n))
    }

    private static func companionTitle(_ letter: Letter, l10n: L10n) -> String {
        if letter.encounter != nil { return l10n("encounter.postcardTitle") }
        return switch letter.kind {
        case .postcard: l10n("letter.postcardTitle")
        case .weekly: l10n("letter.weeklyTitle")
        case .identity: l10n("identity.letterTitle")
        case .adventure: l10n("friends.letterTitle")
        default: l10n("letter.reunionTitle")
        }
    }

    static func localized(_ texts: [String: String]?, l10n: L10n) -> String? {
        guard let texts else { return nil }
        return [l10n.language.rawValue, "en", "zh-Hans"].lazy.compactMap { texts[$0] }.first { !$0.isEmpty }
    }

    static func sponsorTags(for letter: Letter, l10n: L10n, letters: [Letter] = []) -> [String] {
        var sponsors = [letter.sponsor].compactMap { $0 } + letter.arrivalStories.compactMap(\.sponsor)
        if let replyId = letter.fulfilledReplyId,
           let source = letters.first(where: { $0.id < letter.id && $0.replyOptions.contains { $0.id == replyId } }) {
            sponsors += [source.sponsor].compactMap { $0 } + source.arrivalStories.compactMap(\.sponsor)
        }
        var seen: Set<String> = []
        return sponsors.filter { seen.insert($0.id).inserted }.compactMap { l10n.sponsorTag($0) }
    }

    static func place(for letter: Letter, l10n: L10n) -> Letter.Place? {
        letter.place[l10n.language.rawValue]
    }

    static func text(for letter: Letter, l10n: L10n, petName: String, catalog: CityCatalog, letters: [Letter] = []) -> LetterText {
        let city = catalog.city(letter.cityId)
        let signature = l10n("letter.signature", petName)
        if let encounter = letter.encounter {
            return LetterText(title: l10n("encounter.postcardCityTitle", l10n.cityName(catalog.city(encounter.cityId))),
                              voice: localized(letter.texts, l10n: l10n) ?? "", signature: signature, itinerary: [])
        }
        if letter.kind == .logbook {
            let title = letter.logbook == nil ? l10n("letter.welcomeTitle") : l10n("letter.logbookTitle")
            return LetterText(title: title, voice: logbookVoice(letter.logbook, l10n: l10n), signature: signature,
                              itinerary: letter.logbook == nil ? [] : [l10n("letter.logbookSource")])
        }
        if letter.kind == .departure {
            return LetterText(
                title: l10n("letter.departureTitle", l10n.cityName(city)),
                voice: l10n("letter.departureBody", l10n.cityName(city)),
                signature: signature,
                itinerary: [l10n("letter.mileageRule")]
            )
        }
        if [.postcard, .reunion, .weekly, .identity, .adventure].contains(letter.kind) {
            return LetterText(title: companionTitle(letter, l10n: l10n),
                              voice: localized(letter.texts, l10n: l10n) ?? "",
                              lead: localized(letter.leadTexts, l10n: l10n), signature: signature, itinerary: [])
        }
        let target = letter.transitTargetId.map { catalog.city($0) }
        let number = number(for: letter, letters: letters)!
        let title = target.map { l10n("letter.transitTitle", number, l10n.cityName($0)) }
            ?? l10n("letter.dailyTitle", number, l10n.cityName(city))
        return LetterText(
            title: title,
            voice: letter.texts.map { localized($0, l10n: l10n) ?? "" }
                ?? voice(letter, city: city, target: target, l10n: l10n, catalog: catalog),
            lead: localized(letter.leadTexts, l10n: l10n),
            signature: signature, itinerary: itinerary(letter, l10n: l10n, catalog: catalog)
        )
    }

    static func logbookVoice(_ logbook: Logbook?, l10n: L10n) -> String {
        guard let logbook else { return l10n("letter.welcomeBody") }
        var parts = [l10n("letter.logbookOpening")]
        if let hour = logbook.workdayStartHour { parts.append(l10n("letter.logbookWorkday", l10n.hour(hour))) }
        if let quiet = logbook.isWeekendQuiet {
            parts.append(quiet ? l10n("letter.logbookQuietWeekend") : l10n("letter.logbookBusyWeekend"))
        }
        if logbook.topClients.count >= 2 {
            parts.append(l10n("letter.logbookTwoClients", Vehicle.toolName(logbook.topClients[0]), Vehicle.toolName(logbook.topClients[1])))
        } else if let client = logbook.topClients.first {
            parts.append(l10n("letter.logbookOneClient", Vehicle.toolName(client)))
        }
        parts.append(l10n("letter.logbookClosing"))
        return parts.joined(separator: l10n.language == .zhHans ? "" : " ")
    }

    private static func voice(_ letter: Letter, city: City, target: City?, l10n: L10n, catalog: CityCatalog) -> String {
        let quirks = catalog.pets.find(letter.pet)?.quirks
        let quirk = quirks.flatMap { localized($0[letter.id % $0.count], l10n: l10n) } ?? ""
        if let target { return l10n("letter.transitBody", l10n.cityName(target), quirk) }
        var parts: [String] = []
        if letter.isDeepVisit {
            parts.append(l10n("letter.deepVisit", l10n.cityName(city)))
        } else if letter.arrivals.count > 1 {
            let passed = letter.arrivals.dropLast().map { l10n.cityName(catalog.city($0)) }.joined(separator: l10n("letter.citySeparator"))
            parts.append(l10n("letter.longTrip", passed, l10n.cityName(city)))
        } else {
            parts.append(l10n("letter.arrived", l10n.cityName(city)))
        }
        if let country = letter.newCountries.last { parts.append(l10n("letter.newStamp", l10n.countryName(catalog.countryNames(country)))) }
        if !quirk.isEmpty { parts.append(quirk) }
        return parts.joined(separator: l10n.language == .zhHans ? "" : " ")
    }

    private static func itinerary(_ letter: Letter, l10n: L10n, catalog: CityCatalog) -> [String] {
        var lines = [l10n("letter.fuel", l10n.tokens(letter.tokens ?? letter.fuel), Format.km(letter.km))]
        if let percent = letter.compareToMedianPercent {
            if percent == 0 { lines.append(l10n("letter.usual")) }
            else if percent > 0 { lines.append(l10n("letter.more", percent)) }
            else { lines.append(l10n("letter.less", -percent)) }
        }
        if !letter.vehicles.isEmpty {
            lines.append(letter.vehicles.map { l10n("vehicle.share", l10n.vehicle($0.client), $0.percent) }.joined(separator: " · "))
        }
        for country in letter.newCountries {
            lines.append(l10n("letter.newStamp", l10n.countryName(catalog.countryNames(country))))
        }
        if let id = letter.carriedItem, let item = catalog.items.find(id) {
            lines.append(l10n("letter.carriedItem", l10n.itemName(item)))
        }
        if letter.arrivals.count > 1 {
            let passed = letter.arrivals.filter { $0 != letter.cityId }
                .map { l10n.cityName(catalog.city($0)) }.joined(separator: l10n("letter.citySeparator"))
            if !passed.isEmpty { lines.append(l10n("letter.passed", passed)) }
        }
        return lines
    }

}
