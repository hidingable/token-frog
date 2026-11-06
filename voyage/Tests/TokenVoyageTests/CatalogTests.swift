import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

enum LocalizationTestFiles {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = root.appendingPathComponent("Sources")
    static let appSources = sources.appendingPathComponent("TokenVoyage")
    static let catalog = appSources.appendingPathComponent("Resources/Localizable.xcstrings")
}

let localizationCatalog = try! CityCatalog.load(directory: LocalizationTestFiles.root.appendingPathComponent("Content"))

private struct StringCatalog: Decodable {
    struct Entry: Decodable {
        struct Translation: Decodable {
            struct Unit: Decodable { let value: String }
            let stringUnit: Unit
        }
        let localizations: [String: Translation]
    }
    let sourceLanguage: String
    let strings: [String: Entry]
}

@Test func catalogContainsCompleteTranslationsWithMatchingPlaceholders() throws {
    let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: LocalizationTestFiles.catalog))
    #expect(catalog.sourceLanguage == "en")
    #expect(!catalog.strings.isEmpty)
    for key in catalog.strings.keys.sorted() {
        let entry = try #require(catalog.strings[key])
        let english = try #require(entry.localizations["en"], "Missing English translation for \(key)").stringUnit.value
        let chinese = try #require(entry.localizations["zh-Hans"], "Missing Chinese translation for \(key)").stringUnit.value
        #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty English translation for \(key)")
        #expect(!chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty Chinese translation for \(key)")
        #expect(try placeholders(in: english) == placeholders(in: chinese), "Placeholder mismatch for \(key)")
        #expect(L10n(language: .en)(key) == english, "Compiled English translation is missing or stale for \(key)")
        #expect(L10n(language: .zhHans)(key) == chinese, "Compiled Chinese translation is missing or stale for \(key)")
        #expect(L10n(language: .en)(key) != key)
        #expect(L10n(language: .zhHans)(key) != key)
    }
}

private func placeholders(in value: String) throws -> [String: Int] {
    let pattern = #"%(?:\d+\$)?[-+ #0']*(?:\*(?:\d+\$)?|\d+)?(?:\.(?:\*(?:\d+\$)?|\d+))?([hlLjztq]*)([@diuoxXfFeEgGcCsSpaA%])"#
    let expression = try NSRegularExpression(pattern: pattern)
    let string = value as NSString
    var counts: [String: Int] = [:]
    for match in expression.matches(in: value, range: NSRange(location: 0, length: string.length)) {
        let kind = string.substring(with: match.range(at: 1)) + string.substring(with: match.range(at: 2))
        guard kind != "%" else { continue }
        counts[kind, default: 0] += 1
        let stars = string.substring(with: match.range).filter { $0 == "*" }.count
        if stars > 0 { counts["*", default: 0] += stars }
    }
    return counts
}

@Test func placeholderValidationIgnoresEscapedPercentAndTracksKindsAndCounts() throws {
    #expect(try placeholders(in: "%@ %% %d %@") == ["@": 2, "d": 1])
    #expect(try placeholders(in: "%2$@ %1$ld") == ["@": 1, "ld": 1])
    #expect(try placeholders(in: "%.*f") == ["*": 1, "f": 1])
}

@Test func everyLiteralAndDynamicLocalizationKeyExistsInTheCatalog() throws {
    let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: LocalizationTestFiles.catalog))
    let references = try literalLocalizationReferences()
    #expect(!references.isEmpty)
    for reference in references {
        #expect(catalog.strings[reference.key] != nil, "\(reference.file) references missing key \(reference.key)")
    }
    #expect(!L10n.dynamicKeys.isEmpty)
    for key in L10n.dynamicKeys {
        #expect(catalog.strings[key] != nil, "Dynamic localization key \(key) is missing")
    }
}

@Test func everyCatalogKeyIsUsedByALocalizationCallOrDynamicTable() throws {
    let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: LocalizationTestFiles.catalog))
    let used = Set(try literalLocalizationReferences().map(\.key)).union(L10n.dynamicKeys)
    for key in catalog.strings.keys.sorted() {
        #expect(used.contains(key), "Unused localization key \(key)")
    }
}

private func literalLocalizationReferences() throws -> [(file: String, key: String)] {
    let expression = try NSRegularExpression(pattern: #"\b(?:l10n|self)\s*\(\s*"([^"\\]*(?:\\.[^"\\]*)*)""#)
    let files = try #require(FileManager.default.enumerator(at: LocalizationTestFiles.appSources, includingPropertiesForKeys: nil))
    var references: [(file: String, key: String)] = []
    for case let file as URL in files where file.pathExtension == "swift" {
        let source = removingSwiftComments(try String(contentsOf: file, encoding: .utf8))
        let string = source as NSString
        for match in expression.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: match.range(at: 1))
            references.append((file.lastPathComponent, key))
        }
    }
    return references
}

@Test func swiftSourcesDoNotContainHardcodedChineseOutsideAllowedFiles() throws {
    let allowed = Set(["VoyageCore/JourneyMigrations.swift", "VoyageCore/Journey.swift"])
    let enumerator = try #require(FileManager.default.enumerator(at: LocalizationTestFiles.sources, includingPropertiesForKeys: nil))
    var scanned = 0
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        let relative = String(file.path.dropFirst(LocalizationTestFiles.sources.path.count + 1))
        guard !allowed.contains(relative) else { continue }
        let source = removingSwiftComments(try String(contentsOf: file, encoding: .utf8))
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            #expect(!containsHan(line), "Hardcoded Chinese in \(relative):\(index + 1)")
        }
        scanned += 1
    }
    #expect(scanned > 0)
}

private func removingSwiftComments(_ source: String) -> String {
    let characters = Array(source)
    var result = ""
    var index = 0
    var blockDepth = 0
    var inString = false
    while index < characters.count {
        let character = characters[index]
        let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
        if blockDepth > 0 {
            if character == "/", next == "*" { blockDepth += 1; index += 2 }
            else if character == "*", next == "/" { blockDepth -= 1; index += 2 }
            else { if character == "\n" { result.append(character) }; index += 1 }
        } else if inString {
            result.append(character)
            if character == "\\", let next { result.append(next); index += 2 }
            else { if character == "\"" { inString = false }; index += 1 }
        } else if character == "/", next == "/" {
            while index < characters.count, characters[index] != "\n" { index += 1 }
        } else if character == "/", next == "*" {
            blockDepth = 1
            index += 2
        } else {
            result.append(character)
            if character == "\"" { inString = true }
            index += 1
        }
    }
    return result
}
