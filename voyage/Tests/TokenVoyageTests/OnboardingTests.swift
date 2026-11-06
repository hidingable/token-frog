import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private let onboardingToday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
private let onboardingDate = DayKey.string(from: onboardingToday)
private enum OnboardingReadError: Error { case unavailable }

private actor OnboardingReadProbe {
    private(set) var calls = 0
    private(set) var ranges: [(since: String, until: String)] = []
    let days: [DayDetail]
    let hours: [HourUsage]
    let failure: Bool
    let delay: Duration?

    init(days: [DayDetail] = [], hours: [HourUsage] = [], failure: Bool = false, delay: Duration? = nil) {
        self.days = days
        self.hours = hours
        self.failure = failure
        self.delay = delay
    }

    func read(since: String, until: String) async throws -> (days: [DayDetail], hours: [HourUsage]) {
        calls += 1
        ranges.append((since, until))
        if let delay { try await Task.sleep(for: delay) }
        if failure { throw OnboardingReadError.unavailable }
        return (days, hours)
    }
}

private actor OnboardingQuotaProbe {
    private(set) var calls = 0
    func read() -> [ProviderQuota] { calls += 1; return [] }
}

private final class OnboardingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@MainActor
private struct OnboardingFixture {
    let root: URL
    var directory: URL { root.appendingPathComponent("data") }
    var journeyURL: URL { directory.appendingPathComponent("journey.json") }
    var careURL: URL { directory.appendingPathComponent("care.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func files() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func model(now: Date = onboardingToday, isSnapshot: Bool = false, defaults: UserDefaults = OnboardingDefaults(),
               reader: OnboardingReadProbe = OnboardingReadProbe(), quota: OnboardingQuotaProbe = OnboardingQuotaProbe()) -> AppModel {
        AppModel(isSnapshot: isSnapshot, defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { now }, onboardingSeed: 42,
                 onboardingReader: { since, until in try await reader.read(since: since, until: until) },
                 quotaReader: { await quota.read() }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    }

    func prepare(journey: Bool, care: Bool) throws {
        let store = SaveStore(directory: directory, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        if journey {
            var state = JourneyState(seed: 7, startCityId: "shanghai", pet: .snail, date: onboardingDate, now: onboardingToday, catalog: localizationCatalog)
            state.letters[0].kind = .departure
            try store.save(state)
        }
        if care { try store.save(CareState(petName: "My Shelly", species: .snail, hatchedAt: onboardingDate)) }
    }
}

@MainActor
private func waitForOnboardingRead(_ flow: OnboardingFlow) async throws {
    for _ in 0..<100 {
        if !flow.isReading { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!flow.isReading, "The injected reader must finish without holding up the flow")
}

@MainActor
private func advanceToHatch(_ flow: OnboardingFlow, language: Language = .en, pet: PetKind = .pigeon) {
    let l10n = L10n(language: language)
    flow.selectEgg(pet)
    flow.advance(l10n: l10n)
    flow.advance(l10n: l10n)
}

@MainActor
private func advanceToDeparture(_ flow: OnboardingFlow, language: Language = .en, pet: PetKind = .pigeon) {
    advanceToHatch(flow, language: language, pet: pet)
    flow.skipHatching()
    flow.advance(l10n: L10n(language: language))
    flow.advance(l10n: L10n(language: language))
}

private func substantialOnboardingHistory() -> [DayDetail] {
    let first = Calendar.current.date(byAdding: .day, value: -29, to: onboardingToday)!
    return (0..<30).map { offset in
        let day = Calendar.current.date(byAdding: .day, value: offset, to: first)!
        return DayDetail(date: DayKey.string(from: day), rows: [
            UsageRow(client: "codex", model: "example", tokens: UsageTotals(input: 900_000_000, cacheRead: 9_000_000_000)),
            UsageRow(client: "claude", model: "example", tokens: UsageTotals(input: 400_000_000)),
        ])
    }
}

@Suite @MainActor struct OnboardingTests {
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func onboardingOnlyAppearsWhenBothSavesAreMissing(hasJourney: Bool, hasCare: Bool) throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        try fixture.prepare(journey: hasJourney, care: hasCare)
        let existingCare = hasCare ? try Data(contentsOf: fixture.careURL) : nil
        let model = fixture.model()
        #expect(!model.isLocked)
        #expect((model.onboarding != nil) == (!hasJourney && !hasCare))
        if !hasJourney && !hasCare {
            #expect(model.state == nil && model.care == nil)
            #expect(try fixture.files().isEmpty)
        } else {
            #expect(model.state?.pet == .snail)
            #expect(model.care?.species == .snail)
            if hasJourney && !hasCare {
                #expect(model.care?.petName == PetKind.snail.displayName)
                #expect(model.care?.processedLetterIds == [0])
            }
            if let existingCare { #expect(try Data(contentsOf: fixture.careURL) == existingCare) }
        }
    }

    @Test func unfinishedFlowNeverWritesAndRelaunchStartsWithUnselectedEggs() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let reader = OnboardingReadProbe()
        var model: AppModel? = fixture.model(reader: reader)
        let flow = try #require(model?.onboarding)
        #expect(flow.step == .eggs && flow.species == nil && !flow.canContinue)
        model?.start()
        model?.start()
        try await waitForOnboardingRead(flow)
        #expect(try fixture.files().isEmpty)
        flow.selectEgg(.suitcase)
        flow.advance(l10n: L10n(language: .en))
        #expect(try fixture.files().isEmpty)
        flow.selectEgg(.letter)
        #expect(flow.species == .suitcase)
        flow.advance(l10n: L10n(language: .en))
        #expect(try fixture.files().isEmpty)
        flow.petName = "Parcel"
        flow.advance(l10n: L10n(language: .en))
        #expect(try fixture.files().isEmpty)
        model = nil
        #expect(try fixture.files().isEmpty)
        let restarted = fixture.model()
        #expect(restarted.onboarding?.step == .eggs)
        #expect(restarted.onboarding?.species == nil)
        #expect(restarted.state == nil && restarted.care == nil)
        let calls = await reader.calls
        #expect(calls == 1)
    }

    @Test func completionPersistsBothSavesAndHistoricalUsageNeverBecomesMileage() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let reader = OnboardingReadProbe(days: substantialOnboardingHistory())
        let model = fixture.model(reader: reader)
        let flow = try #require(model.onboarding)
        model.start()
        try await waitForOnboardingRead(flow)
        #expect(flow.logbook?.topClients == ["codex", "claude"])
        advanceToHatch(flow, pet: .snail)
        flow.petName = "  Shelly Jr\n"
        flow.skipHatching()
        flow.advance(l10n: model.l10n)
        flow.advance(l10n: model.l10n)
        flow.toggleItem("raincoat")
        let firstStation = flow.preview.targetCityId
        #expect(flow.step == .depart)
        #expect(try fixture.files().isEmpty)
        model.navigate(to: .data)
        model.completeOnboarding()
        #expect(model.onboarding == nil && !model.isLocked)
        #expect(model.tab == .home)
        #expect(model.lastScan == nil && model.lastError == nil)
        #expect(try fixture.files() == ["care.json", "journey.json"])
        let journey = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: fixture.journeyURL))
        let care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture.careURL))
        #expect(journey.version == 5 && journey.seed == 42 && journey.pet == .snail)
        #expect(journey.startDate == onboardingDate && journey.openDate == onboardingDate)
        #expect(journey.totalFuel == 0 && journey.legFuel == 0 && journey.days.isEmpty)
        #expect(journey.route == ["shanghai"] && journey.targetCityId == firstStation)
        #expect(journey.letters.count == 1)
        let letter = try #require(journey.letters.first)
        #expect(letter.kind == .logbook && letter.logbook == flow.logbook)
        #expect(letter.read && letter.deliverAt == onboardingToday && letter.enrichmentDone)
        #expect(journey.unreadCount(now: onboardingToday) == 0)
        #expect(care.petName == "Shelly Jr" && care.species == .snail && care.hatchedAt == onboardingDate)
        #expect(care.bag.todayItem == "raincoat")
        #expect(care.companionDays == [onboardingDate] && care.weekly.stamps == [onboardingDate])
        #expect(model.state == journey && model.care == care)
        let calls = await reader.calls
        let ranges = await reader.ranges
        #expect(calls == 1)
        #expect(ranges.first?.since == "2026-10-08" && ranges.first?.until == "2026-11-06")
    }

    @Test func firstStationUsesTheSameSeedAndChosenHomeAsTheWrittenJourney() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let flow = try #require(model.onboarding)
        flow.selectEgg(.letter)
        flow.advance(l10n: L10n(language: .en))
        flow.homeCityId = "beijing"
        flow.advance(l10n: L10n(language: .en))
        flow.advance(l10n: L10n(language: .en))
        flow.advance(l10n: L10n(language: .en))
        let preview = flow.preview
        model.completeOnboarding()
        let saved = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: fixture.journeyURL))
        #expect(saved.targetCityId == preview.targetCityId)
        #expect(saved.legCost == preview.legCost && saved.legFrom == preview.legFrom && saved.legTo == preview.legTo)
        #expect(saved.route == ["beijing"])
        #expect(model.care?.bag.todayItem == nil)
    }

    @Test(arguments: [("", false), (" \n\t ", false), ("abcdefghijkl", true), ("abcdefghijklm", false),
                      (String(repeating: "👨‍👩‍👧‍👦", count: 12), true), (String(repeating: "🐌", count: 13), false), ("  Coo\n", true)])
    func namesAreTrimmedAndLimitedByCharacterCount(name: String, valid: Bool) throws {
        let flow = OnboardingFlow(catalog: localizationCatalog, seed: 42, today: onboardingToday, readUsage: { _, _ in ([], []) })
        advanceToHatch(flow)
        flow.petName = name
        #expect(flow.canContinue == valid)
        #expect((flow.nameProblem == nil) == valid)
        flow.advance(l10n: L10n(language: .en))
        #expect(flow.step == (valid ? .logbook : .hatch))
    }

    @Test(arguments: [Language.zhHans, .en])
    func defaultNamesAreChosenOnceAndSavedAsLiteralStrings(language: Language) throws {
        let expectedEnglish: [PetKind: String] = [.pigeon: "Coo", .snail: "Shelly", .suitcase: "Trunk", .letter: "Note"]
        for pet in PetKind.allCases {
            let fixture = try OnboardingFixture()
            defer { fixture.remove() }
            let model = fixture.model()
            let flow = try #require(model.onboarding)
            advanceToDeparture(flow, language: language, pet: pet)
            let expected = language == .zhHans ? pet.displayName : expectedEnglish[pet]!
            #expect(flow.petName == expected)
            model.completeOnboarding()
            for preference in [LanguagePreference.zhHans, .en] {
                model.languagePreference = preference
                #expect(model.petName == expected)
                let saved = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture.careURL))
                #expect(saved.petName == expected)
            }
        }
    }

    @Test func homeSearchMatchesBothLanguagesWithoutCaseAndExcludesRetiredCities() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let content = fixture.root.appendingPathComponent("Content")
        try FileManager.default.copyItem(at: LocalizationTestFiles.root.appendingPathComponent("Content"), to: content)
        let retiredURL = content.appendingPathComponent("cities/beijing.json")
        var retired = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: retiredURL)) as? [String: Any])
        retired["status"] = "retired"
        try JSONSerialization.data(withJSONObject: retired).write(to: retiredURL)
        let catalog = try CityCatalog.load(directory: content)
        let flow = OnboardingFlow(catalog: catalog, seed: 42, today: onboardingToday, readUsage: { _, _ in ([], []) })
        #expect(flow.homeCityId == "shanghai")
        for language in Language.allCases {
            let l10n = L10n(language: language)
            for query in ["上海", "SHANGHAI", "  shAnGhAi\n"] {
                flow.search = query
                #expect(flow.cities(l10n: l10n).map(\.id) == ["shanghai"])
            }
            for query in ["北京", "BEIJING"] {
                flow.search = query
                #expect(flow.cities(l10n: l10n).isEmpty)
            }
            flow.search = ""
            let cities = flow.cities(l10n: l10n)
            #expect(cities.allSatisfy { $0.status == "active" })
            let expected = catalog.active.sorted { l10n.cityName($0).compare(l10n.cityName($1), locale: l10n.locale) == .orderedAscending }
            #expect(cities.map(\.id) == expected.map(\.id))
        }
    }

    @Test(arguments: [false, true])
    func readFailureAndTimeoutUseWelcomeWithoutBlockingOrRetrying(timeout: Bool) async throws {
        let probe = OnboardingReadProbe(days: substantialOnboardingHistory(), failure: !timeout, delay: timeout ? .seconds(2) : nil)
        let flow = OnboardingFlow(catalog: localizationCatalog, seed: 42, today: onboardingToday,
                                  readTimeout: .milliseconds(1), readUsage: { since, until in try await probe.read(since: since, until: until) })
        flow.startReading()
        flow.startReading()
        try await waitForOnboardingRead(flow)
        #expect(!flow.isReading && flow.logbook == nil)
        advanceToDeparture(flow)
        #expect(flow.step == .depart)
        let saves = try #require(flow.saves(now: onboardingToday))
        #expect(saves.journey.letters.first?.kind == .logbook && saves.journey.letters.first?.logbook == nil)
        flow.startReading()
        let calls = await probe.calls
        #expect(calls == 1)
    }

    @Test func continuingWhileReadingPermanentlyChoosesWelcome() async throws {
        let probe = OnboardingReadProbe(days: substantialOnboardingHistory(), delay: .seconds(2))
        let flow = OnboardingFlow(catalog: localizationCatalog, seed: 42, today: onboardingToday,
                                  readUsage: { since, until in try await probe.read(since: since, until: until) })
        flow.startReading()
        // Let the injected function begin before cancellation, so its call count is observable.
        for _ in 0..<100 {
            if await probe.calls == 1 { break }
            await Task.yield()
        }
        advanceToHatch(flow)
        flow.advance(l10n: L10n(language: .en))
        #expect(flow.step == .logbook && flow.isReading && flow.canContinue)
        flow.advance(l10n: L10n(language: .en))
        #expect(flow.step == .depart && !flow.isReading && flow.logbook == nil)
        await Task.yield()
        #expect(flow.logbook == nil)
        let calls = await probe.calls
        #expect(calls == 1)
    }

    @Test func anEmptyHistoryAlsoProducesWelcome() async throws {
        let flow = OnboardingFlow(catalog: localizationCatalog, seed: 42, today: onboardingToday, readUsage: { _, _ in ([], []) })
        flow.startReading()
        try await waitForOnboardingRead(flow)
        #expect(flow.logbook == nil)
        advanceToDeparture(flow)
        #expect(flow.saves(now: onboardingToday)?.journey.letters.first?.logbook == nil)
    }

    @Test(arguments: [Language.zhHans, .en])
    func firstLetterTitlesMatchItsContentInTheFlowAndSavedMailbox(language: Language) async throws {
        let l10n = L10n(language: language)
        for hasLogbook in [false, true] {
            let fixture = try OnboardingFixture()
            defer { fixture.remove() }
            let model = fixture.model(reader: OnboardingReadProbe(days: hasLogbook ? substantialOnboardingHistory() : []))
            let flow = try #require(model.onboarding)
            model.start()
            try await waitForOnboardingRead(flow)
            advanceToHatch(flow, language: language)
            flow.skipHatching()
            flow.advance(l10n: l10n)
            #expect(flow.step == .logbook)
            let expectedStepTitle = hasLogbook
                ? (language == .zhHans ? "第一封信：航海日志" : "A first letter: your logbook")
                : (language == .zhHans ? "第一封信" : "A first letter")
            let expectedLetterTitle = hasLogbook
                ? (language == .zhHans ? "航海日志" : "Your logbook")
                : (language == .zhHans ? "你好" : "Hello")
            #expect(l10n.onboardingTitle(flow) == expectedStepTitle)
            let preview = try #require(flow.preview.letters.first)
            #expect(LetterComposer.text(for: preview, l10n: l10n, petName: flow.trimmedName, catalog: localizationCatalog).title == expectedLetterTitle)
            flow.advance(l10n: l10n)
            model.completeOnboarding()
            let journey = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: fixture.journeyURL))
            let saved = try #require(journey.letters.first)
            #expect(LetterComposer.text(for: saved, l10n: l10n, petName: model.petName, catalog: localizationCatalog).title == expectedLetterTitle)
        }
    }

    @Test(arguments: [Language.zhHans, .en])
    func logbookAndWelcomeLettersHaveCompleteLocalizedText(language: Language) throws {
        let l10n = L10n(language: language)
        let examples: [Logbook?] = [nil,
            Logbook(workdayStartHour: 9, weekendActivePercent: 25, topClients: ["codex", "claude"]),
            Logbook(workdayStartHour: nil, weekendActivePercent: 26, topClients: ["codex"]),
            Logbook(workdayStartHour: nil, weekendActivePercent: nil, topClients: []),
        ]
        for example in examples {
            let state = JourneyState(seed: 42, startCityId: "shanghai", date: onboardingDate, logbook: example, catalog: localizationCatalog)
            let letter = try #require(state.letters.first)
            let text = LetterComposer.text(for: letter, l10n: l10n, petName: "Coo", catalog: localizationCatalog)
            for value in [text.title, text.voice, text.signature] + text.itinerary {
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!value.contains("letter."))
                if language == .en { #expect(value.range(of: #"\p{Han}"#, options: .regularExpression) == nil) }
            }
            if let example {
                #expect(text.itinerary == [l10n("letter.logbookSource")])
                #expect(text.voice.contains(l10n("letter.logbookClosing")))
                #expect(!text.voice.contains("午饭"))
                if example.weekendActivePercent == 25 { #expect(text.voice.contains(l10n("letter.logbookQuietWeekend"))) }
                if example.weekendActivePercent == 26 { #expect(text.voice.contains(l10n("letter.logbookBusyWeekend"))) }
                if example.topClients.count == 2 { #expect(text.voice.contains("Codex") && text.voice.contains("Claude")) }
                if example.topClients.count == 1 { #expect(text.voice.contains("Codex") && !text.voice.contains("Claude")) }
            } else {
                #expect(text.itinerary.isEmpty)
                #expect(!text.voice.contains { $0.isNumber })
                #expect(text.voice == l10n("letter.welcomeBody"))
            }
        }
    }

    @Test func hometownIsAvailableOnlyOnTheStartDayAndKeepsTheLogbookAndCare() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let model = fixture.model(reader: OnboardingReadProbe(days: substantialOnboardingHistory()))
        let flow = try #require(model.onboarding)
        model.start()
        try await waitForOnboardingRead(flow)
        advanceToDeparture(flow)
        model.completeOnboarding()
        #expect(model.canChangeStart)
        let careBefore = try Data(contentsOf: fixture.careURL)
        var expectedLetter = try #require(model.state?.letters.first)
        expectedLetter.cityId = "beijing"
        model.setStart("beijing")
        #expect(model.state?.route.first == "beijing")
        #expect(model.state?.letters.first == expectedLetter)
        #expect(model.state?.letters.first?.kind == .logbook)
        #expect(try Data(contentsOf: fixture.careURL) == careBefore)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: onboardingToday)!
        let later = fixture.model(now: tomorrow)
        #expect(!later.canChangeStart)
        let before = later.state
        later.setStart("shanghai")
        #expect(later.state == before)
    }

    @Test func allFiveStepsBlockScansAndQuotaReadsUntilCompletion() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let quota = OnboardingQuotaProbe()
        let reader = OnboardingReadProbe()
        let model = fixture.model(reader: reader, quota: quota)
        let flow = try #require(model.onboarding)
        model.start()
        for step in OnboardingFlow.Step.allCases {
            #expect(flow.step == step)
            model.start()
            model.scheduleScan(immediately: true)
            await model.scan()
            await model.loadDashboard()
            await model.loadQuotas(force: true)
            await model.enrichLatest()
            #expect(model.lastScan == nil && model.dashboardDays == nil && model.quotasLoadedAt == nil)
            let calls = await quota.calls
            #expect(calls == 0)
            #expect(try fixture.files().isEmpty)
            if step == .eggs { flow.selectEgg(.pigeon) }
            flow.advance(l10n: L10n(language: .en))
        }
        model.completeOnboarding()
        await model.loadQuotas(force: true)
        let quotaCalls = await quota.calls
        #expect(quotaCalls == 1)
        #expect(model.quotasLoadedAt != nil)
    }

    @Test func itemSelectionCanBeClearedAndSnapshotsNeverWrite() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        for step in OnboardingFlow.Step.allCases {
            let flow = OnboardingFlow.snapshot(catalog: localizationCatalog, today: onboardingToday, l10n: L10n(language: .en), step: step, welcome: false)
            #expect(flow.step == step && !flow.isReading)
            flow.toggleItem("sketchbook")
            #expect(flow.todayItem == "sketchbook")
            flow.toggleItem("sketchbook")
            #expect(flow.todayItem == nil)
            flow.toggleItem("not-owned")
            #expect(flow.todayItem == nil)
        }
        let model = fixture.model(isSnapshot: true)
        let original = model.state
        model.completeOnboarding()
        #expect(model.onboarding == nil && model.state == original)
        #expect(try fixture.files().isEmpty)
    }

    @Test func careSaveFailureReportsTheErrorAfterJourneyWriteAndCanRetry() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let flow = try #require(model.onboarding)
        advanceToDeparture(flow)
        flow.petName = "Retry Coo"
        flow.toggleItem("note-slip")
        try FileManager.default.createDirectory(at: fixture.careURL, withIntermediateDirectories: true)
        model.completeOnboarding()
        #expect(model.isLocked && model.onboarding?.step == .depart)
        #expect(model.state == nil && model.lastScan == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.journeyURL.path))
        let written = try JSONDecoder().decode(JourneyState.self, from: Data(contentsOf: fixture.journeyURL))
        #expect(written.totalFuel == 0 && written.letters.first?.kind == .logbook)
        guard case .save? = model.lastError as? AppError else { Issue.record("A care write failure must reach the existing save error path"); return }
        try FileManager.default.removeItem(at: fixture.careURL)
        model.retrySaves()
        #expect(!model.isLocked && model.onboarding == nil && model.lastError == nil)
        let care = try JSONDecoder().decode(CareState.self, from: Data(contentsOf: fixture.careURL))
        #expect(care.petName == "Retry Coo" && care.bag.todayItem == "note-slip")
        #expect(care.companionDays == [onboardingDate] && care.weekly.stamps == [onboardingDate])
    }
}
