import AppKit
import VoyageCore

enum AppearancePreference: Equatable, Hashable, Sendable, RawRepresentable {
    case system, dark, light, theme(String)
    static let standard: [Self] = [.system, .dark, .light]

    init(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "dark": self = .dark
        case "light": self = .light
        default: self = .theme(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .system: "system"
        case .dark: "dark"
        case .light: "light"
        case .theme(let id): id
        }
    }

    func resolve(system: ThemeScheme, catalog: ThemeCatalog) -> ThemeDefinition {
        switch self {
        case .system: catalog.standard(system)
        case .dark: catalog.standard(.dark)
        case .light: catalog.standard(.light)
        case .theme(let id): catalog.find(id) ?? catalog.standard(system)
        }
    }
}

extension ThemeScheme {
    init(appearance: NSAppearance?) {
        self = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    var appKitAppearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

enum SnapshotAppearance {
    enum ParseError: Error { case invalidAppearance }
    static func parse(arguments: [String]) throws -> ThemeScheme? {
        guard arguments.contains("--snapshot"), let index = arguments.firstIndex(of: "--appearance") else { return nil }
        guard arguments.indices.contains(index + 1), let scheme = ThemeScheme(rawValue: arguments[index + 1]) else {
            throw ParseError.invalidAppearance
        }
        return scheme
    }
}
