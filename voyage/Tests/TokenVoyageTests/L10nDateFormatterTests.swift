import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@Test func localizedDateFormattersReuseEachLanguageAndTemplate() throws {
    let cache = L10nDateFormatters()
    let date = try #require(DayKey.date(from: "2026-11-06"))
    for _ in 0..<10 {
        for language in Language.allCases {
            let reference = DateFormatter()
            reference.locale = Locale(identifier: language.rawValue)
            reference.setLocalizedDateFormatFromTemplate("MMMd")
            #expect(cache.withFormatter(language: language, format: .day) { $0.string(from: date) } == reference.string(from: date))
            reference.dateStyle = .medium
            #expect(cache.withFormatter(language: language, format: .dayFull) { $0.string(from: date) } == reference.string(from: date))
            reference.dateStyle = .none
            reference.timeStyle = .short
            #expect(cache.withFormatter(language: language, format: .time) { $0.string(from: date) } == reference.string(from: date))
            #expect(cache.withFormatter(language: language, format: .symbols) { $0.shortWeekdaySymbols! } == reference.shortWeekdaySymbols)
        }
        #expect(cache.count == Language.allCases.count * 4)
    }
}

@Test func localizedDateFormattingDoesNotMixConcurrentLanguages() async throws {
    let date = try #require(DayKey.date(from: "2026-11-06"))
    let en = L10n(language: .en)
    let zh = L10n(language: .zhHans)
    let expectedEn = [en.day("2026-11-06"), en.day("2026-11-06", full: true), en.time(date), en.hour(13), en.weekday(0), en.month(11)] + en.weekdays
    let expectedZh = [zh.day("2026-11-06"), zh.day("2026-11-06", full: true), zh.time(date), zh.hour(13), zh.weekday(0), zh.month(11)] + zh.weekdays
    #expect(expectedEn != expectedZh)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                let language: Language = index.isMultiple(of: 2) ? .en : .zhHans
                let l10n = L10n(language: language)
                let actual = [l10n.day("2026-11-06"), l10n.day("2026-11-06", full: true), l10n.time(date), l10n.hour(13), l10n.weekday(0), l10n.month(11)] + l10n.weekdays
                #expect(actual == (language == .en ? expectedEn : expectedZh))
            }
        }
    }
}
