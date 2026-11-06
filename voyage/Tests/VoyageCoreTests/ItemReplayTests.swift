import Foundation
import Testing
@testable import VoyageCore

@Suite struct ItemReplayTests {
    @Test(arguments: Array(UInt32(0)..<32))
    func realContentKeepsDailyHabitsDropsCarryTriggersAndFulfillmentTimingWhenUsageDoubles(seed: UInt32) {
        var (normal, care) = engineState(seed: seed)
        var (doubled, doubledCare) = engineState(seed: seed)
        let bag = ["sketchbook", "note-slip", "raincoat", "old-camera", "lunchbox"]
        care.bag.owned = bag
        doubledCare.bag.owned = bag
        for day in 0..<60 {
            let date = normal.openDate
            let next = DayKey.next(date, calendar: careCalendar)
            let amount = day % 9 == 8 ? 0 : (day % 5 + 1) * 3_000_000
            normal.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount, byClient: ["codex": amount])], calendar: careCalendar, catalog: testCatalog)
            doubled.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount * 2, byClient: ["codex": amount * 2])], calendar: careCalendar, catalog: testCatalog)
            let chosen: String? = day % 6 == 5 ? nil : bag[day % 5]
            care.bag.todayItem = chosen
            doubledCare.bag.todayItem = chosen
            CareEngine.process(journey: &normal, care: &care, stories: testCatalog.stories, catalog: testCatalog)
            CareEngine.process(journey: &doubled, care: &doubledCare, stories: testCatalog.stories, catalog: testCatalog)
            // Reading on the same five days each week is a policy independent of usage.
            if day % 7 < 5 {
                normal.markRead(normal.letters.last!.id)
                doubled.markRead(doubled.letters.last!.id)
                CareEngine.markCompanion(date: next, care: &care, calendar: careCalendar)
                CareEngine.markCompanion(date: next, care: &doubledCare, calendar: careCalendar)
            }
            #expect(care.companionDays == doubledCare.companionDays)
            #expect(Stage.current(companionDays: care.companionDays.count) == Stage.current(companionDays: doubledCare.companionDays.count))
            #expect(care.weekly == doubledCare.weekly)
            // Leave some boxes unopened across week boundaries; both replays open on the same day.
            if day % 10 == 9 {
                for id in care.weekly.boxes {
                    let reward = CareEngine.openBox(id: id, care: &care, library: testCatalog.items, date: next, journey: normal, calendar: careCalendar)
                    let otherReward = CareEngine.openBox(id: id, care: &doubledCare, library: testCatalog.items, date: next, journey: doubled, calendar: careCalendar)
                    #expect(reward == otherReward)
                }
            }
            #expect(care.boxesOpened == doubledCare.boxesOpened && care.boxItemIndex == doubledCare.boxItemIndex)
            #expect(care.souvenirs.filter { $0.boxId != nil } == doubledCare.souvenirs.filter { $0.boxId != nil })
            #expect(care.weekly.boxes == doubledCare.weekly.boxes)
            let letter = normal.letters.last!
            let other = doubled.letters.last!
            #expect(letter.id == other.id && letter.date == other.date)
            #expect(letter.carriedItem == other.carriedItem && letter.itemTriggered == other.itemTriggered)
            #expect(letter.rewards.dropRarity == other.rewards.dropRarity)
            #expect((letter.fulfilledReplyId != nil) == (other.fulfilledReplyId != nil))
            #expect(care.habits == doubledCare.habits && care.pity == doubledCare.pity)
            if letter.kind == .daily && letter.id % 4 == 1 {
                // Encourage the same habit, even if arrival/transit gave different response IDs.
                let habit = letter.id % 8 == 1 ? "talkative" : "observant"
                let reply = letter.replyOptions.first { $0.habit == habit }!
                let otherReply = other.replyOptions.first { $0.habit == habit }!
                CareEngine.reply(letterId: letter.id, replyId: reply.id, date: next, journey: &normal, care: &care)
                CareEngine.reply(letterId: other.id, replyId: otherReply.id, date: next, journey: &doubled, care: &doubledCare)
                #expect(care.habits == doubledCare.habits)
            }
        }
        #expect(normal.letters.map(\.date) == doubled.letters.map(\.date))
        #expect(normal.letters.count == doubled.letters.count)
        #expect(doubled.totalFuel == normal.totalFuel * 2)
    }

    @Test(arguments: [UInt32(0), 42, 314])
    func doubledUsageAlsoPreservesWeeklyRewardsStartingWithOnlyTheInitialBag(seed: UInt32) {
        var (normal, care) = engineState(seed: seed)
        var (doubled, doubledCare) = engineState(seed: seed)
        var opened: [BoxResult] = []
        for day in 0..<90 {
            let date = normal.openDate
            let next = DayKey.next(date, calendar: careCalendar)
            let amount = day % 9 == 8 ? 0 : (day % 5 + 1) * 3_000_000
            normal.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount)], calendar: careCalendar, catalog: testCatalog)
            doubled.sync(today: DayUsage(date: next), finalized: [DayUsage(date: date, fuel: amount * 2)], calendar: careCalendar, catalog: testCatalog)
            let chosen = ["sketchbook", "note-slip", "raincoat"][day % 3]
            care.bag.todayItem = chosen
            doubledCare.bag.todayItem = chosen
            CareEngine.process(journey: &normal, care: &care, stories: testCatalog.stories, catalog: testCatalog)
            CareEngine.process(journey: &doubled, care: &doubledCare, stories: testCatalog.stories, catalog: testCatalog)
            if day % 7 < 5 {
                normal.markRead(normal.letters.last!.id)
                doubled.markRead(doubled.letters.last!.id)
                CareEngine.markCompanion(date: next, care: &care, calendar: careCalendar)
                CareEngine.markCompanion(date: next, care: &doubledCare, calendar: careCalendar)
            }
            #expect(care.companionDays == doubledCare.companionDays)
            #expect(Stage.current(companionDays: care.companionDays.count) == Stage.current(companionDays: doubledCare.companionDays.count))
            #expect(care.weekly == doubledCare.weekly)
            if day % 11 == 10 {
                for id in care.weekly.boxes {
                    let result = CareEngine.openBox(id: id, care: &care, library: testCatalog.items, date: next, journey: normal, calendar: careCalendar)
                    let other = CareEngine.openBox(id: id, care: &doubledCare, library: testCatalog.items, date: next, journey: doubled, calendar: careCalendar)
                    #expect(result == other)
                    if let result { opened.append(result) }
                }
            }
            #expect(care.bag.owned == doubledCare.bag.owned)
            #expect(care.weekly.boxes == doubledCare.weekly.boxes)
            #expect(care.souvenirs.filter { $0.boxId != nil } == doubledCare.souvenirs.filter { $0.boxId != nil })
            #expect(care.boxesOpened == doubledCare.boxesOpened && care.boxItemIndex == doubledCare.boxItemIndex)
        }
        #expect(opened.contains(.item(id: "old-camera", kind: "bag")))
        #expect(opened.contains(.item(id: "lunchbox", kind: "bag")))
        #expect(doubled.totalFuel == normal.totalFuel * 2)
    }

    @Test func catchUpAndOneLetterAtATimeGiveIdenticalResultsWithUnchosenBags() {
        var (batch, batchCare) = engineState(seed: 314)
        var (daily, dailyCare) = engineState(seed: 314)
        let letters = (1...30).map { id in engineLetter(id, arrivals: id % 3 == 0 ? [] : ["xian"]) }
        batch.letters += letters
        CareEngine.process(journey: &batch, care: &batchCare, stories: testCatalog.stories, catalog: testCatalog)
        for letter in letters {
            daily.letters.append(letter)
            CareEngine.process(journey: &daily, care: &dailyCare, stories: testCatalog.stories, catalog: testCatalog)
        }
        #expect(batch == daily && batchCare == dailyCare)
        #expect(batchCare.souvenirs.count + batchCare.trailClues.values.reduce(0, +) == letters.count)
    }
}
