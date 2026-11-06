/// Companion rules use days spent together, never token usage or distance.
public enum CareRules {
    public static let stageThresholds: [(stage: Stage, days: Int)] = [
        (.egg, 0), (.hatchling, 1), (.juvenile, 5), (.teen, 20),
        (.traveler, 60), (.veteran, 170), (.legend, 340),
    ]
    public static let shelfCapacity = 4
}

public enum Stage: String, Codable, CaseIterable, Sendable {
    case egg, hatchling, juvenile, teen, traveler, veteran, legend

    public static func current(companionDays: Int) -> Stage {
        CareRules.stageThresholds.last { companionDays >= $0.days }?.stage ?? .egg
    }

    public static func next(companionDays: Int) -> Stage? {
        CareRules.stageThresholds.first { $0.days > companionDays }?.stage
    }

    public static func daysUntilNext(companionDays: Int) -> Int? {
        CareRules.stageThresholds.first { $0.days > companionDays }.map { $0.days - companionDays }
    }
}

public enum Habit: String, CaseIterable, Sendable {
    case talkative, observant

    /// Display wording belongs to the localization layer.
    public enum Band: Int, CaseIterable, Sendable {
        case none, emerging, growing, established

        public init(value: Int) {
            switch value {
            case ...0: self = .none
            case 1..<30: self = .emerging
            case 30..<60: self = .growing
            default: self = .established
            }
        }
    }

    public func band(in habits: CareState.Habits) -> Band {
        Band(value: self == .talkative ? habits.talkative : habits.observant)
    }
}
