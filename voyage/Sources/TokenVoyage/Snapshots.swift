import AppKit
import SwiftUI
import VoyageCore

/// Renders every surface to PNG for offline visual checks: `TokenVoyage --snapshot <dir>`.
@MainActor
enum Snapshots {
    static func dashboardPages(model: AppModel) -> [(name: String, size: CGSize, selection: DashboardSelection)] {
        let wide = CGSize(width: 940, height: 1240)
        let peak = model.dashboardDays.map { UsageDashboard(days: $0, start: nil, end: DayKey.string(from: model.now)) }?.peak
        return [
            ("dashboard-month", wide, DashboardSelection(period: .month)),
            ("dashboard-all-codex", wide, DashboardSelection(period: .all, client: "codex")),
            ("dashboard-today-narrow", CGSize(width: 760, height: 1240), DashboardSelection(period: .today)),
            ("dashboard-peak-day", wide, DashboardSelection(day: peak?.date ?? DayKey.string(from: model.now), metric: .fuel, showModels: true)),
        ]
    }

    static func dashboardRequest(_ selection: DashboardSelection, model: AppModel) -> DashboardRequest {
        model.dashboardStore.request(selection: selection, seriesLimit: model.theme.series.count)
    }

    /// `write` holds the main actor, so dashboard results must be computed before it starts.
    static func prepareDashboards(model: AppModel) async {
        for page in dashboardPages(model: model) {
            await model.dashboardStore.select(dashboardRequest(page.selection, model: model))
        }
    }

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

        writePetForms(model: model, to: directory, metrics: metrics)

        let todayUsage = model.dashboardDays?.first { $0.date == DayKey.string(from: model.now) }?.usage
        func main(_ tab: MainTab, name: String, size: CGSize = mainSize, dashboard: DashboardSelection = DashboardSelection(), update: (inout JourneyState) -> Void = { _ in }) {
            model.withSnapshotState({ state in
                update(&state)
                if let todayUsage, let catalog = model.catalog {
                    state.sync(today: todayUsage, catalog: catalog, wishTags: model.care.map(WishEngine.tags) ?? [])
                }
            }) {
                model.navigate(to: tab)
                render(MainView(model: model, dashboard: dashboard), size: size, name: name, directory, model: model)
            }
        }

        if let catalog = model.catalog {
            let examples = homeExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = examples.care }) {
                main(.home, name: "main-home", update: { $0 = examples.journey })
                main(.home, name: "home-wish-empty", size: CGSize(width: 760, height: 1000), update: { $0 = examples.journey })
                model.withSnapshotCare({ care in
                    let text = model.l10n("snapshot.wishWritten")
                    WishEngine.write(text, tags: ["coast", "food", "art"], at: model.now, care: &care)
                }) {
                    main(.home, name: "home-wish-written", size: CGSize(width: 760, height: 1000), update: { $0 = examples.journey })
                }
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
        main(.journey, name: "main-journey", size: CGSize(width: 760, height: 1080))
        if let catalog = model.catalog {
            let example = journeyExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = example.care }) {
                model.withSnapshotState({ $0 = example.journey }) {
                    model.navigate(to: .journey)
                    render(MainView(model: model), size: CGSize(width: 760, height: 1080), name: "journey-footprints", directory, model: model)
                    render(NotchExpandedView(model: model, metrics: metrics), size: metrics.expandedSize, name: "notch-road-clue", directory, model: model)
                }
            }
            let empty = journeyExamples(catalog: catalog, now: model.now, petName: model.petName, empty: true)
            model.withSnapshotCare({ $0 = empty.care }) {
                model.withSnapshotState({ $0 = empty.journey }) {
                    model.navigate(to: .journey)
                    render(MainView(model: model), size: CGSize(width: 760, height: 1080), name: "journey-footprints-empty", directory, model: model)
                }
            }
        }
        model.mailFilter = .all
        model.selectedLetterID = nil
        main(.mail, name: "main-mail")
        if let catalog = model.catalog {
            let examples = mailExamples(catalog: catalog, now: model.now, petName: model.petName)
            let unmatched = wishMailExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = unmatched.care }) {
                model.selectedLetterID = unmatched.journey.letters.last?.id
                main(.mail, name: "mail-wish-unmatched", size: CGSize(width: 760, height: 1000), update: { $0 = unmatched.journey })
            }
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
            let companion = companionMailExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = companion.care }) {
                for (kind, name) in [(Letter.Kind.postcard, "mail-postcard"), (.reunion, "mail-reunion")] {
                    model.selectedLetterID = companion.journey.letters.first { $0.kind == kind }?.id
                    main(.mail, name: name, update: { $0 = companion.journey })
                }
                model.selectedLetterID = companion.journey.letters.last { $0.kind == .daily }?.id
                main(.mail, name: "mail-numbered", update: { $0 = companion.journey })
                model.collectionTab = .memories
                main(.collection, name: "collection-memory-citations", size: CGSize(width: 760, height: 1240), update: { $0 = companion.journey })
            }
            model.selectedLetterID = nil
            let weekly = weeklyMailExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.withSnapshotCare({ $0 = weekly.care }) {
                for filter in MailFilter.allCases {
                    model.mailFilter = filter
                    model.selectedLetterID = nil
                    let size = CGSize(width: 760, height: filter == .all ? 1600 : filter == .travel ? 1240 : 780)
                    main(.mail, name: "mail-filter-\(filter.rawValue)", size: size, update: { $0 = weekly.journey })
                    main(.mail, name: "mail-filter-\(filter.rawValue)-empty", update: { $0.letters = [] })
                }
                model.mailFilter = .weekly
                main(.mail, name: "mail-weekly", update: { $0 = weekly.journey })
                let quiet = weeklyMailExamples(catalog: catalog, now: model.now, petName: model.petName, quiet: true)
                main(.mail, name: "mail-weekly-quiet", update: { $0 = quiet.journey })
            }
            model.mailFilter = .all
        }
        model.collectionTab = .passport
        main(.collection, name: "collection-passport", size: CGSize(width: 760, height: 620))
        if let catalog = model.catalog {
            for tea in [true, false] {
                let example = usageEventExamples(catalog: catalog, now: model.now, petName: model.petName, tea: tea)
                model.withSnapshotCare({ $0 = example.care }) {
                    model.withSnapshotState({ $0 = example.journey }) {
                        model.selectedLetterID = example.journey.letters.last?.id
                        model.navigate(to: .mail)
                        render(MainView(model: model), size: CGSize(width: 760, height: 1200), name: tea ? "mail-usage-tea" : "mail-first-voyage", directory, model: model)
                        model.collectionTab = .passport
                        model.navigate(to: .collection)
                        render(MainView(model: model), size: CGSize(width: 760, height: 720), name: tea ? "tickets-empty" : "tickets", directory, model: model)
                    }
                }
            }
            let night = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: model.now)!
            var example = homeExamples(catalog: catalog, now: night, petName: model.petName)
            var observer = NightWorkObserver()
            let key = DayKey.string(from: night)
            observer.observe(DayUsage(date: key, fuel: 10), at: night.addingTimeInterval(-60), journey: &example.journey, content: catalog.usageEvents)
            observer.observe(DayUsage(date: key, fuel: 20), at: night, journey: &example.journey, content: catalog.usageEvents)
            model.withSnapshotTime(night) {
                model.withSnapshotCare({ $0 = example.care }) {
                    model.withSnapshotState({ $0 = example.journey }) {
                        model.navigate(to: .home)
                        render(MainView(model: model), size: CGSize(width: 1000, height: 900), name: "home-nightcap", directory, model: model)
                        render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-nightcap", directory, model: model)
                        render(FloatingView(model: model), size: FloatingLayout.size, name: "floating-nightcap", directory, model: model)
                    }
                }
            }
            model.selectedLetterID = nil
        }
        if let catalog = model.catalog {
            let memories = memoryExamples(catalog: catalog, now: model.now, petName: model.petName)
            model.collectionTab = .memories
            model.withSnapshotCare({ $0 = memories.care }) {
                main(.collection, name: "collection-memories", size: CGSize(width: 760, height: 1040), update: { $0 = memories.journey })
            }
            model.withSnapshotCare({ care in
                care = memories.care
                care.memories = []
                care.specialDays = []
            }) {
                main(.collection, name: "collection-memories-empty", size: CGSize(width: 760, height: 620), update: { $0 = memories.journey })
            }
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
        let settingsSize = CGSize(width: 760, height: 2100)
        render(MainView(model: model), size: settingsSize, name: "settings-full", directory, model: model)
        model.notifications.withSnapshotAuthorization(.denied) {
            render(MainView(model: model), size: settingsSize, name: "settings-denied", directory, model: model)
        }
        let previousArchiveError = model.archiveError
        model.archiveError = SaveArchiveError.invalidArchive
        render(MainView(model: model), size: settingsSize, name: "import-error", directory, model: model)
        model.archiveError = previousArchiveError
        model.navigate(to: .home)
        model.withSnapshotUsage(.noUsage) {
            render(MainView(model: model), size: mainSize, name: "home-no-usage", directory, model: model)
        }
        model.withSnapshotUsage(.failed) {
            render(MainView(model: model), size: mainSize, name: "usage-failed", directory, model: model)
        }

        model.dataTab = .dashboard
        for page in dashboardPages(model: model) {
            model.dashboardStore.showCached(dashboardRequest(page.selection, model: model))
            main(.data, name: page.name, size: page.size, dashboard: page.selection)
        }
        model.dataTab = .quota
        main(.data, name: "quota-empty", size: CGSize(width: 760, height: 720))
        model.quotaRuntime.withSnapshotAccounts(quotaExamples(now: model.now)) {
            main(.data, name: "quota-linked", size: CGSize(width: 760, height: 780))
            render(AccountsView(model: model).padding(12), size: CGSize(width: 760, height: 850), name: "accounts", directory, model: model)
        }

        render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-collapsed", directory, model: model)
        model.withSnapshotState({ state in
            state.legCost = max(state.legCost, 12 * fuelPerKm)
            state.legFuel = state.legCost - 12 * fuelPerKm
            for index in state.letters.indices { state.letters[index].read = true }
        }) {
            render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-near-arrival", directory, model: model)
        }
        if let catalog = model.catalog, let longest = catalog.active.max(by: { model.l10n.cityName($0).count < model.l10n.cityName($1).count }) {
            model.withSnapshotState({ state in
                state.targetCityId = longest.id
                state.legCost = max(state.legCost, 500 * fuelPerKm)
                state.legFuel = 0
            }) {
                render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-long-destination", directory, model: model)
            }
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

    private static func writePetForms(model: AppModel, to directory: URL, metrics: NotchMetrics) {
        guard let catalog = model.catalog else { return }
        render(PetFormsOverview(catalog: catalog.pets), size: CGSize(width: 780, height: 960), name: "pet-forms", directory, model: model)
        render(PetFormsOverview(catalog: catalog.pets, nightcap: true), size: CGSize(width: 600, height: 960), name: "pet-nightcaps", directory, model: model)
        let example = homeExamples(catalog: catalog, now: model.now, petName: model.petName)
        for days in [5, 20] {
            let form = PetForm.current(companionDays: days)
            model.withSnapshotCare({ care in
                care = example.care
                care.companionDays = (0..<days).map { "snapshot-\($0)" }
                care.seenPetStages = ["juvenile", "teen"]
                care.roomPlacements = nil
                var owned = Set(care.souvenirs.map(\.id))
                for item in catalog.items.all where item.kind == "souvenir" && owned.count < 8 {
                    if owned.insert(item.id).inserted {
                        care.souvenirs.append(.init(id: item.id, letterId: nil, boxId: nil, shelved: false))
                    }
                }
            }) {
                model.withSnapshotState({ $0 = example.journey }) {
                    model.showProfile()
                    render(MainView(model: model), size: CGSize(width: 760, height: 900), name: "profile-\(form.rawValue)", directory, model: model)
                    render(FloatingView(model: model), size: FloatingLayout.normalSize(form: form), name: "floating-\(form.rawValue)", directory, model: model)
                    render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-\(form.rawValue)", directory, model: model)
                    model.openPostOffice()
                    render(MainView(model: model), size: CGSize(width: 1000, height: 900), name: "home-\(form.rawValue)-empty", directory, model: model)
                    if days == 20 {
                        model.withSnapshotCare({ care in
                            let ids = care.souvenirs.map(\.id)
                            for (slot, id) in zip(RoomSlot.allCases, ids) { RoomDecor.place(id, in: slot, care: &care, library: catalog.items) }
                        }) {
                            render(MainView(model: model), size: CGSize(width: 1000, height: 900), name: "home-teen-full", directory, model: model)
                            model.showRoomArrangement()
                            render(MainView(model: model), size: CGSize(width: 760, height: 1160), name: "room-arrangement", directory, model: model)
                        }
                    }
                    model.withSnapshotCare({ $0.seenPetStages = days == 5 ? [] : ["juvenile"] }) {
                        model.setMainWindowPresented(true)
                        model.openPostOffice()
                        render(MainView(model: model), size: CGSize(width: 760, height: 780), name: "moment-\(form.rawValue)", directory, model: model)
                        model.setMainWindowPresented(false)
                    }
                }
            }
        }
        model.openPostOffice()
    }

    static func quotaExamples(now: Date) -> [QuotaSource: QuotaAccountState] {
        let old = now.addingTimeInterval(-3600)
        let low = QuotaReading(providerID: "codex", windows: [
            QuotaWindow(kind: .session, remainingPercent: 12, resetsAt: now.addingTimeInterval(7200)),
            QuotaWindow(kind: .weekly, remainingPercent: 55, resetsAt: now.addingTimeInterval(259200)),
        ], readAt: now)
        let stale = QuotaReading(providerID: "claude", windows: [
            QuotaWindow(kind: .session, remainingPercent: 38, resetsAt: now.addingTimeInterval(3600)),
            QuotaWindow(kind: .weekly, remainingPercent: 72, resetsAt: now.addingTimeInterval(432000)),
        ], readAt: old)
        return [
            .codex: QuotaAccountState(linked: true, status: .ok, readings: [low]),
            .claude: QuotaAccountState(linked: true, status: .stale(lastGoodAt: old), readings: [stale], failure: .unavailable(.network)),
            .otherTools: QuotaAccountState(linked: true, status: .expired),
        ]
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

    static func journeyExamples(catalog: CityCatalog, now: Date, petName: String, empty: Bool = false) -> (journey: JourneyState, care: CareState) {
        if empty {
            let journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: catalog)
            return (journey, CareState(petName: petName, species: journey.pet, hatchedAt: journey.startDate))
        }
        var example = memoryExamples(catalog: catalog, now: now, petName: petName)
        let stops = ["quanzhou", "fukuoka", "quanzhou"]
        for index in example.journey.letters.indices where example.journey.letters[index].kind == .daily {
            let city = stops[(example.journey.letters[index].id - 1) % stops.count]
            example.journey.letters[index].cityId = city
            example.journey.letters[index].arrivals = [city]
            example.journey.letters[index].transitTargetId = nil
        }
        example.journey.route = ["shanghai"] + stops
        example.journey.currentCityId = "quanzhou"
        example.journey.targetCityId = "shanghai"
        example.journey.legFrom = catalog.city("quanzhou").coordinate
        example.journey.legTo = catalog.city("shanghai").coordinate
        example.journey.legCost = JourneyState.cost(from: catalog.city("quanzhou"), to: catalog.city("shanghai"))
        example.journey.legFuel = 0
        let key = DayKey.string(from: now)
        // Use the real engine to obtain a populated observation, independent of the snapshot date.
        for seed in UInt32(0)..<64 {
            var probe = JourneyState(seed: seed, startCityId: "shanghai", date: key, now: now, catalog: catalog)
            probe.sync(today: DayUsage(date: key, fuel: 1), catalog: catalog)
            if let decision = probe.days[key]?.roadClueDecision, decision.clue != nil {
                example.journey.seed = seed
                example.journey.days[key, default: DayRecord()].roadClueDecision = decision
                example.journey.days[key]?.fuel = 1
                break
            }
        }
        return example
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
        memoryExamples(catalog: catalog, now: now, petName: petName).journey
    }

    static func wishMailExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        var example = homeExamples(catalog: catalog, now: now, petName: petName)
        WishEngine.write("blorble blorble", tags: [], at: now, care: &example.care)
        var letter = example.journey.letters.last { $0.kind == .daily }!
        letter.id = (example.journey.letters.map(\.id).max() ?? 0) + 1
        letter.storyId = nil
        letter.storyVersion = nil
        letter.texts = [:]
        letter.deliverAt = now
        letter.enrichmentDone = true
        example.journey.letters.append(letter)
        CareEngine.process(journey: &example.journey, care: &example.care, stories: catalog.stories, catalog: catalog,
                           wishTags: WishEngine.tags(in: example.care))
        return example
    }

    static func usageEventExamples(catalog: CityCatalog, now: Date, petName: String, tea: Bool) -> (journey: JourneyState, care: CareState) {
        let start = Calendar.current.date(byAdding: .day, value: -15, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        // This fixture represents a previously used tool without a collectible ticket.
        journey.usageEvents?.seenTools = ["codex"]
        var care = CareState(petName: petName, species: journey.pet, hatchedAt: journey.startDate)
        for offset in 1...15 {
            let fuel = tea && offset == 15 ? 3_000_000 : 1_000_000
            let tool = !tea && offset == 15 ? "claude-code" : "codex"
            let next = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            journey.sync(today: DayUsage(date: DayKey.string(from: next)), finalized: [
                DayUsage(date: journey.openDate, fuel: fuel, byClient: [tool: fuel]),
            ], catalog: catalog)
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        }
        for index in journey.letters.indices {
            journey.letters[index].deliverAt = min(journey.letters[index].deliverAt, now)
            journey.letters[index].enrichmentDone = true
        }
        return (journey, care)
    }

    static func memoryExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        let start = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        var care = CareState(petName: petName, species: catalog.pets.defaultID, hatchedAt: journey.startDate)
        for offset in 1...3 {
            let next = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            let day = journey.openDate
            journey.sync(today: DayUsage(date: DayKey.string(from: next)), finalized: [
                DayUsage(date: day, fuel: 13_400_000, byClient: ["codex": 8_300_000, "claude": 5_100_000]),
            ], catalog: catalog)
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
            if offset == 1 {
                let first = journey.letters.first { $0.id == 1 }!
                CareEngine.reply(letterId: first.id, replyId: first.replyOptions[0].id, date: first.date, journey: &journey, care: &care)
            }
        }
        for index in journey.letters.indices {
            journey.letters[index].deliverAt = min(journey.letters[index].deliverAt, now)
            journey.letters[index].enrichmentDone = true
        }
        return (journey, care)
    }

    static func companionMailExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        let opened = Calendar.current.date(byAdding: .day, value: -4, to: now)!
        var examples = memoryExamples(catalog: catalog, now: opened, petName: petName)
        CareEngine.open(at: opened, journey: &examples.journey, care: &examples.care, catalog: catalog)
        let activeDay = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        examples.journey.sync(today: DayUsage(date: DayKey.string(from: now)), finalized: [
            DayUsage(date: DayKey.string(from: activeDay), fuel: 100, byClient: ["codex": 100]),
        ], catalog: catalog)
        CareEngine.process(journey: &examples.journey, care: &examples.care, stories: catalog.stories, catalog: catalog)
        CareEngine.open(at: now, journey: &examples.journey, care: &examples.care, catalog: catalog)
        return examples
    }

    static func weeklyMailExamples(catalog: CityCatalog, now: Date, petName: String, quiet: Bool = false) -> (journey: JourneyState, care: CareState) {
        let calendar = Calendar.current
        let sunday = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: now) - 1), to: now)!
        let start = calendar.date(byAdding: .day, value: -13, to: sunday)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        var care = CareState(petName: petName, species: catalog.pets.defaultID, hatchedAt: journey.startDate)
        for offset in 1...13 {
            let day = journey.openDate
            if offset == 10 { CareEngine.open(at: DayKey.date(from: day)!, journey: &journey, care: &care, catalog: catalog) }
            let fuel = quiet || offset == 10 ? 0 : (offset <= 7 ? 8_000_000 : 10_000_000)
            let next = calendar.date(byAdding: .day, value: offset, to: start)!
            journey.sync(today: DayUsage(date: DayKey.string(from: next)), finalized: [
                DayUsage(date: day, fuel: fuel, byClient: fuel == 0 ? [:] : ["codex": fuel * 3 / 4, "claude": fuel / 4]),
            ], catalog: catalog)
            CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
            if !quiet, offset == 8, let letter = journey.letters.last, let reply = letter.replyOptions.first {
                CareEngine.reply(letterId: letter.id, replyId: reply.id, date: letter.date, journey: &journey, care: &care)
            }
        }
        CareEngine.open(at: sunday, journey: &journey, care: &care, catalog: catalog)
        CareEngine.writeWeeklyMail(journey: &journey, catalog: catalog)
        journey.sync(today: DayUsage(date: DayKey.string(from: now)), catalog: catalog)
        CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        for index in journey.letters.indices {
            journey.letters[index].deliverAt = min(journey.letters[index].deliverAt, now)
            journey.letters[index].enrichmentDone = true
        }
        return (journey, care)
    }

    /// The collection and ritual fixtures share acquisitions and their original letters, entirely in memory.
    static func collectionExamples(catalog: CityCatalog, now: Date, petName: String) -> (journey: JourneyState, care: CareState) {
        let start = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        var journey = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: start), now: start, catalog: catalog)
        var care = CareState(petName: petName, species: catalog.pets.defaultID, hatchedAt: journey.startDate)
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
            catalog.items.all.first { $0.kind == "souvenir" && $0.source == nil && $0.cityId == nil && $0.rarity == rarity }!
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
        care = CareState(petName: petName, species: catalog.pets.defaultID, hatchedAt: journey.startDate)
        CareEngine.process(journey: &journey, care: &care, stories: catalog.stories, catalog: catalog)
        care.bag.todayItem = "sketchbook"
        if let index = care.souvenirs.firstIndex(where: { $0.id == souvenirs[2].id }) {
            care.souvenirs[index].shelved = true
        }
        return (journey, care)
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, name: String, _ directory: URL, model: AppModel) {
        autoreleasepool {
            let hosting = NSHostingView(rootView: view.localized(using: model))
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.applyTheme(model.theme)
            window.contentView = hosting
            // Lazy stacks need a visible viewport before AppKit caches their display.
            window.orderFront(nil)
            defer {
                // Hidden hosting roots must not observe the next snapshot's model and re-enter layout.
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            hosting.layoutSubtreeIfNeeded()
            guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: representation)
            try? representation.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
