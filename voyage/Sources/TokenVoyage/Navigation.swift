import VoyageCore

enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case home, journey, mail, collection, data
    var id: String { rawValue }
}

enum MailFilter: String, CaseIterable, Identifiable, Sendable {
    case all, travel, postcards, weekly
    var id: String { rawValue }

    func includes(_ letter: Letter) -> Bool {
        switch self {
        case .all: true
        case .travel: letter.kind == .daily
        case .postcards: letter.kind == .postcard
        case .weekly: letter.kind == .weekly
        }
    }
}

enum CollectionTab: String, CaseIterable, Identifiable, Sendable {
    case passport, bag, souvenirs, menus, friends, memories
    var id: String { rawValue }

    static func visible(care: CareState?) -> [Self] {
        allCases.filter { $0 != .friends || !(care?.metFriends ?? []).isEmpty }
    }
}

enum DataTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard, quota
    var id: String { rawValue }
}

enum NotchStatus {
    static let nearArrivalKilometers = 50.0

    static func isNearArrival(remainingKm: Double) -> Bool {
        remainingKm <= nearArrivalKilometers
    }
}
