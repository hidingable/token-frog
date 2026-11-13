import Foundation
import Testing
@testable import VoyageCore

private func friendState(days: Int = 6, seed: UInt32 = 7) -> (JourneyState, CareState) {
    var (journey, care) = engineState(seed: seed)
    care.settledIdentityStages = [.traveler, .veteran, .legend]
    addFriendCompanionDays(through: days, journey: &journey, care: &care)
    return (journey, care)
}

private func addFriendCompanionDays(through count: Int, journey: inout JourneyState, care: inout CareState) {
    let start = DayKey.date(from: care.hatchedAt, calendar: careCalendar)!
    for offset in care.companionDays.count..<count {
        let date = careCalendar.date(byAdding: .day, value: offset, to: start)!
        CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar)
    }
    journey.openDate = care.companionDays.last ?? journey.startDate
}

private func processFriends(_ journey: inout JourneyState, _ care: inout CareState,
                            catalog: CityCatalog = testCatalog, gate: JourneyGate = .open) {
    CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog,
                       calendar: careCalendar, gate: gate)
}

@Suite struct FriendTests {
    @Test(arguments: [(0, nil), (5, nil), (6, 6), (26, 6), (27, 27), (47, 27), (48, 48), (68, 48), (69, 69), (300, 300)] as [(Int, Int?)])
    func thresholdsBeginAtSixThenRepeatEveryTwentyOneDays(days: Int, threshold: Int?) {
        #expect(FriendRules.latestThreshold(companionDays: days) == threshold)
    }

    @Test func oneMeetingPerThresholdSurvivesRepeatedProcessing() throws {
        var (journey, care) = friendState(days: 0)
        for day in 1...48 {
            addFriendCompanionDays(through: day, journey: &journey, care: &care)
            processFriends(&journey, &care)
            let expected = [6, 27, 48].filter { $0 <= day }
            #expect(care.settledFriendThresholds ?? [] == expected)
            #expect(journey.letters.filter { $0.kind == .adventure }.count == expected.count)
            #expect(care.metFriends?.count ?? 0 == expected.count)
            let saved = (journey, care)
            for _ in 0..<3 { processFriends(&journey, &care) }
            #expect(journey == saved.0 && care == saved.1)
        }
        #expect(Set(try #require(care.metFriends).map(\.id)).count == 3)
    }

    @Test func seededDrawUsesSortedUnmetIDsAndItsOwnThresholdSalt() {
        let ids = testCatalog.friends.friends.map(\.id)
        var outcomes: Set<String> = []
        var thresholdsDiffer = false
        for seed: UInt32 in 0..<64 {
            let first = FriendRules.choose(unmetIDs: ids, seed: seed, threshold: 6)!
            #expect(first == FriendRules.choose(unmetIDs: Array(ids.reversed()), seed: seed, threshold: 6))
            var random = SplitMix64(seed: seed, stopCount: 6, salt: .friend)
            #expect(first == ids.sorted()[Int(random.next() % UInt64(ids.count))])
            outcomes.insert(first)
            if first != FriendRules.choose(unmetIDs: ids, seed: seed, threshold: 27) { thresholdsDiffer = true }
            #expect(FriendRules.choose(unmetIDs: ids.filter { $0 != first }, seed: seed, threshold: 27) != first)
        }
        #expect(outcomes == Set(ids))
        #expect(thresholdsDiffer)
        #expect(FriendRules.choose(unmetIDs: [], seed: 7, threshold: 6) == nil)
    }

    @Test func reversingTheContentFileCannotChangeTheMeetingOrSavedLetter() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        try box.edit("friends.json") { json in
            json["friends"] = Array((json["friends"] as! [[String: Any]]).reversed())
        }
        let reordered = try CityCatalog.load(directory: box.directory)
        var (first, firstCare) = friendState(seed: 42)
        var (second, secondCare) = friendState(seed: 42)
        processFriends(&first, &firstCare)
        processFriends(&second, &secondCare, catalog: reordered)
        #expect(first == second && firstCare == secondCare)
    }

    @Test(arguments: [(6, 6), (26, 6), (27, 27), (47, 27), (48, 48), (110, 90), (300, 300)])
    func legacyCatchUpGivesOnlyTheLatestPassedMeetingThenContinuesNormally(days: Int, threshold: Int) throws {
        var (journey, care) = friendState(days: days)
        journey.openDate = DayKey.next(journey.openDate, calendar: careCalendar)
        let upgradeDate = journey.openDate
        processFriends(&journey, &care)
        #expect(care.settledFriendThresholds == [threshold])
        #expect(care.metFriends?.count == 1 && care.metFriends?.first?.date == upgradeDate)
        #expect(journey.letters.filter { $0.kind == .adventure }.count == 1)
        processFriends(&journey, &care)
        #expect(care.metFriends?.count == 1)
        addFriendCompanionDays(through: threshold + 21, journey: &journey, care: &care)
        processFriends(&journey, &care)
        #expect(care.settledFriendThresholds == [threshold, threshold + 21])
        #expect(care.metFriends?.count == 2)
        #expect(try #require(care.metFriends).first?.id != care.metFriends?.last?.id)
    }

    @Test func exhaustedPoolStopsWithoutConsumingFurtherThresholds() throws {
        var (journey, care) = friendState(days: 0)
        let count = testCatalog.friends.friends.count
        for index in 0..<(count + 2) {
            addFriendCompanionDays(through: 6 + index * 21, journey: &journey, care: &care)
            processFriends(&journey, &care)
        }
        let friends = try #require(care.metFriends)
        #expect(Set(friends.map(\.id)) == Set(testCatalog.friends.friends.map(\.id)))
        #expect(friends.count == count)
        #expect(care.settledFriendThresholds == (0..<count).map { 6 + $0 * 21 })
        #expect(journey.letters.filter { $0.kind == .adventure }.count == count)
        let before = (journey, care)
        processFriends(&journey, &care)
        #expect(journey == before.0 && care == before.1)
    }

    @Test(arguments: [false, true])
    func meetingUsesTheMostRecentStayOrTheNoCityVariant(hasStay: Bool) throws {
        var (journey, care) = friendState()
        journey.currentCityId = "xian"
        journey.route = hasStay ? ["shanghai", "tokyo"] : []
        processFriends(&journey, &care)
        let mail = try #require(journey.letters.last)
        let snapshot = try #require(mail.friendSettlement)
        let friend = try #require(testCatalog.friends.friends.first { $0.id == snapshot.friendId })
        #expect(mail.kind == .adventure && mail.cityId == (hasStay ? "tokyo" : journey.homeCityId))
        #expect(snapshot.cityId == (hasStay ? "tokyo" : nil))
        #expect(care.metFriends?.first?.cityId == snapshot.cityId)
        #expect(care.metFriends?.first?.letterId == mail.id)
        #expect(snapshot.names == friend.name && mail.storyVersion == testCatalog.friends.version)
        for language in Language.allCases {
            let template = friend.letters[hasStay ? "city" : "noCity"]![language.rawValue]!
            let city = hasStay ? testCatalog.city("tokyo").names[language.rawValue]! : ""
            #expect(mail.texts?[language.rawValue] == StorySlots.render(template, values: ["pet": care.petName, "city": city]))
            #expect(mail.texts?[language.rawValue]?.contains("{") == false)
        }
    }

    @Test func journeyFirstCrashReplayKeepsTheOriginalFriendAndBilingualSnapshotAfterContentEdits() throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        var (journey, care) = friendState(seed: 42)
        journey.route = ["tokyo"]
        let beforeCare = care
        processFriends(&journey, &care)
        let mail = try #require(journey.letters.last)
        let bytes = try JSONEncoder().encode(journey)
        try box.edit("friends.json") { json in
            var friends = json["friends"] as! [[String: Any]]
            for index in friends.indices {
                friends[index]["name"] = ["zh-Hans": "修改的名字", "en": "Edited name"]
                friends[index]["letters"] = [
                    "city": ["zh-Hans": "{pet}在{city}寄来新正文。", "en": "Edited city letter from {pet} in {city}."],
                    "noCity": ["zh-Hans": "{pet}寄来新正文。", "en": "Edited roadside letter from {pet}."],
                ]
            }
            json["friends"] = friends
        }
        let edited = try CityCatalog.load(directory: box.directory)
        journey = try JSONDecoder().decode(JourneyState.self, from: bytes)
        journey.phase = .home
        var replay = beforeCare
        replay.petName = "A different current name"
        processFriends(&journey, &replay, catalog: edited, gate: JourneyGate { _ in false })
        #expect(replay.metFriends == care.metFriends && replay.settledFriendThresholds == [6])
        #expect(journey.letters.last == mail && journey.letters.filter { $0.kind == .adventure }.count == 1)
        #expect(mail.friendSettlement?.names != edited.friends.friends.first?.name)
        let recoveredCare = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(replay))
        processFriends(&journey, &replay, catalog: edited)
        #expect(replay == recoveredCare && journey.letters.last == mail)
    }

    @Test func identityAndAdventureCanArriveTogetherAtThePlayersNextLocalMorningAcrossDST() throws {
        var (journey, care) = friendState(days: 60)
        care.settledIdentityStages = nil
        journey.openDate = "2027-03-13"
        var calendar = careCalendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let delivery = DeliveryTime(hour: 9, minute: 30)!
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog,
                           calendar: calendar, deliveryTime: delivery)
        let special = journey.letters.filter { [.identity, .adventure].contains($0.kind) }
        let morning = calendar.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 9, minute: 30))!
        #expect(special.count == 2 && Set(special.map(\.kind.rawValue)) == ["identity", "adventure"])
        #expect(special.allSatisfy { $0.date == "2027-03-13" && $0.deliverAt == morning && !$0.read })
        #expect(journey.unreadCount(now: morning.addingTimeInterval(-1)) == 0)
        #expect(journey.unreadCount(now: morning) == 2)
        #expect(care.settledFriendThresholds == [48] && care.settledIdentityStages == [.traveler])
    }

    @Test func meetingChangesOnlyFriendStateAndTheMemoryBook() throws {
        var (journey, care) = friendState()
        care.pendingPromises = [.init(replyId: "ask-next-time", letterId: 0, attempts: 2)]
        care.pity = 8
        care.bag.todayItem = "sketchbook"
        care.trailClues = ["shanghai": 7]
        care.sponsoredDeliveryWeeks = ["2026-11-02": 2]
        care.habits.talkative = 27
        MemoryBook.backfill(journey: journey, care: &care)
        var expectedCare = care
        var expectedJourney = journey
        processFriends(&journey, &care)
        let mail = try #require(journey.letters.last)
        let snapshot = try #require(mail.friendSettlement)
        #expect(mail.rewards == StoryRewards() && mail.replyOptions.isEmpty && mail.learnedTexts.isEmpty)
        #expect(mail.carriedItem == nil && mail.itemTriggered == nil && mail.fulfilledReplyId == nil)
        #expect(mail.sponsor == nil && mail.rewardItems.isEmpty && mail.enrichmentDone)
        #expect(mail.arrivals.isEmpty && mail.fuel == 0 && mail.vehicles.isEmpty && mail.facts.isEmpty)
        expectedCare.metFriends = [.init(id: snapshot.friendId, date: mail.date, cityId: snapshot.cityId, letterId: mail.id)]
        expectedCare.settledFriendThresholds = [6]
        expectedCare.specialDays.append(.init(kind: .friendMet, date: mail.date, letterId: mail.id))
        expectedJourney.letters.append(mail)
        #expect(care == expectedCare && journey == expectedJourney)
        #expect(!CareEngine.reply(letterId: mail.id, replyId: "anything", date: journey.openDate, journey: &journey, care: &care))
        processFriends(&journey, &care)
        #expect(care == expectedCare && journey == expectedJourney)
    }

    @Test func doublingUsageWithTheSameReadingDaysKeepsFriendsAndMeetingDaysIdentical() throws {
        func run(_ multiplier: Int) -> (JourneyState, CareState) {
            var (journey, care) = friendState(days: 0, seed: 42)
            let start = DayKey.date(from: journey.startDate, calendar: careCalendar)!
            for offset in 0..<50 {
                let now = careCalendar.date(byAdding: .day, value: offset, to: start)!.addingTimeInterval(12 * 3600)
                let date = DayKey.string(from: now, calendar: careCalendar)
                let usage = DayUsage(date: date, observedTokens: (offset.isMultiple(of: 2) ? 40_000_000 : 100) * multiplier)
                journey.sync(today: usage, now: now, calendar: careCalendar, catalog: testCatalog)
                processFriends(&journey, &care)
                if let letter = journey.deliveredLetters(now: now).max(by: { $0.id < $1.id }) {
                    journey.markRead(letter.id)
                    CareEngine.markCompanion(date: now, care: &care, calendar: careCalendar)
                    processFriends(&journey, &care)
                }
                // A repeated usage scan cannot draw an extra friend.
                journey.sync(today: usage, now: now, calendar: careCalendar, catalog: testCatalog)
                processFriends(&journey, &care)
            }
            return (journey, care)
        }
        let (firstJourney, first) = run(1), (secondJourney, second) = run(2)
        #expect(firstJourney.totalKm != secondJourney.totalKm)
        #expect(first.companionDays == second.companionDays)
        #expect(first.settledFriendThresholds == [6, 27, 48] && first.settledFriendThresholds == second.settledFriendThresholds)
        #expect(try #require(first.metFriends).map(\.id) == second.metFriends?.map(\.id))
        #expect(first.metFriends?.map(\.date) == second.metFriends?.map(\.date))
    }

    @Test func closedGateLeavesTheThresholdUnconsumedAndReopeningMeetsExactlyOnce() throws {
        var (journey, care) = friendState()
        journey.phase = .home
        MemoryBook.backfill(journey: journey, care: &care)
        let before = (journey, care)
        for _ in 0..<3 { processFriends(&journey, &care, gate: JourneyGate { _ in false }) }
        #expect(care.metFriends == nil && care.settledFriendThresholds == nil)
        #expect(journey == before.0 && care == before.1)
        journey.openDate = DayKey.next(journey.openDate, calendar: careCalendar)
        let reopenDate = journey.openDate
        processFriends(&journey, &care)
        #expect(care.settledFriendThresholds == [6] && care.metFriends?.count == 1)
        #expect(care.metFriends?.first?.date == reopenDate)
        #expect(journey.letters.last?.date == reopenDate)
        let saved = (journey, care)
        processFriends(&journey, &care)
        #expect(journey == saved.0 && care == saved.1)
    }

    @Test func oldCareDecodesWithAbsentOptionalFriendFieldsAndKeepsVersionOne() throws {
        let fixture = try #require(Bundle.module.url(forResource: "care-v1", withExtension: "json", subdirectory: "Fixtures"))
        let care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture))
        #expect(care.metFriends == nil && care.settledFriendThresholds == nil)
        #expect(care.version == 1 && CareState.currentVersion == 1)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
    }

    @Test(arguments: Array(1...8))
    func oldJourneyLettersDecodeWithoutFriendSnapshots(version: Int) throws {
        let fixture = try #require(Bundle.module.url(forResource: "journey-v\(version)", withExtension: "json", subdirectory: "Fixtures"))
        let journey = try decodeOldJourneyFixture(Data(contentsOf: fixture))
        #expect(journey.letters.allSatisfy { $0.friendSettlement == nil })
        #expect(journey.version == 8 && JourneyState.currentVersion == 8)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
    }

    @Test func memoryBookBackfillsEveryFriendByLetterIDWithoutDuplicates() throws {
        var (journey, care) = friendState()
        processFriends(&journey, &care)
        addFriendCompanionDays(through: 27, journey: &journey, care: &care)
        processFriends(&journey, &care)
        let friends = try #require(care.metFriends)
        care.specialDays = []
        MemoryBook.backfill(journey: journey, care: &care)
        let days = care.specialDays.filter { $0.kind == .friendMet }
        #expect(days.count == 2 && Set(days.map(\.id)).count == 2)
        #expect(days.map(\.letterId) == friends.map { Optional($0.letterId) })
        #expect(days.map(\.date) == friends.map(\.date))
        let recovered = care
        for _ in 0..<3 { MemoryBook.backfill(journey: journey, care: &care) }
        #expect(care == recovered)
        #expect(try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(care)) == care)
    }

    @Test func unknownMemoryBookKindsRetainTheExistingDecodeRejection() throws {
        let (_, care) = friendState(days: 0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(care)) as? [String: Any])
        json["specialDays"] = [["kind": "future-milestone", "date": care.hatchedAt]]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CareState.self, from: data) }
    }

    @Test func dailyNotesAreStableAndRotateOncePerLocalDateAcrossTheYearBoundary() {
        for friend in testCatalog.friends.friends {
            let count = friend.notes.count
            var offsets: Set<Int> = []
            for seed: UInt32 in 0..<12 {
                var date = "2026-12-28"
                var indices: [Int] = []
                for _ in 0..<count {
                    let index = FriendRules.noteIndex(seed: seed, friendId: friend.id, date: date, count: count)
                    #expect(index == FriendRules.noteIndex(seed: seed, friendId: friend.id, date: date, count: count))
                    if let previous = indices.last { #expect(index == (previous + 1) % count) }
                    indices.append(index)
                    date = DayKey.next(date, calendar: careCalendar)
                }
                #expect(Set(indices) == Set(0..<count))
                offsets.insert(indices[0])
            }
            #expect(offsets.count > 1)
        }
    }
}
