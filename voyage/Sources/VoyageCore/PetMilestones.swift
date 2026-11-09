import Foundation

/// Presentation acknowledgements only; the current appearance is always derived from companion days.
public enum PetMilestones {
    public static let stages: [Stage] = [.juvenile, .teen]

    public static func reached(in care: CareState) -> [Stage] {
        let current = Stage.current(companionDays: care.companionDays.count)
        let index = Stage.allCases.firstIndex(of: current)!
        return stages.filter { Stage.allCases.firstIndex(of: $0)! <= index }
    }

    /// A missing field means an older save. Baseline existing progress before any new reading.
    @discardableResult
    public static func establishBaseline(care: inout CareState) -> Bool {
        guard care.seenPetStages == nil else { return false }
        care.seenPetStages = reached(in: care).map(\.rawValue)
        return true
    }

    public static func pending(in care: CareState) -> Stage? {
        guard let seen = care.seenPetStages else { return nil }
        return reached(in: care).first { !seen.contains($0.rawValue) }
    }

    public static func acknowledge(_ stage: Stage, care: inout CareState) {
        guard reached(in: care).contains(stage), var seen = care.seenPetStages,
              !seen.contains(stage.rawValue) else { return }
        seen.append(stage.rawValue)
        care.seenPetStages = seen
    }
}

public struct PetMomentContent: Decodable, Sendable {
    public struct Card: Decodable, Sendable {
        public let stage: Stage
        public let title: [String: String]
        public let body: [String: String]
    }
    public let version: Int
    public let cards: [Card]
    public func card(for stage: Stage) -> Card { cards.first { $0.stage == stage }! }

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("pet-moments.json")))
        let complete: ([String: String]) -> Bool = { texts in
            Language.allCases.allSatisfy { language in
                guard let text = texts[language.rawValue] else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !text.contains("{") && !text.contains("}") && !text.contains("<")
            }
        }
        guard content.version > 0, content.cards.count == PetMilestones.stages.count,
              Set(content.cards.map(\.stage)) == Set(PetMilestones.stages),
              content.cards.allSatisfy({ complete($0.title) && complete($0.body) }) else {
            throw ContentValidationError(issues: [.init(file: "pet-moments.json", rule: "petMoments", message: "Juvenile and teen each require one complete, literal bilingual title and body")])
        }
        return content
    }
}
