import Foundation

/// Content IDs remain single strings on the wire, including IDs absent from this content pack.
public struct PetID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

public struct PixelSprite: Decodable, Sendable {
    public let size: [Int]
    public let rows: [String]
}

public struct PetDefinition: Decodable, Sendable, Identifiable {
    public struct Egg: Decodable, Sendable {
        public let recolor: [String: String]
    }
    /// Reserved for body + accessory composition. M0 decodes these layers without drawing them.
    public struct Accessory: Decodable, Sendable {
        public let id: String
        public let sprite: PixelSprite
    }
    public let id: PetID
    public let order: Int
    public let names: [String: String]
    public let eggNames: [String: String]
    public let egg: Egg
    public let sprite: PixelSprite
    public let accessories: [Accessory]
    public let quirks: [[String: String]]
}

public struct EggSprites: Decodable, Sendable {
    public let base: PixelSprite
    public let cracked: PixelSprite
    public let placeholder: PixelSprite
}

/// One immutable, validated snapshot shared by onboarding, saved companions and all art surfaces.
public final class PetCatalog: Sendable {
    public let all: [PetDefinition]
    public let palette: [Character: UInt32]
    public let eggs: EggSprites
    public let icons: [String: PixelSprite]
    private let byID: [PetID: PetDefinition]
    public var defaultID: PetID { all[0].id }
    public func find(_ id: PetID) -> PetDefinition? { byID[id] }
    public func sprite(_ id: PetID) -> PixelSprite { find(id)?.sprite ?? eggs.placeholder }

    private init(directory: URL) throws {
        all = try Self.readPets(directory: directory).map(\.pet).sorted { $0.order < $1.order }
        byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        palette = Dictionary(uniqueKeysWithValues: try Self.readPalette(directory: directory).compactMap { symbol, value in
            value.map { (symbol.first!, UInt32($0.dropFirst(), radix: 16)!) }
        })
        eggs = try Self.readEggs(directory: directory)
        icons = try Self.readIcons(directory: directory)
    }

    public static func load(directory: URL) throws -> PetCatalog {
        let issues = ContentValidator.validatePets(directory: directory)
        guard issues.isEmpty else { throw ContentValidationError(issues: issues) }
        return try PetCatalog(directory: directory)
    }

    static func readPets(directory: URL) throws -> [(file: URL, pet: PetDefinition)] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("pets"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, try JSONDecoder().decode(PetDefinition.self, from: Data(contentsOf: $0))) }
    }
    static func readPalette(directory: URL) throws -> [String: String?] {
        try read("palette", directory: directory)
    }
    static func readEggs(directory: URL) throws -> EggSprites {
        try read("eggs", directory: directory)
    }
    static func readIcons(directory: URL) throws -> [String: PixelSprite] {
        try read("icons", directory: directory)
    }
    private static func read<Value: Decodable>(_ name: String, directory: URL) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: directory.appendingPathComponent("sprites/\(name).json")))
    }
}
