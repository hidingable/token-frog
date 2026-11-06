import Foundation
import Testing
@testable import VoyageCore

@Test(arguments: ["zh-Hans", "zh-CN", "zh-SG", "zh", "zh-Hans-SG"])
func resolvesSimplifiedChineseSystemLanguage(_ identifier: String) {
    #expect(Language.resolve(systemLanguages: [identifier]) == .zhHans)
}

@Test(arguments: ["en", "en-GB", "zh-TW", "zh-Hant", "zh-HK", "ja"])
func resolvesEnglishOrUnsupportedSystemLanguage(_ identifier: String) {
    #expect(Language.resolve(systemLanguages: [identifier]) == .en)
}

@Test func resolvesOnlyTheFirstSystemLanguageAndDefaultsToEnglish() {
    #expect(Language.resolve(systemLanguages: []) == .en)
    #expect(Language.resolve(systemLanguages: ["ja", "zh-Hans"]) == .en)
    #expect(Language.resolve(systemLanguages: ["en-GB", "zh-Hans"]) == .en)
    #expect(Language.resolve(systemLanguages: ["zh-Hans", "en"]) == .zhHans)
}

@Test func explicitLanguagePreferenceOverridesSystemLanguage() {
    #expect(LanguagePreference.system.resolve(systemLanguages: ["zh-CN"]) == .zhHans)
    #expect(LanguagePreference.zhHans.resolve(systemLanguages: ["en"]) == .zhHans)
    #expect(LanguagePreference.en.resolve(systemLanguages: ["zh-Hans"]) == .en)
    #expect(LanguagePreference.zhHans.rawValue == "zh-Hans")
    #expect(LanguagePreference.en.rawValue == "en")
}

@Test(arguments: [
    (9_999, "9,999", "9,999"),
    (10_000, "1 万", "10K"),
    (999_999, "100 万", "1000K"),
    (1_000_000, "100 万", "1.0M"),
    (999_999_999, "10.0 亿", "1000.0M"),
    (1_000_000_000, "10.0 亿", "1.0B"),
])
func tokenFormattingUsesTheSpecifiedLanguageAtUnitBoundaries(value: Int, chinese: String, english: String) {
    #expect(Format.tokens(value, language: .zhHans) == chinese)
    #expect(Format.tokens(value, language: .en) == english)
}

@Test func tokenFormattingPreservesChineseUnitsAndRoundsEnglishUnits() {
    #expect(Format.tokens(13_400_000, language: .zhHans) == "1,340 万")
    #expect(Format.tokens(620_000_000, language: .zhHans) == "6.2 亿")
    #expect(Format.tokens(10_500, language: .en) == "11K")
    #expect(Format.tokens(13_400_000, language: .en) == "13.4M")
    #expect(Format.tokens(1_340_000_000, language: .en) == "1.3B")
}

@Test func missingModelUsesAnInternalMarker() throws {
    let json = #"{"contributions":[{"date":"2026-11-05","clients":[{"client":"codex","tokens":{"input":1}}]}]}"#
    let details = try TokscaleGraph.parseDetails(Data(json.utf8))
    #expect(details.first?.rows.first?.model == TokscaleGraph.unknownModel)
}
