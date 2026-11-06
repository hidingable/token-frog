import VoyageCore

enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case home, journey, mail, collection, data
    var id: String { rawValue }
}

enum MailFilter: String, CaseIterable, Identifiable, Sendable {
    case all, travel
    var id: String { rawValue }

    func includes(_ letter: Letter) -> Bool { self == .all || letter.kind == .daily }
}

enum CollectionTab: String, CaseIterable, Identifiable, Sendable {
    case passport, bag, souvenirs, menus
    var id: String { rawValue }
}

enum DataTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard, quota
    var id: String { rawValue }
}

enum NotchStatus {
    static let nearArrivalKilometers = 50

    static func isNearArrival(remainingFuel: Int) -> Bool {
        remainingFuel <= nearArrivalKilometers * fuelPerKm
    }
}
