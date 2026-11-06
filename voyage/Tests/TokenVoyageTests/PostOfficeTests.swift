import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class CareDefaults: UserDefaults, @unchecked Sendable {
    override func string(forKey key: String) -> String? { key == "language" ? "en" : nil }
    override func object(forKey key: String) -> Any? { string(forKey: key) }
    override func set(_ value: Any?, forKey key: String) {}
}

@MainActor private final class CareClock {
    var date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
}

@MainActor private struct CareFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-care-ui-\(UUID().uuidString)")
    let clock = CareClock()

    init(allRead: Bool = true, update: (inout JourneyState, inout CareState) -> Void = { _, _ in }) throws {
        var examples = Snapshots.collectionExamples(catalog: localizationCatalog, now: clock.date, petName: "Ginkgo")
        for index in examples.journey.letters.indices { examples.journey.letters[index].read = allRead }
        examples.care.bag.todayItem = nil
        update(&examples.journey, &examples.care)
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(examples.journey)
        try store.save(examples.care)
    }

    func model(isSnapshot: Bool = false, floatingReactionDuration: Duration = .seconds(3),
               usageReader: @escaping @Sendable (String?, String) async throws -> [DayDetail] = { _, _ in Issue.record("Care UI must not read usage"); return [] },
               hoursReader: @escaping @Sendable (String, String) async throws -> [HourUsage] = { _, _ in Issue.record("Care UI must not read hourly usage"); return [] }) -> AppModel {
        AppModel(isSnapshot: isSnapshot, defaults: CareDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { clock.date }, quotaReader: { Issue.record("Care UI must not request quotas"); return [] },
                 usageReader: usageReader,
                 hoursReader: hoursReader,
                 enrichmentReader: { _ in Issue.record("Care UI must not request enrichment"); return Enrichment() },
                 runtimeEnabled: false, floatingReactionDuration: floatingReactionDuration)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor struct PostOfficeTests {
    @Test func noMailPresentationPersistsOncePerDayAndRechecksOnReturningOrBecomingFrontmost() throws {
        let fixture = try CareFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.postOfficeDidDisplay() // Hidden windows are not companionship.
        #expect(model.care?.companionDays.isEmpty == true)
        model.setMainWindowPresented(true)
        #expect(model.care?.companionDays == ["2026-11-06"])
        model.setMainWindowPresented(false)
        model.setMainWindowPresented(true)
        model.postOfficeDidDisplay()
        #expect(model.care?.companionDays == ["2026-11-06"])
        #expect(fixture.model().care?.companionDays == ["2026-11-06"])
        model.setMainWindowPresented(false)
        fixture.clock.date = Calendar.current.date(byAdding: .day, value: 1, to: fixture.clock.date)!
        model.postOfficeDidDisplay()
        #expect(model.care?.companionDays.count == 1)
        model.setMainWindowPresented(true)
        #expect(model.care?.companionDays == ["2026-11-06", "2026-11-07"])
        #expect(fixture.model().care?.companionDays == model.care?.companionDays)
        model.navigate(to: .journey)
        fixture.clock.date = Calendar.current.date(byAdding: .day, value: 1, to: fixture.clock.date)!
        model.postOfficeDidDisplay()
        #expect(model.care?.companionDays.count == 2)
        model.openPostOffice()
        #expect(model.care?.companionDays.last == "2026-11-08")
    }

    @Test func unreadMailWaitsForReadingAndFutureMailDoesNotBlock() throws {
        let fixture = try CareFixture(allRead: false) { journey, _ in
            for index in journey.letters.indices { journey.letters[index].read = journey.letters[index].id != 5 }
        }
        defer { fixture.remove() }
        let model = fixture.model()
        model.setMainWindowPresented(true)
        #expect(model.care?.companionDays.isEmpty == true)
        model.openLetter(try #require(model.letters.first { !$0.read }))
        #expect(model.care?.companionDays == ["2026-11-06"])
        model.postOfficeDidDisplay()
        #expect(fixture.model().care?.companionDays == ["2026-11-06"])

        let future = try CareFixture { journey, _ in
            journey.letters[1].read = false
            journey.letters[1].deliverAt = .distantFuture
        }
        defer { future.remove() }
        let other = future.model()
        other.setMainWindowPresented(true)
        #expect(other.care?.companionDays == ["2026-11-06"])
    }

    @Test func floatingNotchProfileSettingsAndSnapshotsDoNotRecordGlances() throws {
        let fixture = try CareFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        for surface in [CompanionSurface.notch, .floating] { model.postOfficeDidDisplay(surface: surface) }
        #expect(model.care?.companionDays.isEmpty == true)
        model.showProfile()
        model.setMainWindowPresented(true)
        #expect(model.care?.companionDays.isEmpty == true)
        model.setMainWindowPresented(false)
        model.openPostOffice()
        model.showingSettings = true
        model.setMainWindowPresented(true)
        #expect(model.care?.companionDays.isEmpty == true)

        let snapshot = fixture.model(isSnapshot: true)
        let before = snapshot.care
        snapshot.setMainWindowPresented(true)
        snapshot.openLetter(try #require(snapshot.letters.first { !$0.read }))
        snapshot.postOfficeDidDisplay()
        #expect(snapshot.care == before)
        #expect(fixture.model().care?.companionDays.isEmpty == true)
    }

    @Test func bubbleTargetsOpenRitualSpecificLetterAndBag() throws {
        let fixture = try CareFixture(allRead: false)
        defer { fixture.remove() }
        let model = fixture.model()
        #expect(model.petBubble == .mail)
        model.activateBubble(.mail)
        #expect(model.ritualLetterID != nil && model.tab == .home)
        model.activateBubble(.reply(3))
        #expect(model.selectedLetterID == 3 && model.tab == .mail && model.ritualLetterID == nil)
        model.activateBubble(.bag)
        #expect(model.tab == .collection && model.collectionTab == .bag)
        model.openCollection(.souvenirs)
        #expect(model.collectionTab == .souvenirs)
    }

    @Test func giftQueuePersistsEachResultAndContinuesThroughOldWeeks() throws {
        let fixture = try CareFixture { _, care in care.weekly.boxes = ["2026-10-19#4", "2026-10-19#6"] }
        defer { fixture.remove() }
        let model = fixture.model()
        #expect(model.pendingBoxCount == 2)
        model.showBoxes()
        #expect(model.homePage == .box && model.boxStampCount == 4 && model.boxResult == nil)
        let result = model.openPresentedBox()
        #expect(result == .item(id: localizationCatalog.items.boxes.souvenirIds[0], kind: "souvenir"))
        #expect(model.pendingBoxCount == 1)
        #expect(model.boxFinishTitle == "Open another")
        let saved = try #require(model.care)
        #expect(model.openPresentedBox() == nil)
        #expect(model.care == saved)
        #expect(fixture.model().care == saved)
        let item = try #require(saved.souvenirs.last)
        #expect(ItemCollection.boxOrigin(for: item, l10n: model.l10n) == "Weekly gift box")
        #expect(item.letterId == nil && item.boxId == "2026-10-19#4")
        model.finishBox()
        #expect(model.homePage == .box && model.boxResult == nil && model.boxStampCount == 6)
        #expect(model.openPresentedBox() == .item(id: localizationCatalog.items.boxes.souvenirIds[1], kind: "souvenir"))
        #expect(model.pendingBoxCount == 0 && model.boxFinishTitle == "Put away")
        model.finishBox()
        #expect(model.homePage == .room && model.tab == .home)
        #expect(fixture.model().care?.boxesOpened == 2)
    }

    @Test(arguments: Snapshots.BoxExample.allCases)
    func giftExamplesProduceTheirActualResultTypesAndPersist(kind: Snapshots.BoxExample) throws {
        let date = CareClock().date
        let example = Snapshots.boxExamples(kind: kind, catalog: localizationCatalog, now: date, petName: "Ginkgo")
        let fixture = try CareFixture { journey, care in journey = example.journey; care = example.care }
        defer { fixture.remove() }
        let model = fixture.model()
        model.showBoxes()
        let result = try #require(model.openPresentedBox())
        switch kind {
        case .souvenir: #expect(result == .item(id: localizationCatalog.items.boxes.souvenirIds[0], kind: "souvenir"))
        case .bag: #expect(result == .item(id: "old-camera", kind: "bag"))
        case .clue:
            let city = example.journey.letters.max { $0.id < $1.id }!.cityId
            #expect(result == .clue(cityId: city))
            #expect(model.care?.trailClues[city] == example.care.trailClues[city, default: 0] + 1)
        }
        #expect(fixture.model().care == model.care)
    }

    @Test func fullShelfShowsLocalizedReasonAndRejectsWithoutChangingCareOrDisk() throws {
        let fixture = try CareFixture { journey, care in
            for id in ["2026-10-19#4", "2026-10-19#6", "2026-10-26#4", "2026-10-26#6", "2026-11-02#4"] {
                care.weekly.boxes.append(id)
                _ = CareEngine.openBox(id: id, care: &care, library: localizationCatalog.items, date: journey.openDate, journey: journey)
            }
            for item in care.souvenirs.prefix(4) { CareEngine.setShelved(id: item.id, shelved: true, care: &care) }
        }
        defer { fixture.remove() }
        let model = fixture.model()
        let care = try #require(model.care)
        let extra = try #require(care.souvenirs.first { !$0.shelved })
        let before = try Data(contentsOf: fixture.directory.appendingPathComponent("care.json"))
        #expect(!model.setSouvenirShelved(extra.id, shelved: true))
        #expect(model.care == care)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("care.json")) == before)
        #expect(ItemCollection.shelfFullMessage(for: extra, care: care, l10n: L10n(language: .zhHans)) == "架子放满了，先收起一件")
        #expect(ItemCollection.shelfFullMessage(for: care.souvenirs[0], care: care, l10n: model.l10n) == nil)
        #expect(model.setSouvenirShelved(care.souvenirs[0].id, shelved: false))
        #expect(model.setSouvenirShelved(extra.id, shelved: true))
        #expect(RoomLayout.shelf(try #require(fixture.model().care)).contains { $0.id == extra.id })
    }

    @Test func snapshotsReadLocalUsageWithoutWritingCorruptSavesOrRequestingNetwork() async throws {
        let fixture = try CareFixture()
        defer { fixture.remove() }
        let journeyURL = fixture.directory.appendingPathComponent("journey.json")
        let careURL = fixture.directory.appendingPathComponent("care.json")
        try Data("sentinel: invalid journey".utf8).write(to: journeyURL)
        try Data("sentinel: invalid care".utf8).write(to: careURL)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let detail = DayDetail(date: DayKey.string(from: fixture.clock.date), rows: [
            UsageRow(client: "codex", model: "test", tokens: UsageTotals(input: 123_456, output: 789)),
        ])
        let yesterday = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -1, to: fixture.clock.date)!)
        let monthStart = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -29, to: fixture.clock.date)!)
        let hours = try TokscaleHourly.parse(Data("""
        {"entries":[
          {"hour":"\(yesterday) 09:00","input":100},
          {"hour":"\(detail.date) 10:00","input":123456,"output":789}
        ]}
        """.utf8))
        let model = fixture.model(isSnapshot: true, usageReader: { since, until in
            #expect(since == nil && until == detail.date)
            return [detail]
        }, hoursReader: { since, until in
            #expect(until == detail.date)
            #expect(since == until || since == monthStart)
            return since == until ? hours.filter { $0.date == until } : hours
        })
        #expect(!model.isLocked && model.onboarding == nil)
        #expect(model.petName == "Coo")
        let care = try #require(model.care)
        #expect(model.unread > 0 && !RoomLayout.shelf(care).isEmpty)
        model.setMainWindowPresented(true)
        await model.scan()
        await model.loadQuotas()
        await model.loadDashboard()
        #expect(model.lastScan == fixture.clock.date && model.lastError == nil)
        #expect(model.todayFuel == detail.usage.fuel)
        #expect(model.todayTotals?.total == detail.rows[0].tokens.total)
        #expect(model.dashboardDays == [detail] && model.quotas.isEmpty)
        #expect(model.dashboardHours == hours)
        #expect(HourUsage.profile(model.dashboardHours, start: detail.date, end: detail.date, metric: .total)[10] == Double(detail.rows[0].tokens.total))
        model.showProfile()
        model.reactToFloatingClick()
        for kind in Snapshots.BoxExample.allCases {
            let example = Snapshots.boxExamples(kind: kind, catalog: localizationCatalog, now: fixture.clock.date, petName: "Ginkgo")
            model.withSnapshotState({ $0 = example.journey }) {
                model.withSnapshotCare({ $0 = example.care }) {
                    model.showBoxes()
                    #expect(model.openPresentedBox() != nil)
                    model.finishBox()
                }
            }
        }
        #expect(String(decoding: try Data(contentsOf: journeyURL), as: UTF8.self) == "sentinel: invalid journey")
        #expect(String(decoding: try Data(contentsOf: careURL), as: UTF8.self) == "sentinel: invalid care")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == filesBefore)
    }

    @Test func floatingReactionUsesLatestLearnedInCurrentLanguageThenRestores() async throws {
        let fixture = try CareFixture { journey, _ in
            journey.letters[1].learnedTexts = ["en": "An older lesson", "zh-Hans": "旧心得"]
            journey.letters[5].learnedTexts = ["en": "Look for a doorway in the rain.", "zh-Hans": "下雨先找屋檐。"]
        }
        defer { fixture.remove() }
        let model = fixture.model(floatingReactionDuration: .milliseconds(10))
        model.navigate(to: .journey)
        model.reactToFloatingClick()
        #expect(model.floatingReaction && model.floatingJump)
        #expect(model.floatingWords == "Look for a doorway in the rain.")
        #expect(model.tab == .journey && !model.mainWindowPresented)
        model.languagePreference = .zhHans
        #expect(model.floatingWords == "下雨先找屋檐。")
        let restoredBy = ContinuousClock.now.advanced(by: .seconds(10))
        while (model.floatingReaction || model.floatingJump), ContinuousClock.now < restoredBy {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.floatingReaction && !model.floatingJump)
    }

    @Test func floatingFallbacksAreLocalizedAndHidingEndsTheReaction() throws {
        let fixture = try CareFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        for language in [LanguagePreference.en, .zhHans] {
            model.languagePreference = language
            for _ in 0..<3 {
                model.reactToFloatingClick()
                #expect(L10n.floatingKeys.map { model.l10n($0) }.contains(model.floatingWords))
                model.endFloatingReaction()
                #expect(!model.floatingReaction && !model.floatingJump)
            }
        }
    }
}
