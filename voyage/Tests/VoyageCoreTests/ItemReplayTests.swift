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
