import CryptoKit
import Foundation
import Testing
@testable import VoyageCore

private func mailTime(_ key: String, _ hour: Int = 12) -> Date {
    careCalendar.date(bySettingHour: hour, minute: 0, second: 0,
                      of: DayKey.date(from: key, calendar: careCalendar)!)!
}

@Suite struct JourneyGateTests {
    @Test func openGatePreservesExistingSaveBytes() throws {
        var (journey, care) = engineState(seed: 42)
        for day in 1...15 {
            let date = String(format: "2026-11-%02d", day)
            let yesterday = journey.openDate
            journey.sync(today: DayUsage(date: date, fuel: day.isMultiple(of: 2) ? 100 : 0),
                         finalized: [DayUsage(date: yesterday, fuel: journey.fuel(on: yesterday))],
                         now: mailTime(date), calendar: careCalendar, catalog: testCatalog)
            CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories,
                               catalog: testCatalog, calendar: careCalendar)
            if [1, 2, 5, 9, 13, 15].contains(day) {
                CareEngine.open(at: mailTime(date), journey: &journey, care: &care,
                                catalog: testCatalog, calendar: careCalendar)
            }
            CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar)
            CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(journey) + encoder.encode(care)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "54644c815020c65d18c48e07833627194c8ee51fdc67d72a1ed4eb96eaf1e28a")
    }

    @Test func decisionsAreIndependentAndUseTheSuppliedInstant() {
        let cutoff = mailTime("2026-11-03")
        let gate = JourneyGate(allowsDeparture: { $0 < cutoff }, allowsNewMail: { $0 >= cutoff })
        #expect(gate.allowsDeparture(at: cutoff.addingTimeInterval(-1)))
        #expect(!gate.allowsNewMail(at: cutoff.addingTimeInterval(-1)))
        #expect(!gate.allowsDeparture(at: cutoff) && gate.allowsNewMail(at: cutoff))
        let shared = JourneyGate { $0 >= cutoff }
        #expect(!shared.allowsDeparture(at: cutoff.addingTimeInterval(-1)))
        #expect(!shared.allowsNewMail(at: cutoff.addingTimeInterval(-1)))
        #expect(shared.allowsDeparture(at: cutoff) && shared.allowsNewMail(at: cutoff))
    }

    @Test(arguments: [0, 100])
    func closedAtHomeProducesNoMailOrCareProgress(tokens: Int) {
        var (journey, care) = engineState()
        journey.phase = .home
        let closed = JourneyGate { _ in false }
        process(&journey, &care, gate: closed)
        care.pity = 8
        care.pendingPromises = [.init(replyId: "ask-next-time", letterId: 0, attempts: 2)]
        care.bag.todayItem = "sketchbook"
        care.companionDays = previousCompanionDays()
        let before = care
        for day in 1...8 {
            let date = String(format: "2026-11-%02d", day)
            let previous = journey.openDate
            journey.sync(today: .init(date: date, observedTokens: tokens),
                         finalized: [.init(date: previous, observedTokens: tokens)], now: mailTime(date),
                         calendar: careCalendar, catalog: testCatalog, gate: closed)
            CareEngine.open(at: mailTime(date), journey: &journey, care: &care,
                            catalog: testCatalog, calendar: careCalendar, gate: closed)
            CareEngine.markCompanion(date: date, care: &care, calendar: careCalendar, gate: closed)
            process(&journey, &care, gate: closed)
            CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar, gate: closed)
        }
        #expect(journey.letters.map(\.kind) == [.logbook])
        #expect(journey.openDate == "2026-11-08" && journey.lastWeeklyMailSunday == "2026-11-08")
        #expect(care == before)
    }

    @Test(arguments: [JourneyState.Phase.pending, .outbound])
    func tripKeepsArrivalAndHomecomingMailAndRewardsThenStops(initialPhase: JourneyState.Phase) throws {
        func run(mailAllowed: Bool) -> (JourneyState, CareState) {
            var (journey, care) = engineState(seed: 42)
            journey.phase = initialPhase
            journey.phaseSince = mailTime("2026-11-01", 6)
            let cost = journey.legCost
            let gate = JourneyGate(allowsDeparture: { _ in false }, allowsNewMail: { _ in mailAllowed })
            journey.sync(today: .init(date: "2026-11-01", observedTokens: 100), now: mailTime("2026-11-01"),
                         calendar: careCalendar, catalog: testCatalog, gate: gate)
            for (day, final) in [(2, 100), (3, cost - 100), (4, 0), (5, 0)] {
                let previous = journey.openDate
                journey.days[previous, default: DayRecord()].mainWindowOpened = true
                let date = String(format: "2026-11-%02d", day)
                journey.sync(today: .init(date: date), finalized: [.init(date: previous, observedTokens: final)],
                             now: mailTime(date), calendar: careCalendar, catalog: testCatalog, gate: gate)
                process(&journey, &care, gate: gate)
            }
            return (journey, care)
        }
        var (journey, care) = run(mailAllowed: false)
        let (openJourney, openCare) = run(mailAllowed: true)
        #expect(journey.phase == .home && journey.tripCount == 1)
        #expect(journey.letters == openJourney.letters && care == openCare)
        #expect(journey.letters.filter { $0.kind == .daily }.map(\.date) == ["2026-11-01", "2026-11-02"])
        #expect(journey.letters.first { $0.date == "2026-11-02" }?.arrivals.isEmpty == false)
        #expect(journey.letters.filter { $0.kind == .postcard }.map(\.date) == ["2026-11-03", "2026-11-04"])
        #expect(DayKey.string(from: try #require(journey.homecoming).returnedAt, calendar: careCalendar) == "2026-11-04")
        #expect(journey.letters.filter { $0.id > 0 }.allSatisfy { !$0.rewards.itemIds.isEmpty })
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        let before = care
        journey.days["2026-11-05", default: DayRecord()].mainWindowOpened = true
        journey.sync(today: .init(date: "2026-11-06"), finalized: [.init(date: "2026-11-05", observedTokens: 100)],
                     now: mailTime("2026-11-06"), calendar: careCalendar, catalog: testCatalog, gate: JourneyGate { _ in false })
        process(&journey, &care, gate: JourneyGate { _ in false })
        #expect(journey.letters == openJourney.letters && care == before)
    }

    @Test(arguments: [JourneyState.Phase.pending, .outbound, .staying, .returning])
    func zeroUsageTripDaysRetainTheirExceptionAcrossSaving(phase: JourneyState.Phase) throws {
        var (journey, care) = engineState()
        journey.phase = phase
        journey.phaseSince = mailTime("2026-11-01", 6)
        if phase == .staying || phase == .returning {
            journey.currentCityId = journey.targetCityId
            journey.route = [journey.targetCityId]
        }
        let closed = JourneyGate { _ in false }
        CareEngine.open(at: mailTime("2026-11-01"), journey: &journey, care: &care,
                        catalog: testCatalog, calendar: careCalendar, gate: closed)
        journey.sync(today: .init(date: "2026-11-02"), now: mailTime("2026-11-02"),
                     calendar: careCalendar, catalog: testCatalog, gate: closed)
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        process(&journey, &care, gate: closed)
        #expect(journey.days["2026-11-01"]?.tripNumber == 1)
        #expect(journey.letters.last?.kind == .postcard && journey.letters.last?.date == "2026-11-01")
        #expect(journey.letters.last?.rewards.itemIds.isEmpty == false)
        #expect(journey.allowsNewMail(on: "2026-11-01", gate: closed, calendar: careCalendar))
    }

    @Test func backfillUsesEachDaysOwnEndForDailyAndPostcardMail() {
        var (journey, care) = engineState()
        journey.phase = .home
        for day in [3, 4] { journey.days[String(format: "2026-11-%02d", day), default: DayRecord()].mainWindowOpened = true }
        let allowed = [DayKey.end(of: "2026-11-02", calendar: careCalendar), DayKey.end(of: "2026-11-04", calendar: careCalendar)]
        let gate = JourneyGate(allowsDeparture: { _ in false }, allowsNewMail: { allowed.contains($0) })
        journey.sync(today: .init(date: "2026-11-06"),
                     finalized: (1...5).map { .init(date: String(format: "2026-11-%02d", $0), observedTokens: [3, 4].contains($0) ? 0 : 100) },
                     now: mailTime("2026-11-06"), calendar: careCalendar, catalog: testCatalog, gate: gate)
        process(&journey, &care, gate: gate)
        #expect(journey.letters.filter { $0.id > 0 }.map(\.date) == ["2026-11-02", "2026-11-04"])
        #expect(journey.letters.filter { $0.id > 0 }.map(\.kind) == [.daily, .postcard])
    }

    @Test func reopeningResumesPityAndPromisesWithoutSkippedLetters() throws {
        var (journey, care) = engineState()
        journey.phase = .home
        let closes = mailTime("2026-11-02", 0), reopens = mailTime("2026-11-05", 0)
        let gate = JourneyGate(allowsDeparture: { _ in false }, allowsNewMail: { $0 < closes || $0 >= reopens })
        journey.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: 100)],
                     now: mailTime("2026-11-02"), calendar: careCalendar, catalog: testCatalog, gate: gate)
        process(&journey, &care, gate: gate)
        let origin = try #require(journey.letters.last)
        let reply = try #require(origin.replyOptions.first)
        #expect(CareEngine.reply(letterId: origin.id, replyId: reply.id, date: "2026-11-02", journey: &journey, care: &care))
        care.pity = 8
        care.bag.todayItem = "sketchbook"
        let before = care
        journey.days["2026-11-03", default: DayRecord()].mainWindowOpened = true
        journey.sync(today: .init(date: "2026-11-05"), finalized: [.init(date: "2026-11-02", observedTokens: 100),
                     .init(date: "2026-11-04", observedTokens: 100)], now: mailTime("2026-11-05"),
                     calendar: careCalendar, catalog: testCatalog, gate: gate)
        process(&journey, &care, gate: gate)
        #expect(care == before)
        journey.sync(today: .init(date: "2026-11-06"), finalized: [.init(date: "2026-11-05", observedTokens: 100)],
                     now: mailTime("2026-11-06"), calendar: careCalendar, catalog: testCatalog, gate: gate)
        process(&journey, &care, gate: gate)
        #expect(journey.letters.filter { $0.kind == .daily }.map(\.date) == ["2026-11-01", "2026-11-05"])
        #expect(journey.letters.last?.fulfilledReplyId == reply.id && care.pendingPromises.isEmpty)
        #expect(journey.letters.last?.rewards.dropRarity == "rare" && care.pity == 0)
        #expect(care.memories.last?.date == "2026-11-05")
    }

    @Test func closedReadsFreezeWeeklyStampsButExistingBoxesStillOpen() {
        let (journey, initialCare) = engineState()
        var care = initialCare
        let closes = mailTime("2026-11-05", 0), reopens = mailTime("2026-11-07", 0)
        let gate = JourneyGate { $0 < closes || $0 >= reopens }
        for day in 2...6 {
            CareEngine.markCompanion(date: String(format: "2026-11-%02d", day), care: &care, calendar: careCalendar, gate: gate)
        }
        #expect(care.companionDays.count == 3 && care.weekly.stamps.count == 3 && care.weekly.boxes.isEmpty)
        CareEngine.markCompanion(date: mailTime("2026-11-07"), care: &care, calendar: careCalendar, gate: gate)
        #expect(care.weekly.boxes == ["2026-11-02#4"])
        let closed = JourneyGate { _ in false }
        CareEngine.markCompanion(date: mailTime("2026-11-08"), care: &care, calendar: careCalendar, gate: closed)
        #expect(care.weekly.stamps.count == 4 && care.weekly.boxes.count == 1)
        #expect(CareEngine.openBox(id: "2026-11-02#4", care: &care, library: testCatalog.items,
                                  date: "2026-11-08", journey: journey, calendar: careCalendar) != nil)
        CareEngine.markCompanion(date: "2026-11-09", care: &care, calendar: careCalendar, gate: gate)
        #expect(care.weekly.stamps == ["2026-11-09"] && care.companionDays.count == 5)
        #expect(care.boxesOpened == 1 && care.weekly.boxes.isEmpty)
    }

    @Test func identityWaitsForFirstAllowedDayAndSavedSettlementStillReplaysWhileClosed() throws {
        var (journey, care) = engineState()
        journey.phase = .home
        care.companionDays = previousCompanionDays()
        let closed = JourneyGate { _ in false }
        process(&journey, &care, gate: closed)
        #expect(care.identity == nil && care.settledIdentityStages == [])
        journey.openDate = "2026-11-03"
        process(&journey, &care, gate: closed)
        #expect(journey.letters.map(\.kind) == [.logbook])
        let before = care
        process(&journey, &care)
        let letter = try #require(journey.letters.last)
        #expect(letter.kind == .identity && letter.date == "2026-11-03")
        var replay = before
        process(&journey, &replay, gate: closed)
        #expect(replay == care && journey.letters.filter { $0.kind == .identity }.count == 1)
    }

    @Test func weeklyMailJudgesSundayAndNeverRetriesAClosedSunday() {
        var (journey, _) = engineState()
        journey.phase = .home
        journey.openDate = "2026-11-09"
        journey.days["2026-11-07", default: DayRecord()].mainWindowOpened = true
        let sundayEnd = DayKey.end(of: "2026-11-08", calendar: careCalendar)
        let gate = JourneyGate { $0 > sundayEnd }
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar, gate: gate)
        #expect(journey.lastWeeklyMailSunday == "2026-11-08" && journey.letters.map(\.kind) == [.logbook])
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar)
        #expect(journey.letters.map(\.kind) == [.logbook])
        journey.openDate = "2026-11-15"
        journey.days["2026-11-14", default: DayRecord()].mainWindowOpened = true
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar, gate: gate)
        #expect(journey.letters.filter { $0.kind == .weekly }.map(\.date) == ["2026-11-15"])
    }

    @Test func reunionExcludesClosedDaysFromAbsenceAndUsesTheOpenInstant() {
        var (journey, care) = engineState()
        journey.phase = .home
        journey.lastOpenedDate = "2026-11-01"
        let closes = mailTime("2026-11-02", 0), reopens = mailTime("2026-11-06", 0)
        let gate = JourneyGate { $0 < closes || $0 >= reopens }
        CareEngine.open(at: mailTime("2026-11-04"), journey: &journey, care: &care,
                        catalog: testCatalog, calendar: careCalendar, gate: gate)
        CareEngine.open(at: mailTime("2026-11-06"), journey: &journey, care: &care,
                        catalog: testCatalog, calendar: careCalendar, gate: gate)
        #expect(journey.letters.allSatisfy { $0.kind != .reunion })
        let cutoff = mailTime("2026-11-09", 13)
        CareEngine.open(at: mailTime("2026-11-09"), journey: &journey, care: &care,
                        catalog: testCatalog, calendar: careCalendar, gate: JourneyGate { $0 < cutoff })
        #expect(journey.letters.filter { $0.kind == .reunion }.map(\.date) == ["2026-11-09"])
        #expect(journey.letters.last?.deliverAt == mailTime("2026-11-09"))
    }

    @Test func alreadyHappenedEncounterIsDeliveredAfterReturningHomeWhileClosed() {
        var (journey, care) = engineState()
        journey.phase = .home
        let closed = JourneyGate { _ in false }
        process(&journey, &care, gate: closed)
        let before = care
        journey.recordEncounter(.init(cityId: "quanzhou", partner: .init(species: "snail", stage: "juvenile"),
                                      localDate: "2026-11-01", own: .init(species: "pigeon", stage: "teen")))
        journey.sync(today: .init(date: "2026-11-02"), now: mailTime("2026-11-02"),
                     calendar: careCalendar, catalog: testCatalog, gate: closed)
        process(&journey, &care, gate: closed)
        #expect(journey.letters.count == 2 && journey.letters.last?.encounter?.cityId == "quanzhou")
        #expect(care == before)
    }

    @Test func zeroUsageHomecomingBeforeSettlementKeepsSundaysTripProvenance() throws {
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-08",
                                   now: mailTime("2026-11-08", 6), catalog: testCatalog)
        journey.phase = .returning
        journey.currentCityId = journey.targetCityId
        journey.route = [journey.targetCityId]
        journey.travelFund = journey.legCost
        var baseline = DayRecord()
        baseline.tokens = journey.legCost
        journey.days["2026-11-07"] = baseline
        let closed = JourneyGate { _ in false }
        journey.sync(today: .init(date: "2026-11-08"), now: mailTime("2026-11-08"),
                     calendar: careCalendar, catalog: testCatalog, gate: closed)
        #expect(journey.phase == .home && journey.days["2026-11-08"]?.tripNumber == nil)
        journey.days["2026-11-08"]?.mainWindowOpened = true
        journey = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(journey))
        journey.sync(today: .init(date: "2026-11-09"), now: mailTime("2026-11-09"),
                     calendar: careCalendar, catalog: testCatalog, gate: closed)
        #expect(journey.days["2026-11-08"]?.tripNumber == 1)
        #expect(journey.letters.last?.kind == .postcard && journey.letters.last?.date == "2026-11-08")
        // A later trip may replace homecoming; the settled Sunday's exception remains durable.
        journey.homecoming = nil
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar, gate: closed)
        #expect(journey.letters.last?.kind == .weekly && journey.letters.last?.date == "2026-11-08")
    }

    @Test func currentTripAlsoKeepsWeeklyIdentityAndAdventureMail() {
        var (journey, care) = engineState()
        journey.phaseSince = mailTime("2026-11-01", 6)
        journey.openDate = "2026-11-08"
        journey.days["2026-11-07", default: DayRecord()].mainWindowOpened = true
        care.companionDays = previousCompanionDays()
        let closed = JourneyGate { _ in false }
        CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar, gate: closed)
        process(&journey, &care, gate: closed)
        #expect(journey.letters.map(\.kind) == [.logbook, .weekly, .adventure, .identity])
        #expect(care.identity != nil && care.settledIdentityStages == [.traveler])
    }

    @Test func existingDailyRewardsReplayAndRepliesRemainAvailableWhileClosed() throws {
        var (journey, care) = engineState()
        journey.phase = .home
        journey.letters.append(engineLetter(1))
        let before = care
        process(&journey, &care)
        let letters = journey.letters
        let earned = care
        care = before
        let closed = JourneyGate { _ in false }
        process(&journey, &care, gate: closed)
        #expect(care == earned && journey.letters == letters)
        let reply = try #require(journey.letters.last?.replyOptions.first)
        #expect(CareEngine.reply(letterId: 1, replyId: reply.id, date: "2026-11-02", journey: &journey, care: &care))
        #expect(care.pendingPromises.last?.attempts == 0 && care.memories.last?.kind == "reply")
        #expect(care.companionDays.isEmpty && care.weekly.stamps.isEmpty)
    }

    @Test func anOngoingTripKeepsReunionMailWhenTheWindowOpensBeforeCatchUp() {
        var (journey, care) = engineState()
        journey.phaseSince = mailTime("2026-11-01", 6)
        journey.lastOpenedDate = "2026-11-01"
        CareEngine.open(at: mailTime("2026-11-04"), journey: &journey, care: &care,
                        catalog: testCatalog, calendar: careCalendar, gate: JourneyGate { _ in false })
        #expect(journey.openDate == "2026-11-01")
        #expect(journey.letters.last?.kind == .reunion && journey.letters.last?.date == "2026-11-04")
        #expect(journey.letters.last?.rewards.itemIds.isEmpty == false)
    }

    private func process(_ journey: inout JourneyState, _ care: inout CareState, gate: JourneyGate = .open) {
        CareEngine.process(journey: &journey, care: &care, stories: testCatalog.stories,
                           catalog: testCatalog, calendar: careCalendar, gate: gate)
    }

    private func previousCompanionDays() -> [String] {
        let first = DayKey.date(from: "2026-09-01", calendar: careCalendar)!
        return (0..<60).map { DayKey.string(from: careCalendar.date(byAdding: .day, value: $0, to: first)!, calendar: careCalendar) }
    }
}
