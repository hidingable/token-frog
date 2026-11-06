public enum Language: String, CaseIterable, Sendable {
    case zhHans = "zh-Hans"
    case en

    /// Only the first preferred system language determines the app language.
    public static func resolve(systemLanguages: [String]) -> Language {
        guard let first = systemLanguages.first?.lowercased() else { return .en }
        if first == "zh" || first == "zh-cn" || first == "zh-sg"
            || first == "zh-hans" || first.hasPrefix("zh-hans-") {
            return .zhHans
        }
        return .en
    }
}

public enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    public func resolve(systemLanguages: [String]) -> Language {
        switch self {
        case .system: Language.resolve(systemLanguages: systemLanguages)
        case .zhHans: .zhHans
        case .en: .en
        }
    }
}
