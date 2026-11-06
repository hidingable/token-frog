import Foundation

/// Companion progress is independent of journey mileage and usage.
public struct CareState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var petName: String
    public var species: PetID
    public var hatchedAt: String
    public var companionDays: [String] = []
    public var habits = Habits()
    public var identity: String?
    public var bag = Bag()
    public var souvenirs: [Souvenir] = []
    public var menus: [Menu] = []
    public var trailClues: [String: Int] = [:]
    public var weekly: Weekly
    public var wish: String?
    public var pendingPromises: [Promise] = []
    public var memories: [Memory] = []
    public var pity = 0
    public var processedLetterIds: [Int] = []
    public var boxesOpened = 0
    public var boxItemIndex = 0

    public struct Habits: Codable, Equatable, Sendable {
        public var talkative = 0
        public var observant = 0
        public init() {}

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            talkative = try values.decodeIfMissing(Int.self, forKey: .talkative, default: 0)
            observant = try values.decodeIfMissing(Int.self, forKey: .observant, default: 0)
        }
    }

    public struct Bag: Codable, Equatable, Sendable {
        public var owned = ["sketchbook", "note-slip", "raincoat"]
        public var todayItem: String?
        public init() {}

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            owned = try values.decodeIfMissing([String].self, forKey: .owned, default: owned)
            todayItem = try values.decodeIfPresent(String.self, forKey: .todayItem)
        }
    }

    public struct Souvenir: Codable, Equatable, Sendable {
        public var id: String
        public var letterId: Int?
        public var boxId: String?
        public var shelved: Bool
    }

    public struct Menu: Codable, Equatable, Sendable {
        public var id: String
        public var letterId: Int
    }

    public struct Weekly: Codable, Equatable, Sendable {
        public var weekStart: String
        public var stamps: [String] = []
        public var boxes: [String] = []

        public init(weekStart: String) { self.weekStart = weekStart }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            weekStart = try values.decode(String.self, forKey: .weekStart)
            stamps = try values.decodeIfMissing([String].self, forKey: .stamps, default: [])
            boxes = try values.decodeIfMissing([String].self, forKey: .boxes, default: [])
        }
    }

    public struct Promise: Codable, Equatable, Sendable {
        public var replyId: String
        public var letterId: Int
        /// Only letters processed while this promise is at the head of the queue count.
        public var attempts = 0

        public init(replyId: String, letterId: Int, attempts: Int = 0) {
            self.replyId = replyId
            self.letterId = letterId
            self.attempts = attempts
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            replyId = try values.decode(String.self, forKey: .replyId)
            letterId = try values.decode(Int.self, forKey: .letterId)
            attempts = try values.decodeIfMissing(Int.self, forKey: .attempts, default: 0)
        }
    }

    public struct Memory: Codable, Equatable, Sendable {
        public var kind: String
        public var date: String
        public var letterId: Int
        public var replyId: String?
    }

    public init(petName: String, species: PetID, hatchedAt: String, calendar: Calendar = .current) {
        self.petName = petName
        self.species = species
        self.hatchedAt = hatchedAt
        weekly = Weekly(weekStart: WeeklyEngine.weekStart(for: hatchedAt, calendar: calendar) ?? hatchedAt)
    }

    public static func legacy(from journey: JourneyState, pets: PetCatalog?) -> CareState {
        var care = CareState(petName: pets?.find(journey.pet)?.names["zh-Hans"] ?? journey.pet.rawValue, species: journey.pet, hatchedAt: journey.startDate)
        care.processedLetterIds = journey.letters.map(\.id)
        return care
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            petName: try values.decode(String.self, forKey: .petName),
            species: try values.decode(PetID.self, forKey: .species),
            hatchedAt: try values.decode(String.self, forKey: .hatchedAt)
        )
        version = try values.decode(Int.self, forKey: .version)
        companionDays = try values.decodeIfMissing([String].self, forKey: .companionDays, default: [])
        habits = try values.decodeIfMissing(Habits.self, forKey: .habits, default: Habits())
        identity = try values.decodeIfPresent(String.self, forKey: .identity)
        bag = try values.decodeIfMissing(Bag.self, forKey: .bag, default: Bag())
        souvenirs = try values.decodeIfMissing([Souvenir].self, forKey: .souvenirs, default: [])
        menus = try values.decodeIfMissing([Menu].self, forKey: .menus, default: [])
        trailClues = try values.decodeIfMissing([String: Int].self, forKey: .trailClues, default: [:])
        weekly = try values.decodeIfMissing(Weekly.self, forKey: .weekly, default: weekly)
        wish = try values.decodeIfPresent(String.self, forKey: .wish)
        pendingPromises = try values.decodeIfMissing([Promise].self, forKey: .pendingPromises, default: [])
        memories = try values.decodeIfMissing([Memory].self, forKey: .memories, default: [])
        pity = try values.decodeIfMissing(Int.self, forKey: .pity, default: 0)
        processedLetterIds = try values.decodeIfMissing([Int].self, forKey: .processedLetterIds, default: [])
        boxesOpened = try values.decodeIfMissing(Int.self, forKey: .boxesOpened, default: 0)
        boxItemIndex = try values.decodeIfMissing(Int.self, forKey: .boxItemIndex, default: 0)
        guard boxesOpened >= 0, boxItemIndex >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Box counters must be nonnegative"))
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeIfMissing<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) throws -> T {
        contains(key) ? try decode(type, forKey: key) : fallback
    }
}
