import Foundation
import VoyageCore

struct LetterText: Equatable, Sendable {
    var title: String
    var voice: String
    var signature: String
    var itinerary: [String]
}

/// M0 letters keep semantic data on disk and render in the current language on every read.
enum LetterComposer {
    static func text(for letter: Letter, l10n: L10n, petName: String, catalog: CityCatalog) -> LetterText {
        let city = catalog.city(letter.cityId)
        let signature = l10n("letter.signature", petName)
        if letter.kind == .departure {
            return LetterText(
                title: l10n("letter.departureTitle", l10n.cityName(city)),
                voice: l10n("letter.departureBody", l10n.cityName(city)),
                signature: signature,
                itinerary: [l10n("letter.mileageRule")]
            )
        }
        let target = letter.transitTargetId.map { catalog.city($0) }
        let title = target.map { l10n("letter.transitTitle", letter.id, l10n.cityName($0)) }
            ?? l10n("letter.dailyTitle", letter.id, l10n.cityName(city))
        return LetterText(title: title, voice: voice(letter, city: city, target: target, l10n: l10n, catalog: catalog), signature: signature, itinerary: itinerary(letter, l10n: l10n))
    }

    private static func voice(_ letter: Letter, city: City, target: City?, l10n: L10n, catalog: CityCatalog) -> String {
        let quirk = l10n(quirkKeys[letter.pet]![letter.id % 3])
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
        parts.append(quirk)
        return parts.joined(separator: l10n.language == .zhHans ? "" : " ")
    }

    private static func itinerary(_ letter: Letter, l10n: L10n) -> [String] {
        var lines = [l10n("letter.fuel", l10n.tokens(letter.fuel), Format.km(fuel: letter.fuel))]
        if let percent = letter.compareToMedianPercent {
            if percent == 0 { lines.append(l10n("letter.usual")) }
            else if percent > 0 { lines.append(l10n("letter.more", percent)) }
            else { lines.append(l10n("letter.less", -percent)) }
        }
        if !letter.vehicles.isEmpty {
            lines.append(letter.vehicles.map { l10n("vehicle.share", l10n.vehicle($0.client), $0.percent) }.joined(separator: " · "))
        }
        return lines
    }

    static let quirkKeys: [PetKind: [String]] = [
        .pigeon: ["letter.pigeon.hat", "letter.pigeon.bag", "letter.pigeon.clouds"],
        .snail: ["letter.snail.coins", "letter.snail.slow", "letter.snail.shell"],
        .suitcase: ["letter.suitcase.sticker", "letter.suitcase.clasps", "letter.suitcase.wheels"],
        .letter: ["letter.letter.fold", "letter.letter.wind", "letter.letter.postmark"],
    ]
}
