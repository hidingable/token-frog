import Foundation
import Testing
@testable import VoyageCore

@Suite struct RoadClueTests {
    @Test(arguments: [UInt32(0), 7, 42])
    func dailyDrawIsIndependentOfUsageScanCountAndCatchUp(seed: UInt32) throws {
        var once = engineState(seed: seed).0
        var often = once
        var catchUp = once
        for day in 1...20 {
            let date = String(format: "2026-11-%02d", day)
            let fuel = day % 3 == 0 ? 0 : 10_000
            once.sync(today: .init(date: date, fuel: fuel), calendar: careCalendar, catalog: testCatalog)
            for amount in [0, fuel / 2, fuel, fuel * 2, fuel * 2] {
                often.sync(today: .init(date: date, fuel: amount), calendar: careCalendar, catalog: testCatalog)
            }
            let a = once.days[date]?.roadClueDecision, b = often.days[date]?.roadClueDecision
            #expect(a == b)
            #expect((fuel > 0) == (a != nil))
            often = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(often))
        }
        let finals = once.days.filter { $0.key < "2026-11-20" }.map { DayUsage(date: $0.key, fuel: $0.value.fuel) }
        catchUp.sync(today: .init(date: "2026-11-20", fuel: 20_000), finalized: finals, calendar: careCalendar, catalog: testCatalog)
        #expect(once.days.mapValues(\.roadClueDecision) == often.days.mapValues(\.roadClueDecision))
        #expect(once.days.mapValues(\.roadClueDecision) == catchUp.days.mapValues(\.roadClueDecision))
        #expect(once.days.values.contains { $0.roadClueDecision?.clue != nil })
        #expect(once.days.values.contains { $0.roadClueDecision != nil && $0.roadClueDecision?.clue == nil })
    }

    @Test func zeroUsageAndOpeningAWindowNeverSealADrawButLaterUsageMay() {
        var journey = engineState().0
        let date = journey.openDate
        journey.days[date, default: DayRecord()].mainWindowOpened = true
        for _ in 0..<10 { journey.sync(today: .init(date: date), catalog: testCatalog) }
        #expect(journey.days[date]?.roadClueDecision == nil)
        journey.sync(today: .init(date: date, fuel: 1), catalog: testCatalog)
        let decision = journey.days[date]?.roadClueDecision
        #expect(decision != nil)
        journey.sync(today: .init(date: date, fuel: 0), catalog: testCatalog)
        journey.sync(today: .init(date: date, fuel: 2_000_000_000), catalog: testCatalog)
        #expect(journey.days[date]?.roadClueDecision == decision)
    }

    @Test(arguments: [UInt32(0), 1, 7, 42])
    func contentUpdatesNeverRewriteEitherPopulatedOrEmptyDraws(seed: UInt32) throws {
        let box = try ContentSandbox(); defer { box.cleanUp() }
        var journey = engineState(seed: seed).0
        journey.sync(today: .init(date: journey.openDate, fuel: 1), catalog: testCatalog)
        let before = journey.days[journey.openDate]?.roadClueDecision
        let file = box.directory.appendingPathComponent("road-clues.json")
        var content = try JSONDecoder().decode(RoadClueContent.self, from: Data(contentsOf: file))
        content.version += 1
        for i in content.clues.indices {
            content.clues[i].id = "new-\(i)"
            content.clues[i].texts = ["en": "Changed copy.", "zh-Hans": "新的文案。"]
        }
        content.clues.reverse()
        try JSONEncoder().encode(content).write(to: file)
        let changed = try CityCatalog.load(directory: box.directory)
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        journey.sync(today: .init(date: journey.openDate, fuel: 2), catalog: changed)
        #expect(journey.days[journey.openDate]?.roadClueDecision == before)
        journey.sync(today: .init(date: "2026-11-03"), finalized: [.init(date: "2026-11-01", fuel: 4), .init(date: "2026-11-02", fuel: 1)], calendar: careCalendar, catalog: changed)
        #expect(journey.days["2026-11-01"]?.roadClueDecision == before)
        #expect(journey.days["2026-11-02"]?.roadClueDecision?.contentVersion == 2)
    }

    @Test func oldSavesDecodeAndActivateTodayWithoutPastClues() throws {
        for version in 1...6 {
            let url = try #require(Bundle.module.url(forResource: "journey-v\(version)", withExtension: "json", subdirectory: "Fixtures"))
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json.removeValue(forKey: "roadCluesEligibleFrom")
            if var days = json["days"] as? [String: [String: Any]] {
                for key in Array(days.keys) { days[key]?.removeValue(forKey: "roadClueDecision") }
                json["days"] = days
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("road-clue-upgrade-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("journey.json"))
            let store = SaveStore(directory: directory, pets: testCatalog.pets, journeyMigrations: .journey(catalog: testCatalog))
            store.load()
            guard case .loaded(var journey) = store.journey else { Issue.record("Version \(version) must load"); continue }
            #expect(journey.roadCluesEligibleFrom == nil)
            let oldOpen = journey.openDate
            journey.sync(today: .init(date: "2026-11-09", fuel: 1), finalized: [.init(date: oldOpen, fuel: 100)], calendar: careCalendar, catalog: testCatalog)
            #expect(journey.roadCluesEligibleFrom == "2026-11-09")
            #expect(journey.days.filter { $0.key < "2026-11-09" }.values.allSatisfy { $0.roadClueDecision == nil })
            #expect(journey.days["2026-11-09"]?.roadClueDecision != nil)
        }
    }

    @Test func observationsDoNotCreateLettersRewardsHabitsPromisesOrCompanionDays() {
        var (a, ca) = engineState()
        var b = a, cb = ca
        b.roadCluesEligibleFrom = "2099-01-01"
        ca.bag.todayItem = "sketchbook"; cb = ca
        for day in 1...12 {
            let date = String(format: "2026-11-%02d", day)
            for value in [1, 1000] {
                a.sync(today: .init(date: date, fuel: value), calendar: careCalendar, catalog: testCatalog)
                b.sync(today: .init(date: date, fuel: value), calendar: careCalendar, catalog: testCatalog)
                CareEngine.process(journey: &a, care: &ca, stories: testCatalog.stories, catalog: testCatalog)
                CareEngine.process(journey: &b, care: &cb, stories: testCatalog.stories, catalog: testCatalog)
                #expect(a.letters == b.letters && ca == cb)
            }
            if let letter = a.letters.first(where: { !$0.replyOptions.isEmpty && $0.selectedReplyId == nil }) {
                CareEngine.reply(letterId: letter.id, replyId: letter.replyOptions[0].id, date: date, journey: &a, care: &ca)
                CareEngine.reply(letterId: letter.id, replyId: letter.replyOptions[0].id, date: date, journey: &b, care: &cb)
            }
        }
        #expect(ca == cb && ca.companionDays.isEmpty && ca.trailClues == cb.trailClues)
        #expect(a.days.values.contains { $0.roadClueDecision?.clue != nil })
        #expect(b.days.values.allSatisfy { $0.roadClueDecision == nil })
    }

    @Test(arguments: ["translation", "blank", "duplicate", "tooFew", "slot", "version"])
    func contentGateRejectsIncompleteOrInvalidObservations(failure: String) throws {
        let box = try ContentSandbox(); defer { box.cleanUp() }
        let file = box.directory.appendingPathComponent("road-clues.json")
        var content = try JSONDecoder().decode(RoadClueContent.self, from: Data(contentsOf: file))
        switch failure {
        case "translation": content.clues[0].texts.removeValue(forKey: "en")
        case "blank": content.clues[0].texts["zh-Hans"] = " \n "
        case "duplicate": content.clues[0].id = content.clues[1].id
        case "tooFew": content.clues = Array(content.clues.prefix(29))
        case "slot": content.clues[0].texts["en"] = "{city}"
        default: content.version = 0
        }
        try JSONEncoder().encode(content).write(to: file)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "roadClues" })
        #expect(throws: (any Error).self) { try CityCatalog.load(directory: box.directory) }
    }
}
