import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

@Test func navigationContainsTheFiveDestinationsAndImplementedChildren() {
    #expect(MainTab.allCases == [.home, .journey, .mail, .collection, .data])
    #expect(MailFilter.allCases == [.all, .travel, .postcards, .weekly])
    #expect(CollectionTab.allCases == [.passport, .bag, .souvenirs, .menus, .memories])
    #expect(DataTab.allCases == [.dashboard, .quota])
}

@MainActor
@Test func mainWindowStartsAtThePostOffice() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let model = fixture.model()
    #expect(model.tab == .home)
    #expect(model.mailFilter == .all)
    #expect(model.collectionTab == .passport)
    #expect(model.dataTab == .dashboard)
    #expect(!model.showingSettings)
}

@MainActor
@Test func homeActionOpensTheEarliestDeliveredUnreadLetterInTheRitual() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let model = fixture.model(isSnapshot: false)
    model.navigate(to: .collection)
    model.mailFilter = .travel
    model.selectedLetterID = 1
    model.showingSettings = true

    model.activateHomeAction()

    #expect(model.tab == .home)
    #expect(model.ritualLetterID == 0)
    #expect(model.ritualLetter?.read == true)
    #expect(!model.showingSettings)
    #expect(model.unread == 2)
}

@MainActor
@Test func homeActionWithoutDeliveredUnreadMailOpensTheJourney() throws {
    let fixture = try NavigationFixture(allDeliveredRead: true)
    defer { fixture.remove() }
    let model = fixture.model(isSnapshot: false)
    model.navigate(to: .mail)
    model.showingSettings = true

    model.activateHomeAction()

    #expect(model.unread == 0)
    #expect(model.tab == .journey)
    #expect(!model.showingSettings)
}

@MainActor
@Test func travelMailExcludesTheDepartureLetter() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let model = fixture.model(isSnapshot: false)
    let departure = try #require(model.letters.first { $0.kind == .departure })
    let daily = try #require(model.letters.first { $0.kind == .daily })
    #expect(MailFilter.all.includes(departure))
    #expect(MailFilter.all.includes(daily))
    #expect(!MailFilter.travel.includes(departure))
    #expect(MailFilter.travel.includes(daily))

    model.mailFilter = .all
    #expect(model.filteredLetters.map(\.id) == [8, 7, 1, 0])
    model.mailFilter = .travel
    #expect(model.filteredLetters.map(\.id) == [8, 7, 1])
}

@Test func nearArrivalUsesTheFiftyKilometreBoundary() {
    #expect(NotchStatus.nearArrivalKilometers == 50)
    #expect(NotchStatus.isNearArrival(remainingFuel: 50 * fuelPerKm))
    #expect(!NotchStatus.isNearArrival(remainingFuel: 50 * fuelPerKm + 1))
    #expect(!NotchStatus.isNearArrival(remainingFuel: 51 * fuelPerKm))
    #expect(NotchStatus.isNearArrival(remainingFuel: 0))
}

@MainActor
@Test func displayPreferencesDefaultToEnabledAndPersistThroughInjectedDefaults() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let defaults = NavigationDefaults()
    let model = fixture.model(isSnapshot: false, defaults: defaults)
    #expect(model.notchEnabled)
    #expect(model.floatingEnabled)
    #expect(defaults.object(forKey: "notchEnabled") == nil)
    #expect(defaults.object(forKey: "floatingEnabled") == nil)
    var displayChanges = 0
    model.onDisplayChange = { displayChanges += 1 }

    model.notchEnabled = false
    model.floatingEnabled = false

    #expect(defaults.object(forKey: "notchEnabled") as? Bool == false)
    #expect(defaults.object(forKey: "floatingEnabled") as? Bool == false)
    #expect(displayChanges == 2)
    let reloaded = fixture.model(isSnapshot: false, defaults: defaults)
    #expect(!reloaded.notchEnabled)
    #expect(!reloaded.floatingEnabled)

    model.notchEnabled = true
    model.floatingEnabled = true
    #expect(defaults.object(forKey: "notchEnabled") as? Bool == true)
    #expect(defaults.object(forKey: "floatingEnabled") as? Bool == true)
    #expect(displayChanges == 4)
}

@MainActor
@Test func snapshotDisplayChangesStayInMemory() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let defaults = NavigationDefaults()
    defaults.set(false, forKey: "notchEnabled")
    defaults.set(true, forKey: "floatingEnabled")
    let writesBefore = defaults.writeCount
    let model = fixture.model(defaults: defaults)
    #expect(!model.notchEnabled)
    #expect(model.floatingEnabled)

    model.notchEnabled = true
    model.floatingEnabled = false

    #expect(model.notchEnabled)
    #expect(!model.floatingEnabled)
    #expect(defaults.object(forKey: "notchEnabled") as? Bool == false)
    #expect(defaults.object(forKey: "floatingEnabled") as? Bool == true)
    #expect(defaults.writeCount == writesBefore)
}

@MainActor
@Test func openingFromTheNotchReturnsToThePostOffice() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let model = fixture.model()
    model.navigate(to: .data)
    model.dataTab = .quota
    model.showingSettings = true

    model.openPostOffice()

    #expect(model.tab == .home)
    #expect(!model.showingSettings)
}

@MainActor
@Test func snapshotStateOverridesAreRestoredAndNeverWritten() throws {
    let fixture = try NavigationFixture()
    defer { fixture.remove() }
    let model = fixture.model()
    let original = try #require(model.state)
    let journeyURL = fixture.directory.appendingPathComponent("journey.json")
    let careURL = fixture.directory.appendingPathComponent("care.json")
    let journeyData = try Data(contentsOf: journeyURL)
    let careData = try Data(contentsOf: careURL)
    var rendered = false

    model.withSnapshotState({ state in
        state.legFuel = max(0, state.legCost - 12 * fuelPerKm)
        for index in state.letters.indices { state.letters[index].read = true }
    }, render: {
        rendered = true
        #expect(model.unread == 0)
        #expect(model.state?.legFuel != original.legFuel)
        // Exercise the normal persistence path while the temporary snapshot state is active.
        model.setStart("beijing")
    })

    #expect(rendered)
    #expect(model.state == original)
    #expect(try Data(contentsOf: journeyURL) == journeyData)
    #expect(try Data(contentsOf: careURL) == careData)
}

@Test func compactSurfacesContainNoQuotaCode() throws {
    let source = try String(contentsOf: LocalizationTestFiles.appSources.appendingPathComponent("CompactViews.swift"), encoding: .utf8)
    #expect(!source.lowercased().contains("quota"))
}

/// Each model reads only a purpose-built save fixture, never the user's application support directory.
@MainActor
private struct NavigationFixture {
    let directory: URL

    init(allDeliveredRead: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-navigation-\(UUID().uuidString)")
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: Date(timeIntervalSince1970: 0), catalog: localizationCatalog)
        // Keep coverage for existing saves with the old unread departure letter.
        state.letters[0].kind = .departure
        state.letters[0].read = false
        let departure = state.letters[0]
        func daily(id: Int, read: Bool = false, future: Bool = false) -> Letter {
            var letter = departure
            letter.id = id
            letter.kind = .daily
            letter.read = read
            letter.deliverAt = future ? .distantFuture : Date(timeIntervalSince1970: 0)
            return letter
        }
        state.letters += [daily(id: 1), daily(id: 7), daily(id: 8, read: true), daily(id: 9, future: true)]
        if allDeliveredRead {
            for index in state.letters.indices where state.letters[index].deliverAt != .distantFuture {
                state.letters[index].read = true
            }
        }
        try store.save(state)
        try store.save(CareState.legacy(from: state, pets: localizationCatalog.pets))
    }

    func model(isSnapshot: Bool = true, defaults: UserDefaults = NavigationDefaults()) -> AppModel {
        AppModel(isSnapshot: isSnapshot, defaults: defaults, directory: directory, catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class NavigationDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private(set) var writeCount = 0
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        writeCount += 1
    }
}
