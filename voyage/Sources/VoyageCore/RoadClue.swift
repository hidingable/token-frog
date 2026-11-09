import Foundation

/// A passing observation, separate from letters and collectible travel clues.
public struct RoadClue: Codable, Equatable, Sendable {
    public var id: String
    public var texts: [String: String]
}

/// A saved empty draw is final too, including after content updates.
public struct RoadClueDecision: Codable, Equatable, Sendable {
    public var contentVersion: Int
    public var clue: RoadClue?
}

public struct RoadClueContent: Codable, Sendable {
    var version: Int
    var clues: [RoadClue]

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("road-clues.json")))
        guard content.version > 0, content.clues.count >= 30,
              Set(content.clues.map(\.id)).count == content.clues.count,
              content.clues.allSatisfy({ clue in
                  !clue.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["zh-Hans", "en"].allSatisfy {
                      guard let text = clue.texts[$0] else { return false }
                      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !text.contains("{") && !text.contains("}")
                  }
              }) else {
            throw ContentValidationError(issues: [.init(file: "road-clues.json", rule: "roadClues", message: "At least 30 unique observations with complete bilingual literal text are required")])
        }
        return content
    }

    func draw(seed: UInt32, date: String) -> RoadClueDecision {
        // Day keys are validated at the persistence/usage boundary. Never use Swift's randomized hash.
        let day = Int(date.replacingOccurrences(of: "-", with: ""))!
        var random = SplitMix64(seed: seed, stopCount: day, salt: .roadClue)
        let offered = random.next() % 2 == 0
        let ordered = clues.sorted { $0.id < $1.id }
        return RoadClueDecision(contentVersion: version, clue: offered ? ordered[Int(random.next() % UInt64(ordered.count))] : nil)
    }
}

extension JourneyState {
    /// Upgrades start today; already elapsed days never receive retrospective observations.
    public mutating func enableRoadClues(on date: String) {
        if roadCluesEligibleFrom == nil { roadCluesEligibleFrom = date }
    }
}
