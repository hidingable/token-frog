import Foundation
import Testing
@testable import VoyageCore

@Suite struct WishTests {
    private var monday: Date { careCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))! }

    @Test func limitCountsCharactersPreservesOriginalAndAllowsClearing() {
        var (_, care) = engineState()
        let original = "  **" + String(repeating: "👨‍👩‍👧‍👦", count: 34) + "**"
        #expect(original.count == 40)
        #expect(WishEngine.write(original, tags: ["coast"], at: monday, care: &care, calendar: careCalendar))
        #expect(care.wish == original && care.wishResolution?.tags == ["coast"])
        let saved = care
        #expect(!WishEngine.write(original + "字", tags: ["food"], at: monday, care: &care, calendar: careCalendar))
        #expect(care == saved)
        #expect(WishEngine.write("", tags: [], at: monday, care: &care, calendar: careCalendar))
        #expect(care.wish == nil && care.wishResolution == nil)
    }

    @Test(arguments: ["Asia/Shanghai", "America/Los_Angeles"])
    func mondayResetUsesLocalTimeAndDoesNotChangeCompanionProgress(zone: String) throws {
        var calendar = careCalendar
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 59))!
        var (_, care) = engineState()
        WishEngine.write("看海", tags: ["coast"], at: sunday, care: &care, calendar: calendar)
        let prior = care
        #expect(!WishEngine.refreshWeek(at: sunday.addingTimeInterval(59), care: &care, calendar: calendar))
        #expect(WishEngine.refreshWeek(at: sunday.addingTimeInterval(60), care: &care, calendar: calendar))
        #expect(care.wish == nil && care.wishResolution == nil)
        var expected = prior
        expected.wish = nil; expected.wishResolution = nil
        #expect(care == expected)
    }

    @Test func bilingualKeywordsUseTheSelectedLanguageAndEnglishWordBoundaries() {
        let content = testCatalog.wishes
        #expect(content.keywordTags(for: "想去靠海的城市，吃美食逛夜市", language: .zhHans) == ["coast", "food", "market"])
        #expect(content.keywordTags(for: "A BEACH, a museum and FOOD", language: .en) == ["coast", "art", "food"])
        #expect(content.keywordTags(for: "research earth department", language: .en).isEmpty)
        #expect(content.keywordTags(for: "看海", language: .en).isEmpty)
        #expect(content.keywordTags(for: "beach", language: .zhHans).isEmpty)
    }

    @Test func modelTagsAreAllowlistedAndFailuresFallBackToKeywords() async {
        let content = testCatalog.wishes
        let model: WishContent.Model = { text, language, tags in
            #expect(text == "beach" && language == .en && Set(tags).contains("art"))
            return ["art", "art", "invented", "coast; run a command", "{instruction}"]
        }
        #expect(await content.resolve("beach", language: .en, model: model) == ["coast", "art"])
        struct Failed: Error {}
        #expect(await content.resolve("beach", language: .en, model: { _, _, _ in throw Failed() }) == ["coast"])
        #expect(await content.resolve("beach", language: .en) == ["coast"])
        #expect(await content.resolve("beach", language: .en, model: { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return ["art"]
        }, timeout: .milliseconds(1)) == ["coast"])
        #expect(await content.resolve("", language: .en, model: { _, _, _ in
            Issue.record("Empty wishes must not call a model"); return ["art"]
        }).isEmpty)
    }

    @Test func contentValidationRejectsUnknownTagsMissingLanguagesAndEmptyKeywords() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("wish.json")
        let original = try Data(contentsOf: file)
        for mutation in 0..<4 {
            try original.write(to: file)
            try box.edit("wish.json") { json in
                if mutation == 3 { json["unmatched"] = ["en": "No match"] ; return }
                var keywords = json["keywords"] as! [String: [String: [String]]]
                if mutation == 0 { keywords["en"]?["unknown"] = ["other"] }
                if mutation == 1 { keywords.removeValue(forKey: "zh-Hans") }
                if mutation == 2 { keywords["en"]?["coast"] = [""] }
                json["keywords"] = keywords
            }
            #expect(ContentValidator.validate(directory: box.directory).contains { $0.file == "wish.json" })
        }
    }

    @Test func savedTagsDriveTheNextDrawWhileTheAlreadyDrawnLegStaysFixed() throws {
        var foundDifference = false
        for seed: UInt32 in 0..<40 {
            var (journey, care) = engineState(seed: seed)
            let target = journey.targetCityId, cost = journey.legCost, from = journey.legFrom, to = journey.legTo
            WishEngine.write("原文与标签无关", tags: ["coast", "food"], at: monday, care: &care)
            care = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care))
            let savedTags = WishEngine.tags(in: care)
            journey.sync(today: DayUsage(date: journey.openDate, fuel: 1), catalog: testCatalog, wishTags: savedTags)
            #expect(journey.targetCityId == target && journey.legCost == cost && journey.legFrom == from && journey.legTo == to)
            var plain = journey
            journey.sync(today: DayUsage(date: journey.openDate, fuel: cost), catalog: testCatalog, wishTags: savedTags)
            plain.sync(today: DayUsage(date: plain.openDate, fuel: cost), catalog: testCatalog)
            let expected = DestinationPicker.pick(from: to, currentCityId: target, route: journey.route,
                stampedCountries: Set(journey.stamps.map(\.countryCode)), medianFuel: 0,
                wishTags: savedTags, catalog: testCatalog, seed: seed)
            #expect(journey.targetCityId == expected)
            if journey.targetCityId != plain.targetCityId { foundDifference = true }
        }
        #expect(foundDifference)
        let coast = testCatalog.city("quanzhou")
        #expect(DestinationPicker.cityWeight(coast, route: [], stampedCountries: [], wishTags: ["coast"])
            == DestinationPicker.cityWeight(coast, route: [], stampedCountries: [], wishTags: []) * 3)
    }

    @Test func savedTagsSelectStoriesWithoutChangingRarityOrCompanionRules() {
        var art = engineStory("wish.art", city: "shanghai")
        art.tags = ["art"]
        let stories = engineStories([art])
        for seed: UInt32 in 0..<32 {
            var (journey, care) = engineState(seed: seed)
            care.bag.owned = ["raincoat"]
            var plainJourney = journey, plainCare = care
            WishEngine.write("任意原文", tags: ["art"], at: monday, care: &care)
            for id in 1...12 {
                journey.letters.append(engineLetter(id))
                plainJourney.letters.append(engineLetter(id))
                CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: testCatalog, wishTags: WishEngine.tags(in: care))
                CareEngine.process(journey: &plainJourney, care: &plainCare, stories: stories, catalog: testCatalog)
                #expect(journey.letters.last?.storyId == "wish.art")
                #expect(journey.letters.last?.rewards == plainJourney.letters.last?.rewards)
                #expect(care.habits == plainCare.habits && care.pity == plainCare.pity)
                #expect(care.companionDays == plainCare.companionDays && care.pendingPromises == plainCare.pendingPromises)
            }
        }
    }

    @Test func unmatchedExplanationIsBilingualSnapshottedAndOnlyOnceEvenAfterCrashReplay() throws {
        var (journey, care) = engineState()
        WishEngine.write("咕噜咕噜", tags: [], at: monday, care: &care)
        let before = care
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        let first = try #require(journey.letters.last)
        #expect(first.wishExplanationAt == care.wishResolution?.parsedAt)
        for language in Language.allCases {
            #expect(first.texts?[language.rawValue]?.hasSuffix(testCatalog.wishes.unmatched[language.rawValue]!) == true)
        }
        care = before // journey saved, care write interrupted.
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(care.wishResolution?.explanationLetterId == first.id)
        #expect(journey.letters.last == first)
        journey.letters.append(engineLetter(2))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.last?.wishExplanationAt == nil)
        #expect(journey.letters.filter { $0.wishExplanationAt != nil }.count == 1)
        WishEngine.write("咕噜咕噜", tags: [], at: monday.addingTimeInterval(5), care: &care)
        #expect(care.wishResolution?.explanationLetterId == first.id) // same raw wish is unchanged.
        WishEngine.write("叽里咕噜", tags: [], at: monday.addingTimeInterval(10), care: &care)
        journey.letters.append(engineLetter(3))
        CareEngine.process(journey: &journey, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(journey.letters.filter { $0.wishExplanationAt != nil }.count == 2)
    }

    @Test func legacyCareWithStringOnlyOrWithoutWishDecodesWithoutParsing() throws {
        let (_, initial) = engineState()
        let raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        for text in [nil, "想看海"] as [String?] {
            var json = raw
            json["wish"] = text
            json.removeValue(forKey: "wishResolution")
            let care = try JSONDecoder().decode(CareState.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(care.wish == text && care.wishResolution == nil)
            #expect(WishEngine.tags(in: care).isEmpty)
        }
    }

    @Test func companionMailDoesNotConsumeAnUnmatchedWish() {
        var (journey, care) = engineState()
        WishEngine.write("blorble", tags: [], at: monday, care: &care)
        for (offset, kind) in [Letter.Kind.postcard, .reunion, .weekly].enumerated() {
            var letter = engineLetter(offset + 1)
            letter.kind = kind
            journey.letters.append(letter)
        }
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(care.wishResolution?.explanationLetterId == nil)
        #expect(journey.letters.allSatisfy { $0.wishExplanationAt == nil })
        journey.letters.append(engineLetter(4))
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(care.wishResolution?.explanationLetterId == 4)
    }
}
