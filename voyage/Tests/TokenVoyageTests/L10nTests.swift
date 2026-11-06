import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@Test func localizationFallbackUsesSelectedThenEnglishThenChineseThenKey() {
    let translations: [Language: [String: String]] = [
        .zhHans: ["selected": "所选翻译", "chineseOnly": "中文兜底"],
        .en: ["selected": "English translation", "englishOnly": "English fallback"],
    ]
    let lookup: L10n.Lookup = { language, key in translations[language]?[key] }
    let chinese = L10n(language: .zhHans, lookup: lookup)
    let english = L10n(language: .en, lookup: lookup)
    #expect(chinese("selected") == "所选翻译")
    #expect(chinese("englishOnly") == "English fallback")
    #expect(english("chineseOnly") == "中文兜底")
    #expect(english("absent.key") == "absent.key")
    #expect(chinese("absent.key") == "absent.key")
}

@Test func emptyTranslationFallsBack() {
    let l10n = L10n(language: .zhHans) { language, _ in
        language == .zhHans ? "" : "English fallback"
    }
    #expect(l10n("example") == "English fallback")
}

@Test func localizedArgumentsSupportReorderingAndLocaleFormatting() {
    let l10n = L10n(language: .en) { _, _ in "%2$@ has %1$d items" }
    #expect(l10n("example", 2, "Ginkgo") == "Ginkgo has 2 items")
    for language in Language.allCases {
        let numeric = L10n(language: language) { _, _ in "%.2f" }
        let expected = String(format: "%.2f", locale: Locale(identifier: language.rawValue), 12.5)
        #expect(numeric("number", 12.5) == expected)
    }
}

@Test func englishTokenAndResetCountsUseSingularAndPluralForms() {
    let l10n = L10n(language: .en)
    #expect(l10n.tokens(0) == "0 tokens")
    #expect(l10n.tokens(1) == "1 token")
    #expect(l10n.tokens(2) == "2 tokens")
    #expect(l10n.tokens(13_400_000) == "13.4M tokens")
    #expect(l10n.reset(.minutes(1)) == "Resets in 1 minute")
    #expect(l10n.reset(.minutes(2)) == "Resets in 2 minutes")
    #expect(l10n.reset(.hours(1)) == "Resets in 1 hour")
    #expect(l10n.reset(.daysHours(1, 2)) == "Resets in 1 day 2 hours")
    #expect(l10n.reset(.raw("provider-specific value")) == "provider-specific value")
}

@Test func semanticErrorsCanBeRenderedAgainAfterLanguageChanges() {
    let errors: [any Error] = [
        UsageError.missingBinary, UsageError.failed(17), UsageError.timedOut,
        SaveStoreError.locked, SaveStoreError.invalidVersion, SaveStoreError.tooNew(3),
        SaveStoreError.missingMigration(1), SaveStoreError.invalidJSON, SaveStoreError.restartNotAllowed,
        AppError.save(SaveStoreError.locked), AppError.restore(SaveStoreError.invalidJSON),
        AppError.restart(SaveStoreError.restartNotAllowed), AppError.backups(SaveStoreError.locked),
    ]
    let chinese = L10n(language: .zhHans)
    let english = L10n(language: .en)
    for error in errors {
        let zh = chinese.error(error)
        let en = english.error(error)
        #expect(zh != en)
        #expect(!en.hasPrefix("error."))
        #expect(!containsHan(en))
    }
    let systemError = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "A system reason"])
    #expect(chinese.error(systemError) == "A system reason")
    #expect(english.error(systemError) == "A system reason")
}

@Test func dateAndTimeDisplayUseTheCurrentLanguageLocale() throws {
    let date = try #require(DayKey.date(from: "2026-11-06"))
    let instant = date.addingTimeInterval(13 * 60 * 60 + 20 * 60)
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: language.rawValue)
        dayFormatter.dateStyle = .medium
        #expect(l10n.day("2026-11-06", full: true) == dayFormatter.string(from: date))
        dayFormatter.dateStyle = .none
        dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
        #expect(l10n.day("2026-11-06") == dayFormatter.string(from: date))
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: language.rawValue)
        timeFormatter.timeStyle = .short
        #expect(l10n.time(instant) == timeFormatter.string(from: instant))
    }
    #expect(L10n(language: .en).day("2026-11-06", full: true) != L10n(language: .zhHans).day("2026-11-06", full: true))
}

@Test func lettersUseVoiceAndItinerary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: localizationCatalog)
    state.sync(
        today: DayUsage(date: "2026-11-02"),
        finalized: [DayUsage(date: "2026-11-01", fuel: 8_880_000, byClient: ["codex": 8_880_000])],
        calendar: calendar, catalog: localizationCatalog
    )
    let letter = try #require(state.letters.last)
    let text = LetterComposer.text(for: letter, l10n: L10n(language: .zhHans), petName: "Ginkgo", catalog: localizationCatalog)
    #expect(text.itinerary.first == "888 万 token = 888 km")
    #expect(!text.voice.isEmpty)
}

@Test(arguments: PetKind.allCases)
func oldLettersRenderInBothLanguagesWithoutChangingSavedData(_ pet: PetKind) throws {
    let state = JourneyState(seed: 7, startCityId: "shanghai", pet: pet, date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: localizationCatalog)
    let initial = try #require(state.letters.first)
    for index in 0..<3 {
        var original = initial
        original.id = index + 1
        original.kind = .daily
        original.arrivals = ["shanghai"]
        original.fuel = 13_400_000
        let data = try JSONEncoder().encode(original)
        let letter = try JSONDecoder().decode(Letter.self, from: data)
        let chinese = LetterComposer.text(for: letter, l10n: L10n(language: .zhHans), petName: "Ginkgo", catalog: localizationCatalog)
        let english = LetterComposer.text(for: letter, l10n: L10n(language: .en), petName: "Ginkgo", catalog: localizationCatalog)
        #expect(chinese.title != english.title)
        #expect(chinese.voice != english.voice)
        #expect(!chinese.title.hasPrefix("letter."))
        #expect(!english.title.hasPrefix("letter."))
        #expect(!chinese.voice.hasPrefix("letter."))
        #expect(!english.voice.hasPrefix("letter."))
        let englishText = ([english.title, english.voice, english.signature] + english.itinerary).joined(separator: "\n")
        #expect(!containsHan(englishText))
        #expect(letter == original)
    }
    let chineseDeparture = LetterComposer.text(for: initial, l10n: L10n(language: .zhHans), petName: "Ginkgo", catalog: localizationCatalog)
    let englishDeparture = LetterComposer.text(for: initial, l10n: L10n(language: .en), petName: "Ginkgo", catalog: localizationCatalog)
    #expect(chineseDeparture.title != englishDeparture.title)
    #expect(chineseDeparture.voice != englishDeparture.voice)
}

@Test func letterSignaturesPreserveTheSuppliedPetNameInBothLanguages() throws {
    let state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    let letter = try #require(state.letters.first)
    let petName = "小银杏 Ginkgo"
    for language in Language.allCases {
        let text = LetterComposer.text(for: letter, l10n: L10n(language: language), petName: petName, catalog: localizationCatalog)
        #expect(text.signature.hasSuffix(petName))
        #expect(text.signature.contains(petName))
    }
}

@Test(arguments: [
    (PetKind.pigeon, 0, "邮差帽被风吹歪了，我又把它扶正。"),
    (PetKind.pigeon, 1, "邮包还很轻，下一封信也装得下。"),
    (PetKind.pigeon, 2, "我在屋顶上数了数今天的云。"),
    (PetKind.snail, 0, "我不着急，壳里的金币叮当响。"),
    (PetKind.snail, 1, "慢一点也能到，我一直这么觉得。"),
    (PetKind.snail, 2, "今晚把壳擦亮了，明天接着走。"),
    (PetKind.suitcase, 0, "今天又多了一张旅行贴纸。"),
    (PetKind.suitcase, 1, "我把自己的搭扣检查了两遍。"),
    (PetKind.suitcase, 2, "轮子有点累，不过还能走。"),
    (PetKind.letter, 0, "我把今天的事都折进了身体里。"),
    (PetKind.letter, 1, "风大的时候，我得贴着墙走。"),
    (PetKind.letter, 2, "邮戳盖在身上，有一点痒。"),
])
func chineseCharacterVoicesPreserveAllTwelveOriginalLines(pet: PetKind, index: Int, expected: String) throws {
    let state = JourneyState(seed: 7, startCityId: "shanghai", pet: pet, date: "2026-11-01", catalog: localizationCatalog)
    var letter = try #require(state.letters.first)
    letter.kind = .daily
    letter.id = index + 3
    let text = LetterComposer.text(for: letter, l10n: L10n(language: .zhHans), petName: "银杏", catalog: localizationCatalog)
    #expect(text.voice == "我到上海了。" + expected)
}

@Test func chineseLetterTemplatesPreserveOriginalCopy() throws {
    let l10n = L10n(language: .zhHans)
    let state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    var letter = try #require(state.letters.first)
    letter.kind = .departure
    let departure = LetterComposer.text(for: letter, l10n: l10n, petName: "银杏", catalog: localizationCatalog)
    #expect(departure.title == "出发信 · 上海")
    #expect(departure.voice == "行李收好了，我从上海出发。你的每 1 万 token，都会变成我路上的 1 公里。到了地方就写信给你。")
    #expect(departure.itinerary == ["里程规则：1 万 token = 1 km"])
    #expect(departure.signature == "—— 银杏")
    letter.kind = .daily
    letter.id = 3
    letter.fuel = 13_400_000
    letter.compareToMedianPercent = 20
    letter.vehicles = [VehicleShare(client: "codex", percent: 100)]
    letter.isDeepVisit = true
    let deep = LetterComposer.text(for: letter, l10n: l10n, petName: "银杏", catalog: localizationCatalog)
    #expect(deep.title == "第 3 封 · 上海")
    #expect(deep.voice == "昨天走得不多，正好在上海慢慢逛了一整天。邮差帽被风吹歪了，我又把它扶正。")
    #expect(deep.itinerary == ["1,340 万 token = 1,340 km", "比平时多 20%", "Codex 号 100%"])
    letter.isDeepVisit = false
    letter.arrivals = ["beijing", "shanghai"]
    letter.newCountries = ["CN"]
    letter.compareToMedianPercent = -20
    let longTrip = LetterComposer.text(for: letter, l10n: l10n, petName: "银杏", catalog: localizationCatalog)
    #expect(longTrip.voice == "这一天跑得真远，路过北京，最后在上海停下。护照上多了一个中国的章。邮差帽被风吹歪了，我又把它扶正。")
    #expect(longTrip.itinerary[1] == "比平时少 20%")
    letter.transitTargetId = "beijing"
    letter.compareToMedianPercent = 0
    let transit = LetterComposer.text(for: letter, l10n: l10n, petName: "银杏", catalog: localizationCatalog)
    #expect(transit.title == "第 3 封 · 前往北京途中")
    #expect(transit.voice == "这一天还没走到北京，今晚就在路上歇脚。邮差帽被风吹歪了，我又把它扶正。")
    #expect(transit.itinerary[1] == "和平时差不多")
}

@Test func hanDetectionDistinguishesHanCharactersFromSharedPunctuation() {
    #expect(containsHan("上海"))
    #expect(containsHan("\u{20000}"))
    #expect(!containsHan("Codex · 13.4M tokens"))
    #expect(!containsHan(""))
}

private let hanExpression = try! NSRegularExpression(pattern: #"\p{Han}"#)

func containsHan(_ value: String) -> Bool {
    hanExpression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

@Test func cityAndCountryNamesRenderInTheSelectedLanguage() {
    let en = L10n(language: .en)
    let zh = L10n(language: .zhHans)
    #expect(en.cityName(localizationCatalog.city("shanghai")) == "Shanghai")
    #expect(zh.cityName(localizationCatalog.city("shanghai")) == "上海")
    #expect(en.countryName(localizationCatalog.countryNames("CN")) == "China")
    #expect(en.countryName(localizationCatalog.countryNames("TW")) == "Taiwan")
    #expect(en.countryName(localizationCatalog.countryNames("GB")) == "United Kingdom")
    #expect(en.countryName(localizationCatalog.countryNames("US")) == "United States")
    #expect(en.countryName(localizationCatalog.countryNames("TR")) == "Türkiye")
    #expect(en.countryName(localizationCatalog.countryNames("KR")) == "South Korea")
    #expect(zh.countryName(localizationCatalog.countryNames("CN")) == "中国")
    for city in localizationCatalog.all {
        #expect(!containsHan(en.cityName(city)))
        #expect(!containsHan(en.countryName(localizationCatalog.countryNames(city.countryCode))))
    }
    var city = localizationCatalog.city("shanghai")
    city.names = ["en": "Shanghai"]
    #expect(zh.cityName(city) == "Shanghai")
    city.names = ["zh-Hans": "上海"]
    #expect(en.cityName(city) == "上海")
}

@Test func countryNamesFallBackFromSelectedToEnglishToChineseToUnknown() {
    let en = L10n(language: .en)
    let zh = L10n(language: .zhHans)
    let names = ["en": "English name", "zh-Hans": "中文名"]
    #expect(en.countryName(names) == "English name")
    #expect(zh.countryName(names) == "中文名")
    #expect(zh.countryName(["en": "English fallback"]) == "English fallback")
    #expect(zh.countryName(["zh-Hans": " \n ", "en": "English fallback"]) == "English fallback")
    #expect(en.countryName(["zh-Hans": "中文兜底"]) == "中文兜底")
    #expect(en.countryName(["en": "", "zh-Hans": "中文兜底"]) == "中文兜底")
    for l10n in [en, zh] {
        #expect(l10n.countryName(nil) == l10n("country.unknown"))
        #expect(l10n.countryName([:]) == l10n("country.unknown"))
        #expect(l10n.countryName(["en": " \n ", "zh-Hans": ""]) == l10n("country.unknown"))
    }
}

@Test func placeholderCityAndUnknownCountryHaveLocalizedFallbacks() throws {
    var letter = try #require(JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog).letters.first)
    letter.cityId = "missing-city"
    letter.kind = .daily
    letter.arrivals = ["another-missing-city", "missing-city"]
    letter.newCountries = ["ZZ"]
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let city = localizationCatalog.city("missing-city")
        #expect(city.isPlaceholder)
        #expect(l10n.cityName(city) == l10n("city.unknown"))
        #expect(l10n.countryName(localizationCatalog.countryNames("ZZ")) == l10n("country.unknown"))
        #expect(l10n.countryName(localizationCatalog.countryNames("invalid")) == l10n("country.unknown"))
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Ginkgo", catalog: localizationCatalog)
        #expect(text.title.contains(l10n("city.unknown")))
        #expect(text.voice.contains(l10n("city.unknown")))
        #expect(text.voice.contains(l10n("country.unknown")))
        var transit = letter
        transit.transitTargetId = "missing-target"
        let transitText = LetterComposer.text(for: transit, l10n: l10n, petName: "Ginkgo", catalog: localizationCatalog)
        #expect(transitText.title.contains(l10n("city.unknown")))
        #expect(transitText.voice.contains(l10n("city.unknown")))
    }
}

@Test func allEnglishLetterPathsContainNoHanExceptThePetName() throws {
    let en = L10n(language: .en)
    let petName = "银杏 Ginkgo"
    for pet in PetKind.allCases {
        var letter = try #require(JourneyState(seed: 7, startCityId: "shanghai", pet: pet, date: "2026-11-01", catalog: localizationCatalog).letters.first)
        for path in ["departure", "arrival", "long", "deep", "transit"] {
            letter.kind = path == "departure" ? .departure : .daily
            letter.arrivals = path == "long" ? ["beijing", "tokyo", "shanghai"] : ["shanghai"]
            letter.newCountries = ["CN", "JP", "US", "ZZ"]
            letter.transitTargetId = path == "transit" ? "xian" : nil
            letter.isDeepVisit = path == "deep"
            let text = LetterComposer.text(for: letter, l10n: en, petName: petName, catalog: localizationCatalog)
            let rendered = ([text.title, text.voice, text.signature] + text.itinerary).joined(separator: "\n")
            #expect(!containsHan(rendered.replacingOccurrences(of: petName, with: "")))
        }
    }
}
