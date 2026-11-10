import Foundation
import Testing
@testable import VoyageCore

private func visitDate(_ day: Int) -> Date {
    careCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

private func visit(_ day: Int, journey: inout JourneyState, care: inout CareState) {
    CareEngine.open(at: visitDate(day), journey: &journey, care: &care, catalog: testCatalog, calendar: careCalendar)
}

@Suite struct CompanionMailTests {
    @Test func morningZeroThenLaterUsageNeverProducesAPostcard() {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-01"), now: DayKey.date(from: (DayUsage(date: "2026-11-01")).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        let morning = careCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        CareEngine.open(at: morning, journey: &journey, care: &care, catalog: testCatalog, calendar: careCalendar)
        #expect(!journey.letters.contains { $0.kind == .postcard })
        #expect(care.companionDays.isEmpty)
        journey.sync(today: DayUsage(date: "2026-11-01", fuel: 100), now: DayKey.date(from: (DayUsage(date: "2026-11-01", fuel: 100)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        #expect(!journey.letters.contains { $0.kind == .postcard })
        journey.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01", fuel: 100)], now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600),
                     calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(!journey.letters.contains { $0.kind == .postcard })
        #expect(journey.letters.filter { $0.kind == .daily }.map(\.date) == ["2026-11-01"])
    }

    @Test func unopenedDaysNeverProducePostcardsAndReunionUsesOnlyOpens() {
        var (journey, care) = engineState()
        journey.sync(today: DayUsage(date: "2026-11-01"), now: DayKey.date(from: (DayUsage(date: "2026-11-01")).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        visit(1, journey: &journey, care: &care)
        #expect(!journey.letters.contains { $0.kind == .postcard })
        #expect(care.companionDays.isEmpty)
        let before = journey
        visit(1, journey: &journey, care: &care)
        #expect(journey == before)
        journey.sync(today: DayUsage(date: "2026-11-04"), finalized: [
            DayUsage(date: "2026-11-02", fuel: 500), DayUsage(date: "2026-11-03", fuel: 500),
        ], now: DayKey.date(from: (DayUsage(date: "2026-11-04")).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey.letters.filter { $0.kind == .postcard }.count == 1)
        #expect(care.companionDays.isEmpty)
        visit(4, journey: &journey, care: &care)
        #expect(journey.letters.filter { $0.kind == .reunion }.map(\.date) == ["2026-11-04"])
        #expect(journey.letters.filter { $0.kind == .postcard }.map(\.date) == ["2026-11-01"])
        #expect(care.companionDays.isEmpty)
        for letter in journey.letters where [.postcard, .reunion].contains(letter.kind) {
            #expect(letter.rewards.itemIds.count == 1 && letter.rewardItems.count == 1)
            #expect(letter.memoryReference == nil && letter.leadTexts.isEmpty)
        }
        let saved = (journey, care)
        visit(4, journey: &journey, care: &care)
        visit(2, journey: &journey, care: &care)
        #expect(journey == saved.0 && care == saved.1)
    }

    @Test func threeCalendarDaysIsInclusiveAndRepeatedOpensResetAbsence() {
        var (journey, care) = engineState()
        visit(1, journey: &journey, care: &care)
        visit(3, journey: &journey, care: &care)
        #expect(!journey.letters.contains { $0.kind == .reunion })
        visit(5, journey: &journey, care: &care)
        #expect(!journey.letters.contains { $0.kind == .reunion })
        visit(8, journey: &journey, care: &care)
        #expect(journey.letters.filter { $0.kind == .reunion }.count == 1)
        #expect(care.companionDays.isEmpty) // Reading mail, rather than merely reopening, earns an active-day stamp.
    }

    @Test(arguments: Array(UInt32(0)..<12))
    func doublingUsagePreservesMailDropsCompanionshipAndPromiseTiming(seed: UInt32) {
        func run(_ multiplier: Int) -> (JourneyState, CareState) {
            var (journey, care) = engineState(seed: seed)
            for day in 1...15 {
                let date = DayKey.string(from: visitDate(day), calendar: careCalendar)
                let yesterday = journey.openDate
                let fuel = day % 2 == 0 ? 100 * multiplier : 0
                journey.sync(today: DayUsage(date: date, fuel: fuel), finalized: [
                    DayUsage(date: yesterday, fuel: journey.fuel(on: yesterday)),
                ], now: DayKey.date(from: (DayUsage(date: date, fuel: fuel)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
                CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
                if [1, 2, 5, 6, 9, 13, 15].contains(day) { visit(day, journey: &journey, care: &care) }
                if let letter = journey.letters.first(where: { !$0.replyOptions.isEmpty && $0.selectedReplyId == nil }) {
                    CareEngine.reply(letterId: letter.id, replyId: letter.replyOptions[0].id, date: date, journey: &journey, care: &care)
                }
            }
            return (journey, care)
        }
        let (a, ca) = run(1), (b, cb) = run(2)
        #expect(a.letters.map(\.kind) == b.letters.map(\.kind))
        #expect(a.letters.map(\.fulfilledReplyId) == b.letters.map(\.fulfilledReplyId))
        #expect(a.letters.map(\.rewards) == b.letters.map(\.rewards))
        #expect(a.letters.filter { [.postcard, .reunion].contains($0.kind) } == b.letters.filter { [.postcard, .reunion].contains($0.kind) })
        #expect(ca == cb)
    }

    @Test func doublingMileageAcrossDifferentCitiesKeepsCompanionMailAndItsDropsIdentical() {
        func run(_ multiplier: Int) -> (JourneyState, CareState) {
            var (journey, care) = engineState(seed: 42)
            for day in 1...10 {
                let date = DayKey.string(from: visitDate(day), calendar: careCalendar)
                journey.sync(today: DayUsage(date: date, fuel: day % 2 == 0 ? 20_000_000 * multiplier : 0), now: DayKey.date(from: (DayUsage(date: date, fuel: day % 2 == 0 ? 20_000_000 * multiplier : 0)).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600),
                             calendar: careCalendar, catalog: testCatalog)
                CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
                if [1, 2, 5, 7, 10].contains(day) { visit(day, journey: &journey, care: &care) }
            }
            return (journey, care)
        }
        let (a, ca) = run(1), (b, cb) = run(2)
        #expect(a.route != b.route)
        let first = a.letters.filter { [.postcard, .reunion].contains($0.kind) }
        let second = b.letters.filter { [.postcard, .reunion].contains($0.kind) }
        #expect(first.map(\.kind) == second.map(\.kind) && first.map(\.date) == second.map(\.date))
        #expect(first.map(\.texts) == second.map(\.texts))
        #expect(first.map { $0.rewards.itemIds } == second.map { $0.rewards.itemIds })
        #expect(first.map { $0.rewards.dropRarity } == second.map { $0.rewards.dropRarity })
        #expect(ca.companionDays == cb.companionDays && ca.weekly == cb.weekly && ca.pity == cb.pity)
    }

    @Test func postcardsSharePityButNeitherKindAdvancesPromisesOrConsumesTheBag() {
        var (journey, care) = engineState()
        journey.letters.append(engineLetter(1))
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let reply = journey.letters[1].replyOptions[0]
        CareEngine.reply(letterId: 1, replyId: reply.id, date: "2026-11-01", journey: &journey, care: &care)
        care.pity = 8
        care.bag.todayItem = "sketchbook"
        journey.sync(today: DayUsage(date: "2026-11-01"), now: DayKey.date(from: (DayUsage(date: "2026-11-01")).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        visit(1, journey: &journey, care: &care)
        journey.sync(today: DayUsage(date: "2026-11-02"), now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey.letters.last?.rewards.dropRarity == "rare" && care.pity == 0)
        #expect(care.pendingPromises.first?.attempts == 0 && care.bag.todayItem == "sketchbook")
        care.pity = 8
        visit(4, journey: &journey, care: &care)
        #expect(journey.letters.last?.kind == .reunion && care.pity == 8)
        #expect(care.pendingPromises.first?.attempts == 0)
        var daily = engineLetter(journey.letters.last!.id + 1, date: "2026-11-04")
        daily.arrivals = []
        journey.letters.append(daily)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey.letters.last?.fulfilledReplyId == reply.id)
        #expect(journey.letters.last?.rewards.dropRarity == "rare" && care.pity == 0)
    }

    @Test(arguments: ["reply", "fulfilled"])
    func memoryCitationsAndItemsRemainSnapshotsThroughContentChangesAndInterruptedWrites(kind: String) throws {
        var (journey, care) = engineState()
        var origin = engineLetter(1)
        origin.storyId = "saved"
        origin.replyOptions = [.init(id: "remember", habit: "observant", text: ["zh-Hans": "看一眼{pet}", "en": "Look at {pet}"])]
        origin.learnedTexts = ["zh-Hans": "慢慢走", "en": "Walk slowly"]
        journey.letters.append(origin)
        care.processedLetterIds.append(1)
        care.memories = [.init(kind: kind, date: "2026-11-01", letterId: 1, replyId: "remember")]
        journey.sync(today: DayUsage(date: "2026-11-01"), now: DayKey.date(from: (DayUsage(date: "2026-11-01")).date, calendar: .current)!.addingTimeInterval(12 * 3600), catalog: testCatalog)
        let beforeCare = care
        visit(1, journey: &journey, care: &care)
        journey.sync(today: DayUsage(date: "2026-11-02"), now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let snapshot = try #require(journey.letters.last)
        #expect(snapshot.memoryReference == beforeCare.memories.first)
        #expect(snapshot.leadTexts["en"]?.contains(kind == "reply" ? "Look at {pet}" : "Walk slowly") == true)
        let encoded = try JSONEncoder().encode(journey)
        journey = try JSONDecoder().decode(JourneyState.self, from: encoded)
        var replayedCare = beforeCare
        var changed = testCatalog.stories.all
        for index in changed.indices { changed[index].text = ["en": "Changed", "zh-Hans": "修改"]; changed[index].memoryLead = nil }
        CareEngine.process(journey: &journey, care: &replayedCare, stories: .init(stories: changed), catalog: testCatalog)
        #expect(journey.letters.last == snapshot && replayedCare == care)
        let savedCare = replayedCare
        visit(1, journey: &journey, care: &replayedCare)
        CareEngine.process(journey: &journey, care: &replayedCare, stories: testCatalog.stories, catalog: testCatalog)
        #expect(replayedCare == savedCare && journey.letters.last == snapshot)
    }

    @Test func zeroDayWaitsForNextDeliveryTimeAndSettlesOnlyOnce() throws {
        var (journey, care) = engineState()
        visit(1, journey: &journey, care: &care)
        #expect(journey.letters.count == 1 && care.companionDays.isEmpty)
        let delivery = DeliveryTime(hour: 14, minute: 30)!
        journey.sync(today: DayUsage(date: "2026-11-02"), now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, deliveryTime: delivery)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let postcard = try #require(journey.letters.first { $0.kind == .postcard })
        let due = careCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 14, minute: 30))!
        #expect(postcard.date == "2026-11-01" && postcard.deliverAt == due && !postcard.read)
        #expect(!journey.deliveredLetters(now: due.addingTimeInterval(-1)).contains(postcard))
        #expect(journey.unreadCount(now: due.addingTimeInterval(-1)) == 0)
        #expect(journey.deliveredLetters(now: due).contains(postcard) && journey.unreadCount(now: due) == 1)
        #expect(care.companionDays.isEmpty)
        let saved = (journey, care)
        journey.sync(today: DayUsage(date: "2026-11-02"), now: DayKey.date(from: (DayUsage(date: "2026-11-02")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog, deliveryTime: delivery)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey == saved.0 && care == saved.1)
    }

    @Test func catchUpSettlesOpenedDaysInDateOrderAndSkipsUnopenedDays() throws {
        var (journey, care) = engineState()
        // Opens are persisted even while scans are unavailable; lastOpenedDate alone loses this history.
        for day in [1, 2, 4, 5] { visit(day, journey: &journey, care: &care) }
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        journey.sync(today: DayUsage(date: "2026-11-07"), finalized: [
            DayUsage(date: "2026-11-02", fuel: 100), DayUsage(date: "2026-11-06", fuel: 200),
        ], now: DayKey.date(from: (DayUsage(date: "2026-11-07")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        let settled = journey.letters.filter { [.daily, .postcard].contains($0.kind) }
        #expect(settled.map(\.date) == ["2026-11-01", "2026-11-02", "2026-11-04", "2026-11-05", "2026-11-06"])
        #expect(settled.map(\.kind) == [.postcard, .daily, .postcard, .postcard, .daily])
        #expect(settled.map(\.id) == [1, 2, 3, 4, 5])
        #expect(care.companionDays.isEmpty)
        let saved = (journey, care)
        journey.sync(today: DayUsage(date: "2026-11-09"), now: DayKey.date(from: (DayUsage(date: "2026-11-09")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey.letters == saved.0.letters && care == saved.1)
    }

    @Test func reunionGiftRepairsAnInterruptedCareWriteOnceWithoutChangingPity() throws {
        var (journey, care) = engineState()
        visit(1, journey: &journey, care: &care)
        care.pity = 8
        let beforeCare = care
        visit(4, journey: &journey, care: &care)
        let savedJourney = journey
        var repaired = beforeCare
        CareEngine.process(journey: &journey, care: &repaired, stories: testCatalog.stories, catalog: testCatalog)
        #expect(journey == savedJourney && repaired == care && repaired.pity == 8)
        #expect(repaired.souvenirs.count == 1)
        visit(4, journey: &journey, care: &repaired)
        #expect(journey == savedJourney && repaired == care)
    }

    @Test(arguments: ["reply", "fulfilled"])
    func allMemoryLeadsAvoidDuplicateSentenceStops(kind: String) throws {
        for story in testCatalog.stories.all where story.memoryLead != nil {
            var (journey, care) = engineState()
            var origin = engineLetter(1)
            let quote = ["zh-Hans": "这是一个主意。", "en": "That is an idea."]
            origin.replyOptions = [.init(id: "remember", habit: "observant", text: quote)]
            origin.learnedTexts = quote
            journey.letters.append(origin)
            care.memories = [.init(kind: kind, date: "2026-11-01", letterId: 1, replyId: "remember")]
            var letter = engineLetter(2)
            letter.kind = try #require(Letter.Kind(rawValue: story.kind))
            CareEngine.snapshotCompanionMail(letter: &letter, journey: journey, care: care, stories: .init(stories: [story]), catalog: testCatalog)
            #expect(letter.memoryReference != nil)
            #expect(letter.leadTexts.count == 2)
            for lead in letter.leadTexts.values {
                #expect(!lead.contains(".”.") && !lead.contains("。”。"))
                #expect(!lead.contains("{memory}"))
            }
            #expect(letter.leadTexts["en"]?.contains("That is an idea") == true)
            #expect(origin.learnedTexts == quote)
        }
    }

    @Test func versionSixFixturePreservesLocalOpenHistory() throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "journey-v6", withExtension: "json", subdirectory: "Fixtures")))
        var journey = try decodeOldJourneyFixture(data)
        #expect(journey.version == 8 && journey.lastOpenedDate == "2026-11-02")
        #expect(journey.days["2026-11-02"]?.mainWindowOpened == true)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey)) == journey)
        journey.sync(today: DayUsage(date: "2026-11-04"), now: DayKey.date(from: (DayUsage(date: "2026-11-04")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        #expect(journey.letters.filter { $0.kind == .postcard }.map(\.date) == ["2026-11-02"])
    }

    @Test func frozenSavesUpgradeWithoutInventingPastOpensOrMail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-m2-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["journey-v5", "care-v1"] {
            let original = try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
            try original.write(to: directory.appendingPathComponent(name.hasPrefix("journey") ? "journey.json" : "care.json"))
        }
        let store = SaveStore(directory: directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
        store.load()
        guard case .loaded(var journey) = store.journey, case .loaded(var care) = store.care else { Issue.record("Upgrade failed"); return }
        #expect(journey.days.values.allSatisfy { !$0.mainWindowOpened })
        journey.sync(today: DayUsage(date: "2026-11-20"), now: DayKey.date(from: (DayUsage(date: "2026-11-20")).date, calendar: careCalendar)!.addingTimeInterval(12 * 3600), calendar: careCalendar, catalog: testCatalog)
        let oldLetters = journey.letters
        #expect(journey.version == JourneyState.currentVersion && journey.lastOpenedDate == nil)
        #expect(journey.letters.allSatisfy { $0.rewardItems.isEmpty && $0.memoryReference == nil })
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories, catalog: testCatalog)
        visit(20, journey: &journey, care: &care)
        #expect(journey.letters == oldLetters)
        #expect(journey.lastOpenedDate == "2026-11-20")
        try store.save(journey)
        try store.save(care)
        #expect(try store.backups(for: .journey).count == 1)
    }
}
