import AppKit
import Foundation
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private let notchNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!

private func notchJourney(phase: JourneyState.Phase, remainingKm: Double = 120) -> JourneyState {
    var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: notchNow), now: notchNow, catalog: localizationCatalog)
    journey.phase = phase
    journey.targetCityId = phase == .returning ? "shanghai" : "beijing"
    journey.currentCityId = phase == .staying || phase == .returning ? "beijing" : "shanghai"
    journey.targetCountryCode = localizationCatalog.city(journey.targetCityId).countryCode
    journey.legFrom = localizationCatalog.city(journey.currentCityId).coordinate
    journey.legTo = localizationCatalog.city(journey.targetCityId).coordinate
    journey.legCost = 200 * journey.tokensPerKm
    journey.legFuel = journey.legCost - Int(remainingKm * Double(journey.tokensPerKm))
    journey.travelFund = 73 * outboundTokensPerKm
    if phase == .pending { journey.phaseSince = notchNow.addingTimeInterval(-2 * 60) }
    if phase == .staying { journey.phaseSince = notchNow.addingTimeInterval(-(3 * 3600 + 43 * 60)) }
    return journey
}

private final class NotchTripDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { key == "language" ? "en" : nil }
    override func string(forKey key: String) -> String? { key == "language" ? "en" : nil }
    override func set(_ value: Any?, forKey key: String) {}
}

@MainActor private struct NotchTripFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-notch-trip-\(UUID())")

    init() throws {
        var journey = notchJourney(phase: .pending)
        journey.legFuel = 0
        journey.travelFund = 0
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        care.bag.todayItem = "sketchbook"
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(care)
    }

    func model() -> AppModel {
        AppModel(defaults: NotchTripDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                 now: { notchNow }, usageReader: { _, _ in Issue.record("Notch controls must not scan usage"); return [] },
                 hoursReader: { _, _ in [] }, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor struct NotchTripTests {
    @Test(arguments: [Language.zhHans, .en])
    func collapsedStatusReflectsEveryPhase(language: Language) {
        let l10n = L10n(language: language)
        let cases: [(JourneyState.Phase, String)] = language == .zhHans ? [
            (.home, "在家"), (.pending, "→ 北京 · 28 分后出发"), (.outbound, "→ 北京"),
            (.staying, "在北京 · 还停 2 时 17 分"), (.returning, "← 回家 · 还差 120 km"),
        ] : [
            (.home, "At home"), (.pending, "→ Beijing · Leaves in 28 min"), (.outbound, "→ Beijing"),
            (.staying, "In Beijing · Staying 2h 17m more"), (.returning, "← Home · 120 km to go"),
        ]
        for (phase, expected) in cases {
            let display = NotchDisplay(journey: notchJourney(phase: phase), care: nil, now: notchNow, catalog: localizationCatalog, l10n: l10n)
            #expect(display.status == expected)
            #expect((display.pending != nil) == (phase == .pending))
        }
    }

    @Test(arguments: [Language.zhHans, .en], [49.0, 50.0, 50.1])
    func outboundSwitchesFromDestinationAtFiftyKilometers(language: Language, remainingKm: Double) {
        let display = NotchDisplay(journey: notchJourney(phase: .outbound, remainingKm: remainingKm), care: nil,
                                   now: notchNow, catalog: localizationCatalog, l10n: L10n(language: language))
        let remaining = remainingKm == 49 ? "49 km" : "50 km"
        let distance = language == .zhHans ? "还差 \(remaining)" : "\(remaining) to go"
        #expect(display.status == (remainingKm <= 50 ? distance : language == .zhHans ? "→ 北京" : "→ Beijing"))
        #expect(display.compactStatus == distance)
        #expect(display.remainingAndFund == (language == .zhHans ? "\(distance) · 路费 73 km" : "\(distance) · Travel fund 73 km"))
    }

    @Test(arguments: [Language.zhHans, .en], [false, true])
    func pendingPreviewUsesThePickersDistanceBand(language: Language, reachableToday: Bool) throws {
        var journey = notchJourney(phase: .pending)
        let distance = journey.homeCoordinate.distanceKm(to: localizationCatalog.city(journey.targetCityId).coordinate)
        journey.legCost = Int(distance * Double(outboundTokensPerKm))
        journey.homecoming = Homecoming(tripNumber: 1, cityId: "beijing", returnedAt: notchNow,
                                       distanceKm: distance, medianKm: reachableToday ? distance * 2 : 300)
        var care = CareState(petName: "Pip", species: journey.pet, hatchedAt: journey.startDate)
        care.bag.todayItem = "raincoat"
        let pending = try #require(NotchDisplay(journey: journey, care: care, now: notchNow,
                                               catalog: localizationCatalog, l10n: L10n(language: language)).pending)
        let band = language == .zhHans ? (reachableToday ? "当天能到" : "随便走") : (reachableToday ? "Reachable today" : "Wander")
        #expect(pending.destination == (language == .zhHans ? "北京" : "Beijing"))
        #expect(pending.distanceAndBand == (language == .zhHans ? "离家 \(Format.km(journey.legKm)) · \(band)" : "\(Format.km(journey.legKm)) from home · \(band)"))
        #expect(pending.countdown == (language == .zhHans ? "28 分后自动出发" : "Leaves automatically in 28 min"))
        #expect(pending.carriedItemID == "raincoat")
    }

    @Test(arguments: [(0.0, 30), (1.0, 30), (120.0, 28), (1_799.0, 1), (1_800.0, 0), (1_900.0, 0)])
    func pendingCountdownRoundsUpAndNeverBecomesNegative(elapsed: TimeInterval, minutes: Int) throws {
        var journey = notchJourney(phase: .pending)
        journey.phaseSince = notchNow.addingTimeInterval(-elapsed)
        let display = NotchDisplay(journey: journey, care: nil, now: notchNow, catalog: localizationCatalog, l10n: L10n(language: .en))
        #expect(display.status == "→ Beijing · Leaves in \(minutes) min")
        #expect(try #require(display.pending).countdown == "Leaves automatically in \(minutes) min")
    }

    @Test func pendingControlsChangeTheOwnedItemAndDepartWithoutChangingTheDestination() throws {
        let fixture = try NotchTripFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let before = try #require(model.state)
        #expect(model.canDepartNow)
        #expect(model.setTodayItem("raincoat"))
        let display = NotchDisplay(journey: before, care: model.care, now: notchNow, catalog: localizationCatalog, l10n: model.l10n)
        #expect(display.pending?.carriedItemID == "raincoat")
        #expect(fixture.model().care?.bag.todayItem == "raincoat")
        let care = model.care
        #expect(!model.setTodayItem("not-owned"))
        #expect(model.care == care && fixture.model().care == care)
        model.departNow()
        let departed = try #require(model.state)
        #expect(departed.phase == .outbound && departed.phaseSince == notchNow)
        #expect(departed.targetCityId == before.targetCityId && departed.legCost == before.legCost)
        #expect(departed.route == before.route && departed.totalKm == before.totalKm)
        #expect(!model.canDepartNow)
        #expect(fixture.model().state == departed && fixture.model().care?.bag.todayItem == "raincoat")
        model.departNow()
        #expect(model.state == departed)
    }

    @Test(arguments: [CGFloat(0), 180])
    func theSharedCollapsedContentRendersWithAndWithoutAScreenNotch(notchWidth: CGFloat) throws {
        let fixture = try NotchTripFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let metrics = NotchMetrics(notchWidth: notchWidth, barHeight: 30)
        let renderer = ImageRenderer(content: NotchCollapsedView(model: model, metrics: metrics).environment(\.l10n, model.l10n))
        let image = try #require(renderer.nsImage)
        #expect(image.size == metrics.collapsedSize)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(model.state?.phase == .pending && model.canDepartNow)
    }

    @Test func expandingThePanelRoutesTheFirstMouseToItsInteractiveContent() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parent
        defer { window.contentView = nil; window.close() }
        let host = PanelHostView(rootView: Button("Leave now") {}.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = NSRect(x: 40, y: 60, width: 300, height: 80)
        parent.addSubview(host)
        host.layout()
        host.layoutSubtreeIfNeeded()
        let point = NSPoint(x: host.frame.midX, y: host.frame.midY)
        #expect(host.hitTest(point) === host)
        #expect(host.acceptsFirstMouse(for: nil))
        host.interactiveContent = true
        let hosting = try #require(host.subviews.first)
        #expect(hosting.frame == host.bounds)
        let target = try #require(host.hitTest(point))
        #expect(target === hosting || target.isDescendant(of: hosting))
        #expect(hosting.acceptsFirstMouse(for: nil))
        #expect(host.hitTest(NSPoint(x: 20, y: 20)) == nil)
        host.interactiveContent = false
        #expect(host.hitTest(point) === host)
    }
}
