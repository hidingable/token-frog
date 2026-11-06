import Foundation
import VoyageCore

enum HomePage { case room, profile, box }
enum CompanionSurface { case main, floating, notch }

enum PetBubble: Equatable {
    case mail, reply(Int), bag

    var titleKey: String {
        switch self {
        case .mail: "home.bubble.mail"
        case .reply: "home.bubble.reply"
        case .bag: "home.bubble.bag"
        }
    }

    static func current(letters: [Letter], care: CareState) -> Self? {
        if letters.contains(where: { !$0.read }) { return .mail }
        if let latest = letters.filter(\.read).max(by: { $0.id < $1.id }),
           !latest.replyOptions.isEmpty, latest.selectedReplyId == nil { return .reply(latest.id) }
        return care.bag.todayItem == nil ? .bag : nil
    }
}

enum RoomLayout {
    static let width = 240
    static let height = 132
    static func scale(availableWidth: CGFloat, pixelWidth: Int = width) -> Int {
        max(0, Int(floor(availableWidth / CGFloat(pixelWidth))))
    }
    static func shelf(_ care: CareState) -> [CareState.Souvenir] {
        Array(care.souvenirs.filter(\.shelved).prefix(CareRules.shelfCapacity))
    }

    static func bubbleRegion(scale: Int, souvenir: Bool) -> CGRect {
        let factor = CGFloat(scale)
        let x: CGFloat = souvenir ? 8 : 154 * factor
        let y = 58 * factor
        return CGRect(x: x, y: y, width: CGFloat(width) * factor - x - 8,
                      height: CGFloat(height) * factor - y - 8)
    }
}

struct HomeLayout {
    let contentWidth: CGFloat
    let roomWidth: CGFloat
    var rightWidth: CGFloat { contentWidth - roomWidth - 16 }

    init(windowWidth: CGFloat) {
        contentWidth = floor(min(windowWidth - 24, 1080))
        let scale = min(3, RoomLayout.scale(availableWidth: contentWidth - 16 - 230))
        roomWidth = CGFloat(RoomLayout.width * scale)
    }
}

struct WeekDisplay {
    struct Day: Identifiable {
        let id: String
        let label: String
        let stamped: Bool
        let today: Bool
    }
    let days: [Day]
    let stampCount: Int
    let pendingBoxes: Int

    init(care: CareState, now: Date, l10n: L10n, calendar: Calendar = .current) {
        let today = DayKey.string(from: now, calendar: calendar)
        let offset = (calendar.component(.weekday, from: now) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -offset, to: now)!
        let keys = (0..<7).map { DayKey.string(from: calendar.date(byAdding: .day, value: $0, to: monday)!, calendar: calendar) }
        let stamped = Set(care.weekly.stamps)
        days = keys.enumerated().map { index, key in
            Day(id: key, label: l10n.weekday(index), stamped: stamped.contains(key), today: key == today)
        }
        stampCount = days.filter(\.stamped).count
        pendingBoxes = care.weekly.boxes.count
    }

    func progressText(l10n: L10n) -> String? {
        switch stampCount {
        case 0..<4: l10n("home.week.untilBox", 4 - stampCount)
        case 4..<6: l10n("home.week.untilExtra", 6 - stampCount)
        default: nil
        }
    }

    func boxButton(l10n: L10n) -> String? {
        pendingBoxes > 0 ? l10n("home.week.openBoxes", pendingBoxes) : nil
    }
}

struct ProfileDisplay {
    struct Learned: Identifiable {
        let id: Int
        let text: String
    }
    let days: Int
    let stage: Stage
    let cityCount: Int
    let kilometers: String
    let learned: [Learned]
    let next: String

    init(journey: JourneyState, care: CareState, l10n: L10n) {
        days = care.companionDays.count
        stage = Stage.current(companionDays: days)
        cityCount = Set(journey.route).count
        kilometers = Format.km(fuel: journey.totalFuel)
        learned = CareEngine.recentLearned(journey: journey, limit: 5).compactMap {
            guard let text = LetterComposer.localized($0.learnedTexts, l10n: l10n) else { return nil }
            return Learned(id: $0.letterId, text: text)
        }
        if let nextStage = Stage.next(companionDays: days), let remaining = Stage.daysUntilNext(companionDays: days) {
            next = l10n("profile.nextStage", l10n.days(remaining), l10n.stage(nextStage))
        } else {
            next = l10n("profile.legend")
        }
    }

    static func habitSummary(_ habits: CareState.Habits, l10n: L10n) -> String? {
        guard max(habits.talkative, habits.observant) > 0 else { return nil }
        if habits.talkative == habits.observant { return l10n("habit.both") }
        return l10n.habit(habits.talkative > habits.observant ? .talkative : .observant)
    }
}

enum FloatingClick: Equatable {
    case none, react, openPostOffice
    static func action(clickCount: Int, dragged: Bool) -> Self {
        if dragged { return .none }
        return clickCount >= 2 ? .openPostOffice : .react
    }
}

extension L10n {
    func stage(_ stage: Stage) -> String { self(Self.stageKeys[stage]!) }
    func habit(_ habit: Habit) -> String { self(Self.habitKeys[habit]!) }
    func habitDescription(_ habit: Habit, habits: CareState.Habits) -> String {
        self(Self.habitDescriptionKeys[habit]![habit.band(in: habits).rawValue])
    }
}

extension ItemCollection {
    static func shelfFullMessage(for souvenir: CareState.Souvenir, care: CareState, l10n: L10n) -> String? {
        !souvenir.shelved && care.souvenirs.filter(\.shelved).count >= CareRules.shelfCapacity
            ? l10n("collection.shelfFull") : nil
    }

    static func boxOrigin(for souvenir: CareState.Souvenir, l10n: L10n) -> String? {
        souvenir.boxId == nil ? nil : l10n("collection.weeklyBox")
    }
}
