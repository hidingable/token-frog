import Foundation
import Testing
@testable import VoyageCore

private func tripTime(_ day: String = "2026-11-01", _ hour: Int = 0, _ minute: Int = 0) -> Date {
    careCalendar.date(bySettingHour: hour, minute: minute, second: 0,
                      of: DayKey.date(from: day, calendar: careCalendar)!)!
}

private func tripState() -> JourneyState {
    var state = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-11-01", now: tripTime("2026-11-01", 6), catalog: testCatalog)
    var baseline = DayRecord()
    baseline.tokens = 20_000_000_000
    state.days["2026-10-31"] = baseline
    return state
}

private func observe(_ tokens: Int, at now: Date, state: inout JourneyState) {
    state.sync(today: DayUsage(date: DayKey.string(from: now, calendar: careCalendar), observedTokens: tokens),
               now: now, calendar: careCalendar, catalog: testCatalog)
}

@Suite struct TripStateTests {
    @Test func completeCyclePaysReturnThenNextOutboundAndOnlyDrawsAtHome() {
        var state = tripState()
        #expect(state.phase == .outbound && state.route.isEmpty && state.tripCount == 0)
        let destination = state.targetCityId
        let cost = state.legCost
        let returnCost = max(returnTokensPerKm, Int(state.legTo.distanceKm(to: state.homeCoordinate) * Double(returnTokensPerKm)))
        let extra = returnCost + 10_000_000
        observe(cost + extra, at: tripTime("2026-11-01", 7), state: &state)
        #expect(state.phase == .staying && state.phaseSince == tripTime("2026-11-01", 7))
        #expect(state.route == [destination] && state.targetCityId == destination)
        #expect(state.travelFund == extra && state.travelFundKm == Double(extra) / Double(outboundTokensPerKm))
        #expect(state.totalKm == Double(cost) / Double(outboundTokensPerKm))
        let saved = state
        observe(cost + extra, at: tripTime("2026-11-01", 13), state: &state)
        #expect(state.phase == .home && state.phaseSince == tripTime("2026-11-01", 13))
        #expect(state.tripCount == 1 && state.currentCityId == state.homeCityId && state.route == saved.route)
        #expect(state.travelFund == 10_000_000 && state.legFrom == state.homeCoordinate)
        #expect(abs(state.totalKm - (Double(cost) / Double(outboundTokensPerKm) + Double(returnCost) / Double(returnTokensPerKm))) < 0.000000001)
        let next = state.targetCityId
        observe(cost + extra + 100, at: tripTime("2026-11-01", 14), state: &state)
        #expect(state.phase == .pending && state.legFuel == 100 && state.position == state.homeCoordinate)
        state.departNow(now: tripTime("2026-11-01", 14, 10), calendar: careCalendar, catalog: testCatalog, wishTags: ["coast"])
        #expect(state.phase == .outbound && state.targetCityId == next && state.legFuel == 10_000_100 && state.travelFund == 0)
    }

    @Test func pendingAutoDepartureAndExplicitDepartureUseAccumulatedTokens() {
        var state = tripState()
        state.phase = .home
        observe(10, at: tripTime("2026-11-01", 8), state: &state)
        observe(30, at: tripTime("2026-11-01", 8, 29), state: &state)
        #expect(state.phase == .pending && state.legFuel == 30 && state.totalKm == 0)
        var manual = state
        manual.departNow(now: tripTime("2026-11-01", 8, 29), calendar: careCalendar, catalog: testCatalog)
        #expect(manual.phase == .outbound && manual.legFuel == 30 && manual.phaseSince == tripTime("2026-11-01", 8, 29))
        observe(30, at: tripTime("2026-11-01", 9), state: &state)
        #expect(state.phase == .outbound && state.phaseSince == tripTime("2026-11-01", 8, 30) && state.legFuel == 30)
        #expect(state.totalKm == 0.00003)
    }

    @Test func pendingCanHoldMoreThanALegWithoutNegativeDistances() {
        var state = tripState()
        state.phase = .home
        let cost = state.legCost
        observe(cost * 2, at: tripTime("2026-11-01", 8), state: &state)
        #expect(state.phase == .pending && state.legFuel == cost * 2)
        #expect(state.remainingFuel == cost && state.remainingKm == state.legKm && state.legProgress == 0)
        #expect(state.position == state.homeCoordinate && state.totalKm == 0)
        state.departNow(now: tripTime("2026-11-01", 8, 1), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .staying && state.legFuel == cost && state.route.count == 1)
    }

    @Test func shrinkingFundCapConvertsExistingExcessOnlyToMileage() {
        var state = tripState()
        state.phase = .home
        state.travelFund = 20_000_000
        state.days = [:]
        for day in 1...14 {
            var record = DayRecord(); record.tokens = outboundTokensPerKm
            state.days[String(format: "2026-10-%02d", day)] = record
        }
        observe(0, at: tripTime("2026-11-01", 8), state: &state)
        #expect(state.phase == .home && state.travelFund == outboundTokensPerKm && state.totalKm == 19)
    }

    @Test func stayCountsClosedTimeAndReturningUsesItsOwnRate() throws {
        var state = tripState()
        let cost = state.legCost
        observe(cost, at: tripTime("2026-11-01", 9), state: &state)
        state = try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state))
        observe(cost + returnTokensPerKm, at: tripTime("2026-11-01", 16), state: &state)
        #expect(state.phase == .returning && state.phaseSince == tripTime("2026-11-01", 15))
        #expect(state.legFuel == returnTokensPerKm && state.tokensPerKm == returnTokensPerKm)
        #expect(state.totalKm == Double(cost) / Double(outboundTokensPerKm) + 1)
        #expect(state.remainingKm == Double(state.remainingFuel) / Double(returnTokensPerKm))
        #expect(state.legKm == Double(state.legCost) / Double(returnTokensPerKm))
    }

    @Test func fundCapUsesFourteenCompletedActiveDaysAndOverflowOnlyAddsKm() {
        var state = tripState()
        state.days = [:]
        for day in 1...20 {
            var record = DayRecord(); record.tokens = day * outboundTokensPerKm
            state.days[String(format: "2026-10-%02d", day)] = record
        }
        let cost = state.legCost
        observe(cost + 20_000_000, at: tripTime("2026-11-01", 7), state: &state)
        #expect(state.travelFund == 14_000_000)
        #expect(state.totalKm == Double(cost) / Double(outboundTokensPerKm) + 6)
        observe(cost + 25_000_000, at: tripTime("2026-11-01", 8), state: &state)
        #expect(state.travelFund == 14_000_000 && state.totalKm == Double(cost) / Double(outboundTokensPerKm) + 11)
        #expect(state.phaseSince == tripTime("2026-11-01", 7))
    }

    @Test func fundCapRetainsIntegerPrecisionBeyondDoubleWholeNumbers() {
        var state = tripState()
        let cap = 9_007_199_254_740_993
        state.days["2026-10-31"]?.tokens = cap
        state.phase = .staying
        state.legFuel = state.legCost
        observe(cap + 1, at: tripTime("2026-11-01", 7), state: &state)
        #expect(state.travelFund == cap && state.totalKm == 0.000001)
    }

    @Test func fullIdleDayAfterStayUsesNightMailWithoutSpendingFund() {
        var state = tripState()
        state.phase = .returning
        state.phaseSince = tripTime("2026-10-31", 20)
        state.travelFund = 777
        let before = state.totalKm
        state.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01")],
                   now: tripTime("2026-11-02", 8), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .home && state.tripCount == 1 && state.travelFund == 777 && state.totalKm == before)
        // A zero-usage partial day containing the end of the stay does not qualify.
        var partial = tripState()
        partial.phase = .staying
        partial.phaseSince = tripTime("2026-11-01", 1)
        partial.sync(today: DayUsage(date: "2026-11-02"), finalized: [DayUsage(date: "2026-11-01")],
                     now: tripTime("2026-11-02", 8), calendar: careCalendar, catalog: testCatalog)
        #expect(partial.phase == .returning && partial.tripCount == 0)
    }

    @Test func hourlyCatchUpAllocatesOnlyResidualAfterObservationAndIsReproducible() throws {
        var state = tripState()
        let cost = state.legCost
        let credited = cost / 4
        observe(credited, at: tripTime("2026-11-01", 8), state: &state)
        let initial = state
        let residual = cost - credited
        let hours = [HourUsage(date: "2026-11-01", hour: 7, tokens: .init(input: 999_999)),
                     HourUsage(date: "2026-11-01", hour: 9, tokens: .init(input: 1)),
                     HourUsage(date: "2026-11-01", hour: 10, tokens: .init(cacheRead: 2))]
        state.sync(today: DayUsage(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                   hourly: ["2026-11-01": hours], now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .returning && state.phaseSince == tripTime("2026-11-01", 17))
        #expect(state.days["2026-11-01"]?.arrivals.count == 1 && state.days["2026-11-01"]?.tokens == cost)
        #expect(state.totalKm == Double(cost) / Double(outboundTokensPerKm))
        var live = initial
        observe(credited + residual / 3, at: tripTime("2026-11-01", 10), state: &live)
        observe(cost, at: tripTime("2026-11-01", 11), state: &live)
        live.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                  now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(live == state)
        let saved = state
        state.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                   hourly: ["2026-11-01": hours], now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(saved == state)
        #expect(try JSONDecoder().decode(JourneyState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test func finalHourStaysInsideItsNaturalDayWhileKeepingHourEndTiming() {
        var state = tripState()
        let cost = state.legCost
        state.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                   hourly: ["2026-11-01": [.init(date: "2026-11-01", hour: 23, tokens: .init(input: cost))]],
                   now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phaseSince == tripTime("2026-11-02", 0).addingTimeInterval(-1))
        #expect(state.letters.last?.arrivals == state.route && state.letters.last?.transitTargetId == nil)
        #expect(state.days["2026-11-02"]?.arrivals.isEmpty != false)
    }

    @Test(arguments: [false, true]) func absentOrEmptyHourlyDataFallsBackTo2359(empty: Bool) {
        var state = tripState()
        let cost = state.legCost
        state.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                   hourly: empty ? ["2026-11-01": []] : [:], now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .staying && state.phaseSince == tripTime("2026-11-01", 23, 59))
    }

    @Test func pendingArrivalOnAnIdleDayKeepsMailCountAndStillEnablesRevisits() {
        var state = tripState()
        state.phase = .home
        let city = state.targetCityId
        let tokens = state.legCost * 2
        observe(tokens, at: tripTime("2026-11-01", 23, 50), state: &state)
        state.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: tokens)],
                   now: tripTime("2026-11-02", 1), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .staying && state.phaseSince == tripTime("2026-11-02", 0, 20))
        #expect(state.days["2026-11-02"]?.arrivals == [city] && state.route == [city])
        state.sync(today: .init(date: "2026-11-03"), finalized: [.init(date: "2026-11-02")],
                   now: tripTime("2026-11-03", 0), calendar: careCalendar, catalog: testCatalog)
        #expect(state.letters.filter { $0.kind == .daily }.count == 1)
        var care = engineState().1
        care.trailClues[city] = 3
        var revisit = engineStory("idle-day-revisit", kind: "revisit", city: city)
        revisit.replies = []
        state.letters.append(engineLetter(2, arrivals: [city], date: "2026-11-03", cityId: city))
        CareEngine.process(journey: &state, care: &care, stories: engineStories([revisit]), catalog: testCatalog)
        #expect(state.letters.last?.isRevisit == true && care.toldRevisitStoryIds == [revisit.id])
    }

    @Test func stayAcrossMidnightOnlyUsesArrivalDayForItsCityAndDropsUseLastStay() throws {
        var state = tripState()
        let cost = state.legCost
        let city = state.targetCityId
        observe(cost, at: tripTime("2026-11-01", 22), state: &state)
        state.sync(today: .init(date: "2026-11-02", observedTokens: 1), finalized: [.init(date: "2026-11-01", observedTokens: cost)],
                   now: tripTime("2026-11-02", 1), calendar: careCalendar, catalog: testCatalog)
        #expect(state.phase == .staying)
        state.sync(today: .init(date: "2026-11-03"), finalized: [.init(date: "2026-11-02", observedTokens: 1)],
                   now: tripTime("2026-11-03", 0), calendar: careCalendar, catalog: testCatalog)
        let daily = state.letters.filter { $0.kind == .daily }
        #expect(daily.count == 2 && daily[0].arrivals == [city] && daily[0].transitTargetId == nil)
        #expect(daily[1].arrivals.isEmpty && daily[1].transitTargetId != nil && daily[1].cityId == city)
        var care = engineState().1
        CareEngine.process(journey: &state, care: &care, stories: engineStories(), catalog: testCatalog)
        #expect(state.letters.last?.storyId == "generic.transit")
        #expect(state.letters.last?.arrivalStories.isEmpty == true)
        let rewards = try #require(state.letters.last?.rewards)
        if let duplicate = rewards.duplicateClueCityId {
            #expect(duplicate == city)
        } else {
            let drop = try #require(rewards.itemIds.first)
            #expect(testCatalog.items.find(drop)?.cityId == city)
        }
    }

    @Test func twoStaysMakeTwoStorySegmentsButOneLetterAndOneReward() {
        var state = tripState()
        let first = state.targetCityId
        var total = state.legCost
        observe(total, at: tripTime("2026-11-01", 6), state: &state)
        total += max(returnTokensPerKm, Int(state.legTo.distanceKm(to: state.homeCoordinate) * Double(returnTokensPerKm))) + 1
        observe(total, at: tripTime("2026-11-01", 12), state: &state)
        #expect(state.phase == .pending)
        let second = state.targetCityId
        state.departNow(now: tripTime("2026-11-01", 12), calendar: careCalendar, catalog: testCatalog)
        total += state.remainingFuel
        observe(total, at: tripTime("2026-11-01", 13), state: &state)
        state.sync(today: .init(date: "2026-11-02"), finalized: [.init(date: "2026-11-01", observedTokens: total)],
                   now: tripTime("2026-11-02", 0), calendar: careCalendar, catalog: testCatalog)
        var care = engineState().1
        CareEngine.process(journey: &state, care: &care, stories: engineStories(), catalog: testCatalog)
        let daily = state.letters.filter { $0.kind == .daily }
        #expect(daily.count == 1 && daily[0].arrivals == [first, second])
        #expect(daily[0].arrivalStories.map(\.cityId) == [first, second])
        #expect(daily[0].texts?["en"]?.contains(testCatalog.city(first).names["en"]!) == true)
        #expect(daily[0].texts?["en"]?.contains(testCatalog.city(second).names["en"]!) == true)
        #expect(care.processedLetterIds == [daily[0].id] && care.pity <= 1)
        var single = state
        single.letters = [engineLetter(daily[0].id, arrivals: [second], cityId: second)]
        var singleCare = engineState().1
        CareEngine.process(journey: &single, care: &singleCare, stories: engineStories(), catalog: testCatalog)
        #expect(single.letters[0].rewards == daily[0].rewards && singleCare.pity == care.pity)
        var recoveredCare = engineState().1
        let saved = state
        CareEngine.process(journey: &state, care: &recoveredCare, stories: .init(stories: []), catalog: testCatalog)
        #expect(state == saved && recoveredCare == care)
        let footprints = Footprints(journey: state, care: care, catalog: testCatalog, now: .distantFuture)
        #expect(footprints.mostVisited.count == 1 && footprints.mostVisited.cityId == second)
    }
}
