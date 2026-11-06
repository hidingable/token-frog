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
        guard !model.isLocked else {
            render(SaveRecoveryView(
                issues: model.recoveryIssues, error: model.recoveryError,
                onRestore: { _ in }, onImport: { _ in }, onRestart: { _ in }, onRetry: {}, onQuit: {}
            ), size: mainSize, name: "content-recovery", directory, model: model)
            return
        }

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

        let todayUsage = model.dashboardDays?.first { $0.date == DayKey.string(from: model.now) }?.usage
        func main(_ tab: MainTab, name: String, size: CGSize = mainSize, dashboard: DashboardSelection = DashboardSelection(), update: (inout JourneyState) -> Void = { _ in }) {
            model.withSnapshotState({ state in
                update(&state)
                if let todayUsage, let catalog = model.catalog { state.sync(today: todayUsage, catalog: catalog) }
            }) {
                model.navigate(to: tab)
                render(MainView(model: model, dashboard: dashboard), size: size, name: name, directory, model: model)
            }
        }

        if let catalog = model.catalog {
            let examples = homeExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = examples.care }) {
                main(.home, name: "main-home", update: { $0 = examples.journey })
                model.withSnapshotState({ $0 = examples.journey }) {
                    model.showProfile()
                    render(MainView(model: model), size: mainSize, name: "profile", directory, model: model)
                }
            }
            model.withSnapshotCare({ care in
                care = examples.care
                care.companionDays = [DayKey.string(from: model.now)]
                care.habits = .init()
            }) {
                model.showProfile()
                model.withSnapshotState({ state in
                    state = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: model.now), now: model.now, catalog: catalog)
                }) {
                    render(MainView(model: model), size: mainSize, name: "profile-empty", directory, model: model)
                }
            }
            for kind in BoxExample.allCases {
                let example = boxExamples(kind: kind, catalog: catalog, now: model.now, petName: model.petName)
                model.withSnapshotCare({ $0 = example.care }) {
                    model.withSnapshotState({ $0 = example.journey }) {
                        model.navigate(to: .home)
                        if kind == .souvenir {
                            render(MainView(model: model), size: mainSize, name: "main-home-no-mail", directory, model: model)
                        }
                        model.showBoxes()
                        if kind == .souvenir {
                            render(MainView(model: model), size: mainSize, name: "box-closed", directory, model: model)
                        }
                        model.openPresentedBox()
                        render(MainView(model: model), size: mainSize, name: "box-\(kind.rawValue)", directory, model: model)
                    }
                }
            }
            model.navigate(to: .home)
        }
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
        render(MainView(model: model), size: CGSize(width: 760, height: 620), name: "main-settings", directory, model: model)

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
        model.reactToFloatingClick()
        render(FloatingView(model: model), size: FloatingLayout.reactionSize(text: model.floatingWords), name: "floating-reaction", directory, model: model)
        model.endFloatingReaction()

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

    static func homeExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        var examples = collectionExamples(catalog: catalog, now: now, petName: petName)
        for offset in (-2)...0 {
            CareEngine.markCompanion(date: Calendar.current.date(byAdding: .day, value: offset, to: now)!, care: &examples.care)
        }
        examples.care.habits.talkative = 35
        examples.care.habits.observant = 15
        let learned = catalog.stories.all.compactMap(\.learned)
        for (index, text) in learned.prefix(5).enumerated() where index < examples.journey.letters.count {
            examples.journey.letters[index].learnedTexts = text
        }
        return examples
    }

    enum BoxExample: String, CaseIterable { case souvenir, bag, clue }

    static func boxExamples(kind: BoxExample, catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        var examples = homeExamples(catalog: catalog, now: now, petName: petName)
        for index in examples.journey.letters.indices { examples.journey.letters[index].read = true }
        let offset = (Calendar.current.component(.weekday, from: now) + 5) % 7
        let monday = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
        let key = DayKey.string(from: monday)
        if kind == .bag {
            examples.care.hatchedAt = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -21, to: monday)!)
        }
        if kind == .clue { examples.care.boxItemIndex = catalog.items.boxes.souvenirIds.count }
        examples.care.weekly.boxes = ["\(key)#\(kind == .bag ? 4 : 6)"]
        return examples
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
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.applyTheme(model.theme)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
