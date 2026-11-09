import Foundation

public enum MemoryBook {
    /// Safe to repeat for existing saves: only references change, never rewards or promises.
    public static func backfill(journey: JourneyState, care: inout CareState) {
        let first = journey.letters.min { $0.id < $1.id }
        record(.init(kind: .hatched, date: care.hatchedAt,
                     letterId: first?.date == care.hatchedAt ? first?.id : nil), care: &care)
        if let letter = journey.letters.filter({ $0.kind == .daily }).min(by: { $0.id < $1.id }) {
            record(.init(kind: .firstLetter, date: letter.date, letterId: letter.id), care: &care)
        }
        recordCompanionMilestone(care: &care)
    }

    static func recordCompanionMilestone(care: inout CareState) {
        let days = Set(care.companionDays).sorted()
        if days.count >= 100 {
            record(.init(kind: .hundredDays, date: days[99]), care: &care)
        }
    }

    private static func record(_ day: CareState.SpecialDay, care: inout CareState) {
        if !care.specialDays.contains(where: { $0.kind == day.kind }) { care.specialDays.append(day) }
    }
}
