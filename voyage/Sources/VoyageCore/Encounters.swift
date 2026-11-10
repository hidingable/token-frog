import Foundation

public struct EncounterAppearance: Codable, Equatable, Sendable {
    public var species: String
    public var stage: String
    public init(species: String, stage: String) { self.species = species; self.stage = stage }
}

public struct EncounterPhoto: Codable, Equatable, Sendable {
    public var cityId: String
    public var partner: EncounterAppearance
    public var localDate: String
    public var own: EncounterAppearance
    public init(cityId: String, partner: EncounterAppearance, localDate: String, own: EncounterAppearance) {
        self.cityId = cityId; self.partner = partner; self.localDate = localDate; self.own = own
    }
}

/// A durable one-shot registration. An interrupted/failed POST is never retried by replay.
public struct EncounterStay: Codable, Equatable, Sendable {
    public var stayId: String
    public var cityId: String
    public var day: String
    public var endsAt: Date
    public var appearance: EncounterAppearance
    public var registered = false
    public var lastPollAt: Date?
    public var finalChecked = false
    public init(stayId: String, cityId: String, day: String, endsAt: Date, appearance: EncounterAppearance) {
        self.stayId = stayId; self.cityId = cityId; self.day = day; self.endsAt = endsAt; self.appearance = appearance
    }
}

public struct EncounterPostcardContent: Codable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var id: String
        public var texts: [String: String]
    }
    public var version: Int
    public var lines: [Line]

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("encounter-postcards.json")))
        guard content.version > 0, content.lines.count >= 4,
              Set(content.lines.map(\.id)).count == content.lines.count,
              content.lines.allSatisfy({ line in
                  !line.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["zh-Hans", "en"].allSatisfy {
                      guard let text = line.texts[$0] else { return false }
                      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !text.contains("{") && !text.contains("}") && !text.contains("<") && !text.contains(">")
                  }
              }) else {
            throw ContentValidationError(issues: [.init(file: "encounter-postcards.json", rule: "encounterPostcards",
                message: "At least four unique original bilingual literal lines are required")])
        }
        return content
    }

    func draw(seed: UInt32, cityID: String) -> Line {
        let citySeed = cityID.utf8.reduce(seed ^ 0xE8C0_17A5) { ($0 &* 31) &+ UInt32($1) }
        var random = SplitMix64(seed: citySeed, stopCount: 0)
        let ordered = lines.sorted { $0.id < $1.id }
        return ordered[Int(random.next() % UInt64(ordered.count))]
    }
}

extension JourneyState {
    public mutating func recordEncounter(_ photo: EncounterPhoto) {
        guard !(encounterPhotos ?? []).contains(where: { $0.cityId == photo.cityId }),
              !letters.contains(where: { $0.encounter?.cityId == photo.cityId }) else { return }
        encounterPhotos = (encounterPhotos ?? []) + [photo]
    }

    /// Invoked only by day settlement; no network, rewards or care processing is involved.
    mutating func settleEncounters(on date: String, content: EncounterPostcardContent,
                                  calendar: Calendar, deliveryTime: DeliveryTime) {
        let pending = (encounterPhotos ?? []).filter { photo in
            photo.localDate <= date && !letters.contains { $0.encounter?.cityId == photo.cityId }
        }.sorted { $0.cityId < $1.cityId }
        for photo in pending {
            let line = content.draw(seed: seed, cityID: photo.cityId)
            let next = DayKey.date(from: DayKey.next(date, calendar: calendar), calendar: calendar)!
            let deliverAt = calendar.date(bySettingHour: deliveryTime.hour, minute: deliveryTime.minute, second: 0, of: next)!
            // Keep ordinary IDs (and every gameplay random input) exactly as they were without encounters.
            let id = (letters.filter { $0.encounter != nil }.map(\.id).min() ?? Int.max) - 1
            var letter = Letter(id: id, kind: .postcard, date: date, pet: pet, cityId: photo.cityId,
                                arrivals: [], newCountries: [], fuel: 0, vehicles: [], isDeepVisit: false,
                                deliverAt: deliverAt, enrichmentDone: true, storyId: line.id,
                                storyVersion: content.version, texts: line.texts)
            letter.encounter = photo
            letters.append(letter)
        }
    }
}
