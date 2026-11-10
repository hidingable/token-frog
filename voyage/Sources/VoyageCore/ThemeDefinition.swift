import Foundation

public enum ThemeScheme: String, Decodable, Sendable { case dark, light }

/// Semantic color roles shared by SwiftUI and the pixel renderers.
public enum ThemeToken: String, CaseIterable, Sendable {
    case actionFill, actionText
    case background
    case surface
    case surfaceRaised
    case border
    case borderMuted
    case text
    case textMuted
    case selectedFill
    case selectedText
    case controlOff
    case paper
    case paperText
    case paperMuted
    case paperRule
    case paperBorder
    case paperLink
    case paperCompanionText
    case mileageFill
    case mileageText
    case newMailFill
    case newMailText
    case onNewMail
    case newPlaceFill
    case newPlaceText
    case onNewPlace
    case companionFill
    case companionOnFill
    case companionText
    case onCompanion
    case quotaLowText
    case quotaLowFill
    case quotaFill
    case mapSea
    case mapLand
    case mapBorder
    case mapMarker
    case mapPosition
    case mapStayed
    case roomWall
    case roomWallLine
    case roomFloor
    case roomFloorLine
    case roomWood
    case roomWoodDark
    case roomWindowBack
    case roomWindowFrame
    case roomStar
    case roomDoor
    case roomDoorDark
    case roomCabinet
    case roomShadow
    case roomLight
    case roomMail
    case roomPaper
    case notchBackground
    case notchText
    case notchTextMuted
    case notchMileageText
    case notchControlOff
    case seriesOther
}

public struct ThemeDefinition: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let names: [String: String]
    public let scheme: ThemeScheme
    public let colors: [ThemeToken: UInt32]
    public let series: [UInt32]
    public let heat: [UInt32]
    public let photoPalette: [UInt32]
    public var tokenNames: Set<String> { Set(colors.keys.map(\.rawValue)).union(["series", "heat", "photoPalette"]) }
    public func color(_ token: ThemeToken) -> UInt32 { colors[token]! }

    private enum CodingKeys: String, CodingKey { case id, names, scheme, colors }
    private enum ColorValue: Decodable {
        case single(String), array([String])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let color = try? value.decode(String.self) { self = .single(color) }
            else { self = .array(try value.decode([String].self)) }
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let names = try values.decode([String: String].self, forKey: .names)
        self.names = names
        scheme = try values.decode(ThemeScheme.self, forKey: .scheme)
        func invalid(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        guard id.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil,
              !["system", "dark", "light"].contains(id),
              ["zh-Hans", "en"].allSatisfy({ !(names[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw invalid("Themes require a unique ID and zh-Hans/en names")
        }
        let raw = try values.decode([String: ColorValue].self, forKey: .colors)
        let required = Set(ThemeToken.allCases.map(\.rawValue)).union(["series", "heat", "photoPalette"])
        guard Set(raw.keys) == required else { throw invalid("Theme color tokens must exactly match the schema") }
        func color(_ value: String) throws -> UInt32 {
            guard value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
                  let rgb = UInt32(value.dropFirst(), radix: 16) else { throw invalid("Invalid color: \(value)") }
            return rgb
        }
        var decoded: [ThemeToken: UInt32] = [:]
        for token in ThemeToken.allCases {
            guard case .single(let value) = raw[token.rawValue] else { throw invalid("Expected a single color: \(token)") }
            decoded[token] = try color(value)
        }
        colors = decoded
        func array(_ key: String) throws -> [UInt32] {
            guard case .array(let values) = raw[key], !values.isEmpty else { throw invalid("Expected a nonempty color array: \(key)") }
            return try values.map(color)
        }
        series = try array("series")
        heat = try array("heat")
        photoPalette = try array("photoPalette")
        // HeatCell.level is the established five-step dashboard scale.
        guard heat.count == 5 else { throw invalid("Heat requires five levels") }
    }
}

/// Loads every theme file. Adding a theme needs no registry or application change.
public struct ThemeCatalog: Sendable {
    public let all: [ThemeDefinition]
    public func find(_ id: String) -> ThemeDefinition? { all.first { $0.id == id } }
    public func standard(_ scheme: ThemeScheme) -> ThemeDefinition { find(scheme == .dark ? "night" : "day")! }

    public static func load(directory: URL) throws -> ThemeCatalog {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let themes = try files.map { file in
            let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: file))
            guard theme.id == file.deletingPathExtension().lastPathComponent else {
                throw ContentValidationError(issues: [ContentIssue(file: file.lastPathComponent, rule: "themeID", message: "Filename must equal theme ID")])
            }
            return theme
        }
        guard let night = themes.first(where: { $0.id == "night" }), night.scheme == .dark,
              let day = themes.first(where: { $0.id == "day" }), day.scheme == .light,
              themes.allSatisfy({ $0.tokenNames == night.tokenNames && $0.series.count == night.series.count && $0.heat.count == night.heat.count && $0.photoPalette.count == night.photoPalette.count }) else {
            throw ContentValidationError(issues: [ContentIssue(file: "themes", rule: "themes", message: "Night/day themes and matching tokens and array lengths are required")])
        }
        return ThemeCatalog(all: themes)
    }
}
