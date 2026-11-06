import Foundation
import Testing
@testable import VoyageCore

private let themesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Content/themes")

private func themeJSON(_ id: String = "night") throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: themesDirectory.appendingPathComponent("\(id).json"))) as? [String: Any])
}

private func decodeTheme(_ json: [String: Any]) throws -> ThemeDefinition {
    try JSONDecoder().decode(ThemeDefinition.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func shippedThemesLoadWithTheSameCompleteSemanticTokens() throws {
    let themes = try ThemeCatalog.load(directory: themesDirectory)
    let night = try #require(themes.find("night"))
    let day = try #require(themes.find("day"))
    #expect(night.scheme == .dark && day.scheme == .light)
    #expect(night.tokenNames == day.tokenNames)
    #expect(night.colors.count == ThemeToken.allCases.count)
    #expect(night.series.count == day.series.count)
    #expect(night.heat.count == day.heat.count)
    #expect(night.names["zh-Hans"] == "夜墨" && day.names["zh-Hans"] == "信纸")
    let fixed: [ThemeToken: UInt32] = [
        .background: 0x1D1A39, .text: 0xF7EBD0, .paper: 0xF7EBD0, .paperText: 0x1D1A39,
        .mileageFill: 0xF4B63F, .mileageText: 0xF4B63F, .newMailFill: 0xE5533D,
        .newPlaceText: 0x7FD1C7, .companionText: 0xEFA0A8, .textMuted: 0x8E86B8,
        .quotaLowText: 0xE8873A, .mapSea: 0x2B6C8F, .mapLand: 0x3F7F5F,
    ]
    for (token, color) in fixed { #expect(night.color(token) == color) }
    #expect(night.series == [0x3987E5, 0xD95926, 0x199E70, 0xC98500])
    #expect(night.photoPalette == day.photoPalette)
    for theme in themes.all { #expect(theme.color(.notchBackground) == 0) }
    #expect(day.color(.roomStar) == day.color(.roomWindowBack))
    #expect(day.color(.roomWindowFrame) == night.color(.roomWindowFrame))
}

@Test func everyMissingThemeFieldOrTokenIsRejected() throws {
    let original = try themeJSON()
    for field in ["id", "names", "scheme", "colors"] {
        var json = original
        json.removeValue(forKey: field)
        #expect(throws: (any Error).self) { try decodeTheme(json) }
    }
    let colors = try #require(original["colors"] as? [String: Any])
    for token in colors.keys {
        var missing = colors
        missing.removeValue(forKey: token)
        var json = original
        json["colors"] = missing
        #expect(throws: (any Error).self, "Missing \(token)") { try decodeTheme(json) }
    }
}

@Test(arguments: ["#12345", "#1234567", "123456", "#GG0000", "red", " #123456", "#123456\n"])
func malformedThemeColorsAreRejected(_ color: String) throws {
    var json = try themeJSON()
    var colors = try #require(json["colors"] as? [String: Any])
    colors["text"] = color
    json["colors"] = colors
    #expect(throws: (any Error).self) { try decodeTheme(json) }
    colors = try #require(themeJSON()["colors"] as? [String: Any])
    colors["series"] = [color]
    json["colors"] = colors
    #expect(throws: (any Error).self) { try decodeTheme(json) }
}

@Test func themeColorKindsNamesAndUnknownTokensAreValidated() throws {
    let original = try themeJSON()
    for replacement: [String: Any] in [
        ["series": []], ["heat": ["#000000"]], ["heat": []], ["photoPalette": []],
        ["text": ["#000000"]], ["series": "#000000"], ["text": 123], ["unknownToken": "#000000"],
    ] {
        var json = original
        var colors = try #require(json["colors"] as? [String: Any])
        colors.merge(replacement) { _, new in new }
        json["colors"] = colors
        #expect(throws: (any Error).self) { try decodeTheme(json) }
    }
    for replacement: [String: Any] in [["names": ["en": "Night"]], ["names": ["en": " ", "zh-Hans": "夜墨"]], ["scheme": "auto"], ["id": "dark"], ["id": ""]] {
        let json = original.merging(replacement) { _, new in new }
        #expect(throws: (any Error).self) { try decodeTheme(json) }
    }
}

@Test(arguments: ["series", "heat", "photoPalette"])
func themesRejectMismatchedArrayLengths(_ token: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-themes-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: themesDirectory, to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var day = try themeJSON("day")
    var colors = try #require(day["colors"] as? [String: Any])
    let array = try #require(colors[token] as? [String])
    colors[token] = Array(array.dropLast())
    day["colors"] = colors
    try JSONSerialization.data(withJSONObject: day).write(to: directory.appendingPathComponent("day.json"))
    #expect(throws: (any Error).self) { try ThemeCatalog.load(directory: directory) }
}

@Test func aThemeIsDiscoveredByAddingOneFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-new-theme-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: themesDirectory, to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var json = try themeJSON()
    json["id"] = "custom-night"
    json["names"] = ["zh-Hans": "自定义", "en": "Custom"]
    try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("custom-night.json"))
    let themes = try ThemeCatalog.load(directory: directory)
    #expect(themes.find("custom-night")?.names["en"] == "Custom")
    #expect(themes.standard(.dark).id == "night")
    #expect(themes.standard(.light).id == "day")
    try FileManager.default.moveItem(at: directory.appendingPathComponent("custom-night.json"), to: directory.appendingPathComponent("wrong-name.json"))
    #expect(throws: (any Error).self) { try ThemeCatalog.load(directory: directory) }
}

private func luminance(_ rgb: UInt32) -> Double {
    let channels = [Double(rgb >> 16 & 255), Double(rgb >> 8 & 255), Double(rgb & 255)].map { $0 / 255 }
    let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
}

@Test func semanticTextMeetsWCAGContrastInEveryTheme() throws {
    let pairs: [(ThemeToken, ThemeToken, Double)] = [
        (.text, .background, 4.5), (.text, .surface, 4.5), (.text, .surfaceRaised, 4.5),
        (.paperText, .paper, 4.5), (.selectedText, .selectedFill, 4.5),
        (.mileageText, .surface, 4.5), (.newPlaceText, .surface, 4.5),
        (.companionText, .surface, 4.5), (.quotaLowText, .surface, 4.5),
        (.paperMuted, .paper, 4.5), (.textMuted, .background, 3.0),
        (.paperCompanionText, .paper, 4.5), (.actionText, .actionFill, 4.5),
        (.newMailText, .newMailFill, 4.5), (.onNewMail, .newMailFill, 4.5),
        (.companionOnFill, .companionFill, 4.5),
        (.notchText, .notchBackground, 4.5), (.notchTextMuted, .notchBackground, 3.0),
    ]
    for theme in try ThemeCatalog.load(directory: themesDirectory).all {
        for (foreground, background, minimum) in pairs {
            let a = luminance(theme.color(foreground)), b = luminance(theme.color(background))
            let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            #expect(contrast >= minimum, "\(theme.id): \(foreground) / \(background) = \(contrast), expected \(minimum)")
        }
    }
}
