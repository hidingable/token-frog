import Foundation

/// Stable order is part of seeded settlement; content enumeration never changes a draw.
public enum TravellerIdentity: String, CaseIterable, Codable, Sendable {
    case liaison, sketcher, gourmet, collector, pathfinder, neighbour
}

/// Saved with the letter before care.json, so crash replay restores the original decision.
public struct IdentitySettlement: Codable, Equatable, Sendable {
    public let stage: Stage
    public let identity: TravellerIdentity
    public let previousIdentity: String?
    public let scores: [String: Int]
    public let names: [String: String]
}

public enum IdentityRules {
    public static let stages: [Stage] = [.traveler, .veteran, .legend]

    public static func scores(journey: JourneyState, care: CareState, catalog: CityCatalog) -> [TravellerIdentity: Int] {
        [
            .liaison: care.habits.talkative,
            .sketcher: care.habits.observant,
            .gourmet: Set(care.menus.map(\.id)).count * 3,
            .collector: Set(care.souvenirs.map(\.id)).count * 2,
            .pathfinder: Set(journey.stamps.map(\.countryCode)).count * 4,
            .neighbour: CityStays.all(journey: journey, catalog: catalog).filter(\.isRegular).count * 10,
        ]
    }

    /// Inclusive 90% boundary, using integer arithmetic to avoid rounding at the edge.
    public static func candidates(scores: [TravellerIdentity: Int]) -> [TravellerIdentity] {
        let top = scores.values.max()!
        return TravellerIdentity.allCases.filter { scores[$0]! * 10 >= top * 9 }
    }

    public static func choose(scores: [TravellerIdentity: Int], seed: UInt32, stage: Stage) -> TravellerIdentity {
        let candidates = candidates(scores: scores)
        let threshold = CareRules.stageThresholds.first { $0.stage == stage }!.days
        var random = SplitMix64(seed: seed, stopCount: threshold, salt: .identity)
        return candidates[Int(random.next() % UInt64(candidates.count))]
    }
}

extension CareEngine {
    static func settleIdentity(
        journey: inout JourneyState, care: inout CareState, catalog: CityCatalog,
        date: String, calendar: Calendar, deliveryTime: DeliveryTime, gate: JourneyGate
    ) {
        var settled = care.settledIdentityStages ?? []
        // Journey is written first. Its metadata and bilingual body are authoritative on replay.
        for letter in journey.letters.filter({ $0.kind == .identity }).sorted(by: { $0.id < $1.id }) {
            guard let snapshot = letter.identitySettlement else { continue }
            if !settled.contains(snapshot.stage) { settled.append(snapshot.stage) }
            care.identity = snapshot.identity.rawValue
        }
        care.settledIdentityStages = settled
        let stage = Stage.current(companionDays: care.companionDays.count)
        // Consider only the current stage, including a legacy save already above a threshold.
        guard journey.allowsNewMail(on: date, gate: gate, calendar: calendar),
              IdentityRules.stages.contains(stage), !settled.contains(stage),
              let nextDay = DayKey.date(from: DayKey.next(date, calendar: calendar), calendar: calendar),
              let deliverAt = calendar.date(bySettingHour: deliveryTime.hour, minute: deliveryTime.minute, second: 0, of: nextDay) else { return }
        let scores = IdentityRules.scores(journey: journey, care: care, catalog: catalog)
        let identity = IdentityRules.choose(scores: scores, seed: journey.seed, stage: stage)
        let content = catalog.identities.entry(identity)
        let outcome = care.identity == nil ? "first" : care.identity == identity.rawValue ? "same" : "changed"
        let zeroVariants = ["first": "zero", "changed": "zeroChanged", "same": "zeroSame"]
        let variant = scores.values.allSatisfy { $0 == 0 } ? zeroVariants[outcome]! : outcome
        var letter = Letter(
            id: journey.nextLetterID, kind: .identity, date: date, pet: journey.pet, cityId: journey.currentCityId,
            arrivals: [], newCountries: [], fuel: 0, vehicles: [], isDeepVisit: false, deliverAt: deliverAt, enrichmentDone: true
        )
        letter.identitySettlement = IdentitySettlement(stage: stage, identity: identity, previousIdentity: care.identity,
                                                       scores: Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, $0.value) }), names: content.name)
        letter.storyVersion = catalog.identities.version
        letter.texts = content.letters[variant]!.mapValues { StorySlots.render($0, values: ["pet": care.petName]) }
        journey.letters.append(letter)
        care.identity = identity.rawValue
        care.settledIdentityStages = settled + [stage]
    }
}
