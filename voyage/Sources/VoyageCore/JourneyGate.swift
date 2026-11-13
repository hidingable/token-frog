import Foundation

/// Decisions use the engine's event time, including each backfilled day's own time.
public struct JourneyGate: Sendable {
    public static let open = JourneyGate { _ in true }

    private let departureDecision: @Sendable (Date) -> Bool
    private let mailDecision: @Sendable (Date) -> Bool

    public init(allowsDeparture: @escaping @Sendable (Date) -> Bool,
                allowsNewMail: @escaping @Sendable (Date) -> Bool) {
        departureDecision = allowsDeparture
        mailDecision = allowsNewMail
    }

    public init(_ decision: @escaping @Sendable (Date) -> Bool) {
        self.init(allowsDeparture: decision, allowsNewMail: decision)
    }

    public func allowsDeparture(at now: Date) -> Bool { departureDecision(now) }
    public func allowsNewMail(at now: Date) -> Bool { mailDecision(now) }
}

extension JourneyState {
    /// Mail already earned by an ongoing trip survives a closed gate, including homecoming day.
    func allowsNewMail(on date: String, gate: JourneyGate, calendar: Calendar) -> Bool {
        allowsNewMail(at: DayKey.end(of: date, calendar: calendar), gate: gate, calendar: calendar)
    }

    func allowsNewMail(at now: Date, gate: JourneyGate, calendar: Calendar) -> Bool {
        if gate.allowsNewMail(at: now) { return true }
        let date = DayKey.string(from: now, calendar: calendar)
        if days[date]?.tripNumber != nil || days[date]?.arrivals.isEmpty == false { return true }
        if let homecoming, DayKey.string(from: homecoming.returnedAt, calendar: calendar) == date { return true }
        return phase != .home && date >= DayKey.string(from: phaseSince, calendar: calendar)
    }
}

extension DayKey {
    static func end(of date: String, calendar: Calendar) -> Date {
        DayKey.date(from: DayKey.next(date, calendar: calendar), calendar: calendar)!.addingTimeInterval(-1)
    }
}
