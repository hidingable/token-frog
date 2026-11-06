import AppKit
import SwiftUI
import VoyageCore

/// Renders every surface to PNG for offline visual checks: `TokenVoyage --snapshot <dir>`.
@MainActor
enum Snapshots {
    static func write(model: AppModel, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metrics = NotchMetrics(notchWidth: 180, barHeight: 37)
        let mainSize = CGSize(width: 760, height: 780)

        if let catalog = model.catalog {
            for (name, step, welcome) in [
                ("onboarding-1-eggs", OnboardingFlow.Step.eggs, false),
                ("onboarding-2-home", .home, false),
                ("onboarding-3-hatch", .hatch, false),
                ("onboarding-4-logbook", .logbook, false),
                ("onboarding-4-welcome", .logbook, true),
                ("onboarding-5-depart", .depart, false),
            ] {
                let flow = OnboardingFlow.snapshot(catalog: catalog, today: model.now, l10n: model.l10n, step: step, welcome: welcome)
                render(OnboardingView(flow: flow, onDepart: {}), size: mainSize, name: name, directory, model: model)
            }
        }

        func main(_ tab: MainTab, name: String, size: CGSize = mainSize, dashboard: DashboardSelection = DashboardSelection(), update: (inout JourneyState) -> Void = { _ in }) {
            model.withSnapshotState(update) {
                model.navigate(to: tab)
                render(MainView(model: model, dashboard: dashboard), size: size, name: name, directory, model: model)
            }
        }

        main(.home, name: "main-home", update: { state in
            // Even a fixture with only read mail shows the new-mail home variant.
            if let index = state.letters.indices.first {
                state.letters[index].read = false
                state.letters[index].deliverAt = min(state.letters[index].deliverAt, model.now)
            }
        })
        main(.home, name: "main-home-no-mail", update: { state in
            for index in state.letters.indices { state.letters[index].read = true }
        })
        main(.journey, name: "main-journey")
        model.mailFilter = .all
        model.selectedLetterID = nil
        main(.mail, name: "main-mail")
        if let catalog = model.catalog {
            let examples = mailExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.selectedLetterID = 2
            main(.mail, name: "mail-story", update: { $0 = examples })
            model.selectedLetterID = 1
            main(.mail, name: "mail-replied", update: { $0 = examples })
            model.selectedLetterID = 3
            main(.mail, name: "mail-legacy", update: { state in
                state = examples
                let index = state.letters.firstIndex { $0.id == 3 }!
                state.letters[index].texts = nil
                state.letters[index].leadTexts = [:]
                state.letters[index].storyId = nil
                state.letters[index].storyVersion = nil
                state.letters[index].replyOptions = []
                state.letters[index].facts = []
                state.letters[index].rewards = StoryRewards()
                state.letters[index].carriedItem = nil
            })
            model.selectedLetterID = nil
        }
        model.collectionTab = .passport
        main(.collection, name: "collection-passport", size: CGSize(width: 760, height: 400))
        if let catalog = model.catalog {
            let examples = collectionExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = examples.care }) {
                for (selection, name) in [
                    (CollectionTab.bag, "collection-bag"),
                    (.souvenirs, "collection-souvenirs"),
                    (.menus, "collection-menus"),
                ] {
                    model.collectionTab = selection
                    main(.collection, name: name, size: CGSize(width: 760, height: 620), update: { $0 = examples.journey })
                }
                for (letterID, name) in [(3, "mail-brought"), (5, "mail-duplicate")] {
                    model.selectedLetterID = letterID
                    main(.mail, name: name, update: { $0 = examples.journey })
                }
            }
            model.selectedLetterID = nil
            for (name, multiple) in [("ritual", false), ("ritual-multi", true)] {
                model.withSnapshotState({ state in
                    state = examples.journey
                    for index in state.letters.indices {
                        let id = state.letters[index].id
                        state.letters[index].read = id != 3 && !(multiple && id > 3)
                    }
                }) {
                    model.withSnapshotCare({ $0 = examples.care }) {
                        model.navigate(to: .home)
                        model.activateHomeAction()
                        render(MainView(model: model), size: CGSize(width: 760, height: 1240), name: name, directory, model: model)
                        model.navigate(to: .home)
                    }
                }
            }
        }
        model.showingSettings = true
        render(MainView(model: model), size: CGSize(width: 760, height: 520), name: "main-settings", directory, model: model)

        model.dataTab = .dashboard
        let dashboardSize = CGSize(width: 940, height: 1240)
        main(.data, name: "dashboard-month", size: dashboardSize, dashboard: DashboardSelection(period: .month))
        main(.data, name: "dashboard-all-codex", size: dashboardSize, dashboard: DashboardSelection(period: .all, client: "codex"))
        main(.data, name: "dashboard-today-narrow", size: CGSize(width: 760, height: 1240), dashboard: DashboardSelection(period: .today))
        let peak = model.dashboardDays.map { UsageDashboard(days: $0, start: nil, end: DayKey.string(from: model.now)) }?.peak
        main(.data, name: "dashboard-peak-day", size: dashboardSize, dashboard: DashboardSelection(day: peak?.date ?? DayKey.string(from: model.now), metric: .fuel, showModels: true))
        model.dataTab = .quota
        main(.data, name: "data-quota", size: CGSize(width: 760, height: 420))

        render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-collapsed", directory, model: model)
        model.withSnapshotState({ state in
            state.legCost = max(state.legCost, 12 * fuelPerKm)
            state.legFuel = state.legCost - 12 * fuelPerKm
            for index in state.letters.indices { state.letters[index].read = true }
        }) {
            render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-near-arrival", directory, model: model)
        }
        render(NotchExpandedView(model: model, metrics: metrics), size: metrics.expandedSize, name: "notch-expanded", directory, model: model)
        render(FloatingView(model: model), size: FloatingController.size, name: "floating", directory, model: model)

        let exampleDirectory = model.l10n("snapshot.exampleDirectory")
        let quarantinedPath = "\(exampleDirectory)/backups/journey.json.v1.2026-11-06.corrupted.json"
        let exampleBackup = SaveBackup(file: .journey, url: URL(fileURLWithPath: "\(exampleDirectory)/backups/journey.json.v1.2026-11-05.migration.json"))
        render(SaveRecoveryView(
            issues: [SaveRecoveryIssue(file: .journey, problem: .corrupted(backupPath: quarantinedPath), backups: [exampleBackup])],
            onRestore: { _ in }, onImport: { _ in }, onRestart: { _ in }, onRetry: {}, onQuit: {}
        ), size: CGSize(width: 760, height: 620), name: "save-recovery-corrupted", directory, model: model)
        render(SaveRecoveryView(
            issues: [SaveRecoveryIssue(file: .journey, problem: .tooNew(version: 2))],
            onRestore: { _ in }, onImport: { _ in }, onRestart: { _ in }, onRetry: {}, onQuit: {}
        ), size: CGSize(width: 760, height: 420), name: "save-recovery-too-new", directory, model: model)
    }

    /// The mail variants compose real content and a payoff entirely in memory.
    static func mailExamples(catalog: CityCatalog, now: Date, petName: String) -> JourneyState {
        let start = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        var care = CareState(petName: petName, species: .pigeon, hatchedAt: journey.startDate)
        for offset in 1...3 {
            let next = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            let day = journey.openDate
            journey.sync(today: DayUsage(date: DayKey.string(from: next)), finalized: [
                DayUsage(date: day, fuel: 13_400_000, byClient: ["codex": 8_300_000, "claude": 5_100_000]),
            ], catalog: catalog)
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog, wishTags: [])
            if offset == 1 {
                let first = journey.letters.first { $0.id == 1 }!
                CareEngine.reply(letterId: first.id, replyId: first.replyOptions[0].id, date: first.date, journey: &journey, care: &care)
            }
        }
        for index in journey.letters.indices {
            journey.letters[index].deliverAt = min(journey.letters[index].deliverAt, now)
            journey.letters[index].enrichmentDone = true
        }
        return journey
    }

    /// The collection and ritual fixtures share acquisitions and their original letters, entirely in memory.
    static func collectionExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        let start = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        var care = CareState(petName: petName, species: .pigeon, hatchedAt: journey.startDate)
        for offset in 1...5 {
            let next = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            let day = journey.openDate
            care.bag.todayItem = "sketchbook"
            journey.sync(today: DayUsage(date: DayKey.string(from: next)), finalized: [
                DayUsage(date: day, fuel: fuelPerKm, byClient: ["codex": fuelPerKm]),
            ], catalog: catalog)
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        }

        let rarities = ["common", "uncommon", "rare"]
        let souvenirs = rarities.map { rarity in
            catalog.items.all.first { $0.kind == "souvenir" && $0.cityId == nil && $0.rarity == rarity }!
        }
        for index in journey.letters.indices where journey.letters[index].kind == .daily {
            let id = journey.letters[index].id
            let item = souvenirs[min(id, 3) - 1]
            var rewards = StoryRewards()
            rewards.itemIds = [item.id]
            rewards.dropRarity = item.rarity
            if id > 3 { rewards.duplicateClueCityId = journey.letters[index].cityId }
            journey.letters[index].rewards = rewards
            journey.letters[index].read = false
            journey.letters[index].deliverAt = min(journey.letters[index].deliverAt, now)
            journey.letters[index].enrichmentDone = true
        }
        // Replaying saved story rewards gives each souvenir a real provenance without changing draw rules.
        care = CareState(petName: petName, species: .pigeon, hatchedAt: journey.startDate)
        CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        care.bag.todayItem = "sketchbook"
        if let index = care.souvenirs.firstIndex(where: { $0.id == souvenirs[2].id }) {
            care.souvenirs[index].shelved = true
        }
        return (journey, care)
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, name: String, _ directory: URL, model: AppModel) {
        let hosting = NSHostingView(rootView: view.localized(using: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .darkGray
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
