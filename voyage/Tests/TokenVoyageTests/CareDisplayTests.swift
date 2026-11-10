import AppKit
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let careDisplayDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!

@Test(arguments: [0.0, 1, 239, 240, 241, 479.9, 480, 719, 720, 1000, 1440])
func roomAlwaysChoosesLargestIntegerScaleThatFits(width: Double) {
    let scale = RoomLayout.scale(availableWidth: width)
    #expect(scale >= 0)
    #expect(Double(scale * RoomLayout.width) <= width)
    #expect(Double((scale + 1) * RoomLayout.width) > width)
}

@MainActor
@Test(arguments: [0.0, 119.9, 120, 121, 239.9, 240, 359, 360, 472, 719.5, 736, 1055.5])
func mapsChooseTheLargestIntegerScaleAndCenterAtWholePoints(width: Double) {
    let city = localizationCatalog.city("shanghai")
    let state = JourneyState(seed: 7, startCityId: city.id, date: "2026-11-01", catalog: localizationCatalog)
    for definition in testThemes.all {
        let theme = AppTheme(definition)
        for image in [PixelMap.homeImage(city, theme: theme), PixelMap.image(for: state, catalog: localizationCatalog, theme: theme)] {
            let map = PixelMapView(image: image, availableWidth: width, borderColor: theme.mapBorder)
            #expect(map.scale == RoomLayout.scale(availableWidth: width, pixelWidth: WorldMapData.width))
            #expect(map.size.width == CGFloat(map.scale * WorldMapData.width))
            #expect(map.size.height == CGFloat(map.scale * WorldMapData.height))
            #expect(map.size.width <= width && map.size.width + CGFloat(WorldMapData.width) > width)
            #expect(map.leadingInset >= 0 && map.leadingInset == floor(map.leadingInset))
            let trailingInset = width - map.leadingInset - map.size.width
            #expect(trailingInset >= map.leadingInset && trailingInset - map.leadingInset < 2)
            #expect(!image.shouldInterpolate)
        }
    }
}

@Test(arguments: [760.0, 780, 989, 990, 1000, 1200, 1920])
func homeKeepsRoomAtTwoOrThreeTimesWithAWrappingRightColumn(width: Double) {
    let layout = HomeLayout(windowWidth: width)
    #expect(layout.contentWidth + 24 <= width)
    #expect(layout.rightWidth >= 230)
    #expect(layout.roomWidth == (width < 990 ? 480 : 720))
    #expect(layout.contentWidth == layout.roomWidth + 16 + layout.rightWidth)
}

@Test(arguments: [RoomLayout.weekFloorMinRows, 58, 120])
func weekFloorTilesStayInsideAndApart(rows: Int) {
    let floor = CGRect(x: 0, y: 0, width: RoomLayout.width, height: rows)
    let tiles = (0..<7).map { RoomLayout.weekTile($0, rows: rows) }
    for (index, tile) in tiles.enumerated() {
        // The drop shadow extends two rows below each tile.
        #expect(floor.contains(tile.insetBy(dx: 0, dy: -2)))
        if index > 0 { #expect(!tile.intersects(tiles[index - 1])) }
    }
}

@Test(arguments: [2, 3])
func roomBubblesStayInsideWithoutCoveringTheShelfOrPet(scale: Int) {
    let factor = CGFloat(scale)
    let room = CGRect(x: 0, y: 0, width: 240 * factor, height: 132 * factor)
    let shelf = CGRect(x: 78 * factor, y: 40 * factor, width: 78 * factor, height: 15 * factor)
    let pet = CGRect(x: 116 * factor, y: 76 * factor, width: 32 * factor, height: 32 * factor)
    for souvenir in [true, false] {
        let region = RoomLayout.bubbleRegion(scale: scale, souvenir: souvenir)
        #expect(room.contains(region) && !shelf.intersects(region))
        if !souvenir { #expect(!pet.intersects(region)) }
        for language in Language.allCases {
            let l10n = L10n(language: language)
            let texts = souvenir ? localizationCatalog.items.all.map(l10n.itemDescription)
                : ["home.bubble.mail", "home.bubble.reply", "home.bubble.bag"].map { l10n($0) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            for text in texts {
                let bounds = (text as NSString).boundingRect(
                    with: CGSize(width: region.width - 16, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
                #expect(ceil(bounds.height) + 16 <= region.height)
            }
        }
    }
}

@Test(arguments: [(0, 0), (1, 1), (30, 30), (100, 100), (1, 0), (0, 1), (30, 10), (10, 30)])
func homeHabitSummaryShowsBothPositiveTiesAndOmitsZero(talkative: Int, observant: Int) {
    var habits = CareState.Habits()
    habits.talkative = talkative
    habits.observant = observant
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let summary = ProfileDisplay.habitSummary(habits, l10n: l10n)
        if talkative == 0 && observant == 0 { #expect(summary == nil) }
        else if talkative == observant {
            #expect(summary == (language == .en ? "Chatty and observant" : "爱搭话，也爱观察"))
        } else {
            #expect(summary == l10n.habit(talkative > observant ? .talkative : .observant))
        }
    }
}

@Test func floatingReactionFitsTheTextAndCapsItAtTwoLines() {
    let short = FloatingLayout.reactionSize(text: "Hi!")
    let long = FloatingLayout.reactionSize(text: String(repeating: "A lesson from the road. ", count: 20))
    #expect(short.width == 150 && short.height == 48)
    #expect(long.width == 300 && long.height > short.height && long.height <= 64)
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let texts = L10n.floatingKeys.map { l10n($0) }
            + localizationCatalog.stories.all.compactMap { LetterComposer.localized($0.learned ?? [:], l10n: l10n) }
        for text in texts {
            let size = FloatingLayout.reactionSize(text: text)
            #expect((150...300).contains(size.width) && (48...64).contains(size.height))
        }
    }
}

@Test func floatingReactionKeepsItsTopLeftAtScreenEdgesAndRestoresTheRememberedFrame() {
    let visible = CGRect(x: -1440, y: 24, width: 1440, height: 876)
    for x in [visible.minX, visible.maxX - 174, visible.maxX - 150] {
        for y in [visible.minY, visible.minY + 4, visible.maxY - 48] {
            let normal = CGRect(origin: CGPoint(x: x, y: y), size: FloatingLayout.size)
            let maximum = FloatingLayout.availableReactionSize(normal: normal, visible: visible)
            let size = FloatingLayout.reactionSize(text: String(repeating: "长一点的路上心得。", count: 10), maximum: maximum)
            let speech = FloatingLayout.reactionFrame(normal: normal, size: size)
            #expect(speech.minX == normal.minX && speech.maxY == normal.maxY)
            #expect(visible.contains(speech))
            #expect(FloatingLayout.restoredFrame(normal: normal, speech: speech, current: speech, visible: visible) == normal)
            let dragged = speech.offsetBy(dx: -30, dy: -20)
            let restored = FloatingLayout.restoredFrame(normal: normal, speech: speech, current: dragged, visible: visible)
            #expect(visible.contains(restored) && restored.size == FloatingLayout.size)
            #expect(restored.minX == max(visible.minX, normal.minX - 30))
            #expect(restored.maxY == max(visible.minY + 48, normal.maxY - 20))
        }
    }
}

@Test func pixelInterfaceCopyUsesStraightApostrophes() {
    let l10n = L10n(language: .en)
    for key in ["box.title", "home.bubble.reply", "profile.nextStage"] {
        #expect(!l10n(key).contains("’") && l10n(key).contains("'"))
    }
}

@MainActor
@Test func roomArtUsesCurrentSpeciesAndOnlySelectedShelfSlots() throws {
    let item = try #require(localizationCatalog.items.find("box.tea-paper"))
    for pet in localizationCatalog.pets.all.map(\.id) {
        let room = RoomArt.image(pet: pet, shelf: [], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets)
        #expect(room.width == 240 && room.height == 132 && !room.shouldInterpolate)
        let data = try #require(room.dataProvider?.data) as Data
        for (index, color) in Sprites.petPixels(pet, catalog: localizationCatalog.pets).enumerated() {
            guard let color else { continue }
            let x = 116 + index % 16 * 2
            let y = 76 + index / 16 * 2
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let offset = ((y + dy) * 240 + x + dx) * 4
                    #expect(data[offset] == UInt8(color >> 16 & 255))
                    #expect(data[offset + 1] == UInt8(color >> 8 & 255))
                    #expect(data[offset + 2] == UInt8(color & 255))
                }
            }
        }
    }
    let empty = try #require(RoomArt.image(pet: PetID(rawValue: "pigeon"), shelf: [], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets).dataProvider?.data) as Data
    let full = try #require(RoomArt.image(pet: PetID(rawValue: "pigeon"), shelf: [item], theme: AppTheme(testThemes.standard(.dark)), catalog: localizationCatalog.pets).dataProvider?.data) as Data
    #expect(empty != full)
    for y in 0..<132 {
        for x in 0..<240 where !(80..<92).contains(x) || !(40..<52).contains(y) {
            let offset = (y * 240 + x) * 4
            #expect(empty[offset..<(offset + 4)] == full[offset..<(offset + 4)])
        }
    }
}

@Test func shelfFiltersBeforeLimitingAndKeepsAcquisitionOrder() throws {
    var care = CareState(petName: "Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: "2026-11-02")
    care.souvenirs = try JSONDecoder().decode([CareState.Souvenir].self, from: Data("""
        [{"id":"z","letterId":1,"shelved":false},
         {"id":"b","letterId":3,"shelved":true},
         {"id":"a","letterId":2,"shelved":true},
         {"id":"c","letterId":4,"shelved":true},
         {"id":"e","letterId":5,"shelved":true},
         {"id":"d","letterId":6,"shelved":true}]
        """.utf8))
    #expect(RoomLayout.shelf(care).map(\.id) == ["b", "a", "c", "e"])
    care.souvenirs.removeAll()
    #expect(RoomLayout.shelf(care).isEmpty)
}

@MainActor @Test func bubblesUseUnreadThenLatestReadUnansweredThenBagThenSilence() throws {
    var examples = Snapshots.mailExamples(catalog: localizationCatalog, now: careDisplayDate, petName: "Ginkgo")
    var care = CareState(petName: "Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: "2026-11-02")
    let latest = try #require(examples.letters.max { $0.id < $1.id })
    #expect(!latest.replyOptions.isEmpty)
    #expect(PetBubble.current(letters: examples.deliveredLetters(now: careDisplayDate), care: care) == .mail)
    for index in examples.letters.indices { examples.letters[index].read = true }
    #expect(PetBubble.current(letters: examples.letters, care: care) == .reply(latest.id))
    let lastIndex = try #require(examples.letters.firstIndex { $0.id == latest.id })
    examples.letters[lastIndex].selectedReplyId = latest.replyOptions[0].id
    #expect(PetBubble.current(letters: examples.letters, care: care) == .bag)
    care.bag.todayItem = "sketchbook"
    #expect(PetBubble.current(letters: examples.letters, care: care) == nil)
    // An older unanswered letter must not displace the latest read letter.
    examples.letters[lastIndex].replyOptions = []
    #expect(PetBubble.current(letters: examples.letters, care: care) == nil)
    care.bag.todayItem = nil
    #expect(PetBubble.current(letters: [], care: care) == .bag)
}

@Test(arguments: [(0, "再 4 章开礼盒"), (3, "再 1 章开礼盒"), (4, "再 2 章多一件"), (5, "再 1 章多一件"), (6, "")])
func weeklyCopyAndLocalizedMondayToSundayCells(count: Int, expected: String) {
    var care = CareState(petName: "Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: "2026-11-02")
    care.weekly.stamps = (2..<(2 + count)).map { String(format: "2026-11-%02d", $0) }
    care.weekly.boxes = Array(["2026-11-02#4", "2026-11-02#6"].prefix(count < 4 ? 0 : count < 6 ? 1 : 2))
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let week = WeekDisplay(care: care, now: careDisplayDate, l10n: l10n)
        #expect(week.days.map(\.label) == (0..<7).map { l10n.weekday($0) })
        #expect(week.days.first?.id == "2026-11-02")
        #expect(week.days.last?.id == "2026-11-08")
        #expect(week.days.filter(\.today).map(\.id) == ["2026-11-08"])
        #expect(week.days.filter(\.stamped).count == count)
        #expect(week.pendingBoxes == care.weekly.boxes.count)
        #expect((week.boxButton(l10n: l10n) == nil) == (count < 4))
        if language == .zhHans { #expect((week.progressText(l10n: l10n) ?? "") == expected) }
        else { #expect(!containsHan((week.progressText(l10n: l10n) ?? "") + (week.boxButton(l10n: l10n) ?? ""))) }
        if let button = week.boxButton(l10n: l10n) { #expect(button.contains("\(care.weekly.boxes.count)")) }
        let monday = Calendar.current.date(byAdding: .day, value: 1, to: careDisplayDate)!
        let next = WeekDisplay(care: care, now: monday, l10n: l10n)
        #expect(next.stampCount == 0 && next.pendingBoxes == week.pendingBoxes)
    }
}

@Test(arguments: [(0, 0), (1, 1), (29, 1), (30, 2), (59, 2), (60, 3), (100, 3)])
func habitsUseDistinctNaturalDescriptionsWithoutNumbers(value: Int, band: Int) {
    var habits = CareState.Habits()
    habits.talkative = value
    habits.observant = value
    for language in Language.allCases {
        let l10n = L10n(language: language)
        for habit in Habit.allCases {
            let text = l10n.habitDescription(habit, habits: habits)
            #expect(text == l10n(L10n.habitDescriptionKeys[habit]![band]))
            #expect(!text.contains { $0.isASCII && $0.isNumber })
            if language == .en { #expect(!containsHan(text)) }
        }
        #expect(l10n.habitDescription(.talkative, habits: habits) != l10n.habitDescription(.observant, habits: habits))
    }
}

@MainActor @Test func profileDeduplicatesCitiesConvertsMileageLimitsLessonsAndComputesRemainingDays() {
    var journey = Snapshots.mailExamples(catalog: localizationCatalog, now: careDisplayDate, petName: "银杏 Ginkgo")
    journey.route = ["shanghai", "beijing", "shanghai", "xian", "beijing"]
    journey.totalKm = 9820
    let first = journey.letters[0]
    journey.letters = (1...7).map { id in
        var letter = first
        letter.id = id
        letter.learnedTexts = ["en": "Lesson \(id)", "zh-Hans": "心得 \(id)"]
        return letter
    }.reversed()
    var care = CareState(petName: "银杏 Ginkgo", species: PetID(rawValue: "pigeon"), hatchedAt: "2025-11-01")
    care.companionDays = (0..<27).map { DayKey.string(from: Calendar.current.date(byAdding: .day, value: $0, to: DayKey.date(from: care.hatchedAt)!)!) }
    for language in Language.allCases {
        let l10n = L10n(language: language)
        let profile = ProfileDisplay(journey: journey, care: care, l10n: l10n)
        #expect(profile.stage == .teen && profile.days == 27)
        #expect(profile.cityCount == 3 && profile.kilometers == "9,820 km")
        #expect(profile.learned.map(\.id) == [7, 6, 5, 4, 3])
        #expect(profile.learned[0].text == (language == .en ? "Lesson 7" : "心得 7"))
        #expect(profile.next == l10n("profile.nextStage", l10n.days(33), l10n.stage(.traveler)))
        if language == .en { #expect(!containsHan(profile.next + profile.kilometers + profile.learned.map(\.text).joined())) }
    }
    care.companionDays = (0..<340).map { DayKey.string(from: Calendar.current.date(byAdding: .day, value: $0, to: DayKey.date(from: care.hatchedAt)!)!) }
    let legend = ProfileDisplay(journey: journey, care: care, l10n: L10n(language: .en))
    #expect(legend.stage == .legend && legend.next == L10n(language: .en)("profile.legend"))
    journey.letters = []
    #expect(ProfileDisplay(journey: journey, care: care, l10n: L10n(language: .en)).learned.isEmpty)
    #expect(ProfileDisplay.habitSummary(.init(), l10n: L10n(language: .en)) == nil)
    care.habits.talkative = 10
    #expect(ProfileDisplay.habitSummary(care.habits, l10n: L10n(language: .en)) == "Chatty")
    care.habits.observant = 30
    #expect(ProfileDisplay.habitSummary(care.habits, l10n: L10n(language: .en)) == "Observant")
}

@Test(arguments: [(1, false, FloatingClick.react), (2, false, .openPostOffice), (3, false, .openPostOffice), (1, true, .none), (2, true, .none)])
func floatingClickDistinguishesSingleDoubleAndDrag(count: Int, dragged: Bool, expected: FloatingClick) {
    #expect(FloatingClick.action(clickCount: count, dragged: dragged) == expected)
}

@Test func newCopyIsTranslatedAndEnglishContainsNoHan() throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: LocalizationTestFiles.catalog)) as? [String: Any])
    let strings = try #require(object["strings"] as? [String: [String: Any]])
    let prefixes = ["home.", "profile.", "stage.", "habit.", "box.", "floating."]
    for (key, entry) in strings where prefixes.contains(where: key.hasPrefix) {
        let locales = try #require(entry["localizations"] as? [String: [String: Any]])
        for language in Language.allCases {
            let unit = try #require(locales[language.rawValue]?["stringUnit"] as? [String: String])
            let value = try #require(unit["value"])
            #expect(!value.isEmpty && L10n(language: language)(key) == value)
            if language == .en { #expect(!containsHan(value)) }
        }
    }
    let zh = L10n(language: .zhHans)
    #expect(Stage.allCases.map(zh.stage) == ["蛋", "雏", "幼年", "少年", "旅人", "老练", "传奇"])
}
