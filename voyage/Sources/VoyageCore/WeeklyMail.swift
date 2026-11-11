import Foundation

public struct WeeklyMailSummary: Codable, Equatable, Sendable {
    public struct Highlight: Codable, Equatable, Sendable {
        public var kind: String
        public var date: String
        public var letterId: Int?
    }

    public var weekStart: String
    public var weekEnd: String
    public var fuel: Int
    public var byClient: [String: Int]
    public var previousFuel: Int?
    public var highlight: Highlight?
}

/// Authored copy is validated before use; rendered bilingual text lives in each saved letter.
public struct WeeklyMailContent: Codable, Sendable {
    var version: Int
    var openings: [[String: String]]
    var closings: [[String: String]]
    var lines: [String: [String: String]]

    static let slots: [String: Set<String>] = [
        "summary": ["start", "end", "distance"], "tools": ["tools"], "noTools": [],
        "trendUp": ["percent"], "trendDown": ["percent"], "trendSame": [], "trendFromZero": [],
        "fulfilled": ["event"], "rare": ["event"], "country": ["event"],
        "longest": ["date", "distance"], "quiet": [],
    ]

    static func load(directory: URL) throws -> WeeklyMailContent {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("weekly-mail.json")))
        func valid(_ texts: [String: String], slots: Set<String>) -> Bool {
            ["zh-Hans", "en"].allSatisfy { language in
                guard let text = texts[language], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                let literal = StorySlots.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                return StorySlots.names(in: text) == slots && !literal.contains("{") && !literal.contains("}")
            }
        }
        guard content.version > 0, !content.openings.isEmpty, !content.closings.isEmpty,
              (content.openings + content.closings).allSatisfy({ valid($0, slots: []) }),
              slots.allSatisfy({ valid(content.lines[$0.key] ?? [:], slots: $0.value) }) else {
            throw ContentValidationError(issues: [.init(file: "weekly-mail.json", rule: "weeklyMail", message: "Complete bilingual copy with matching supported slots is required")])
        }
        return content
    }
}

/// Saved in the letter's own language, so dates read as prose rather than storage keys.
private func letterDay(_ key: String, language: String, calendar: Calendar) -> String {
    guard let date = DayKey.date(from: key, calendar: calendar) else { return key }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: language)
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: date)
}

extension JourneyState {
    /// Only legacy saves need activation. Even an upgrade on Sunday starts next Sunday.
    public mutating func enableWeeklyMail(on date: String, calendar: Calendar = .current) {
        guard weeklyMailEligibleFrom == nil, let day = DayKey.date(from: date, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 7 - (calendar.component(.weekday, from: day) - 1), to: day) else { return }
        weeklyMailEligibleFrom = DayKey.string(from: next, calendar: calendar)
    }
}

extension CareEngine {
    /// Call only after a successful sync and care processing: all six days and their stories are final.
    /// The latest due Sunday is the sole candidate, so returning never produces a weekly backlog.
    public static func writeWeeklyMail(
        journey: inout JourneyState, catalog: CityCatalog,
        calendar: Calendar = .current, deliveryTime: DeliveryTime = .standard
    ) {
        journey.enableWeeklyMail(on: journey.openDate, calendar: calendar)
        guard let today = DayKey.date(from: journey.openDate, calendar: calendar),
              let sunday = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: today) - 1), to: today),
              let deliverAt = calendar.date(bySettingHour: deliveryTime.hour, minute: deliveryTime.minute, second: 0, of: sunday) else { return }
        let sundayKey = DayKey.string(from: sunday, calendar: calendar)
        guard sundayKey >= journey.weeklyMailEligibleFrom!, sundayKey > (journey.lastWeeklyMailSunday ?? "") else { return }
        journey.lastWeeklyMailSunday = sundayKey
        guard !journey.letters.contains(where: { $0.kind == .weekly && $0.date == sundayKey }) else { return }
        func key(_ offset: Int) -> String {
            DayKey.string(from: calendar.date(byAdding: .day, value: offset, to: sunday)!, calendar: calendar)
        }
        let keys = (-6 ... -1).map(key)
        let records = keys.compactMap { journey.days[$0] }
        guard records.contains(where: { ($0.tokens ?? $0.fuel) > 0 || $0.mainWindowOpened }) else { return }
        let fuel = records.reduce(0) { $0 + $1.fuel }
        let km = records.reduce(0.0) { $0 + $1.km }
        let clients = records.reduce(into: [String: Int]()) { total, record in
            for (client, value) in record.byClient where value > 0 { total[client, default: 0] += value }
        }
        let previousKeys = (-13 ... -8).map(key)
        let previousFuel = previousKeys.allSatisfy { journey.days[$0] != nil }
            ? previousKeys.reduce(0) { $0 + journey.fuel(on: $1) } : nil
        let previousKm = previousKeys.allSatisfy { journey.days[$0] != nil }
            ? previousKeys.reduce(0.0) { $0 + journey.days[$1]!.km } : nil
        let events = journey.letters.filter {
            $0.date >= keys[0] && $0.date <= keys[5] && $0.deliverAt <= deliverAt && $0.kind != .weekly && !$0.hasSponsoredContent
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let content = catalog.weeklyMail
        var highlight: WeeklyMailSummary.Highlight?
        var eventTexts: [String: String] = [:]
        var eventKey = "quiet"
        func complete(_ texts: [String: String]) -> Bool { ["zh-Hans", "en"].allSatisfy { texts[$0]?.isEmpty == false } }
        if let letter = events.first(where: { $0.fulfilledReplyId != nil && complete($0.learnedTexts) }) {
            highlight = .init(kind: "fulfilled", date: letter.date, letterId: letter.id)
            eventTexts = letter.learnedTexts
            eventKey = "fulfilled"
        } else if let event = events.lazy.compactMap({ letter -> (Letter, Item)? in
            guard letter.rewards.dropRarity == "rare",
                  let item = letter.rewardItems.first ?? letter.rewards.itemIds.compactMap({ catalog.items.find($0) }).first,
                  complete(item.names) else { return nil }
            return (letter, item)
        }).first {
            highlight = .init(kind: "rare", date: event.0.date, letterId: event.0.id)
            eventTexts = event.1.names
            eventKey = "rare"
        } else if let date = keys.first(where: { journey.days[$0]?.newCountries.isEmpty == false }),
                  let country = journey.days[date]?.newCountries.first,
                  let names = catalog.countryNames(country), complete(names) {
            highlight = .init(kind: "country", date: date, letterId: nil)
            eventTexts = names
            eventKey = "country"
        } else if let date = keys.filter({ (journey.days[$0]?.km ?? 0) > 0 }).sorted(by: {
            journey.days[$0]!.km == journey.days[$1]!.km ? $0 < $1 : journey.days[$0]!.km > journey.days[$1]!.km
        }).first {
            highlight = .init(kind: "longest", date: date, letterId: nil)
            eventKey = "longest"
        }
        var random = SplitMix64(seed: sundayKey.utf8.reduce(journey.seed) { ($0 &* 31) &+ UInt32($1) }, stopCount: 0)
        let opening = content.openings[Int(random.next() % UInt64(content.openings.count))]
        let closing = content.closings[Int(random.next() % UInt64(content.closings.count))]
        let total = clients.values.reduce(0, +)
        let vehicles = clients.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map {
            VehicleShare(client: $0.key, percent: Int((Double($0.value) / Double(max(1, total)) * 100).rounded()))
        }
        var letter = Letter(
            id: journey.nextLetterID, kind: .weekly, date: sundayKey,
            pet: journey.pet, cityId: journey.currentCityId, arrivals: [], newCountries: [], fuel: fuel,
            tokens: records.reduce(0) { $0 + ($1.tokens ?? 0) },
            vehicles: vehicles, isDeepVisit: false, deliverAt: deliverAt, enrichmentDone: true
        )
        letter.weeklySummary = .init(weekStart: keys[0], weekEnd: keys[5], fuel: fuel, byClient: clients, previousFuel: previousFuel, highlight: highlight)
        letter.storyVersion = content.version
        letter.texts = ["zh-Hans", "en"].reduce(into: [:]) { result, language in
            func line(_ id: String, _ values: [String: String] = [:]) -> String {
                var text = StorySlots.render(content.lines[id]![language]!, values: values)
                if id == "fulfilled", let ending = text.last, !"。！？.!?…".contains(ending) {
                    text += language == "zh-Hans" ? "。" : "."
                }
                return text
            }
            var parts = [opening[language]!, line("summary", ["start": letterDay(keys[0], language: language, calendar: calendar), "end": letterDay(keys[5], language: language, calendar: calendar), "distance": Format.km(km)])]
            parts.append(vehicles.isEmpty ? line("noTools") : line("tools", ["tools": vehicles.map { "\(Vehicle.toolName($0.client)) \($0.percent)%" }.joined(separator: " · ")]))
            if let previousKm {
                if previousKm == km { parts.append(line("trendSame")) }
                else if previousKm == 0 { parts.append(line("trendFromZero")) }
                else {
                    let percent = Int((abs(km / previousKm - 1) * 100).rounded())
                    parts.append(line(km > previousKm ? "trendUp" : "trendDown", ["percent": String(percent)]))
                }
            }
            if eventKey == "longest", let highlight {
                parts.append(line(eventKey, ["date": letterDay(highlight.date, language: language, calendar: calendar), "distance": Format.km(journey.days[highlight.date]!.km)]))
            } else {
                parts.append(line(eventKey, ["event": eventTexts[language] ?? ""]))
            }
            parts.append(closing[language]!)
            result[language] = parts.joined(separator: "\n\n")
        }
        journey.letters.append(letter)
    }
}
