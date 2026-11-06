import Foundation
import Observation
import VoyageCore

/// An uncommitted first launch. No store or mileage ledger is reachable from this object.
@MainActor
@Observable
final class OnboardingFlow {
    enum Step: Int, CaseIterable { case eggs = 1, home, hatch, logbook, depart }
    enum NameProblem { case empty, tooLong }
    typealias UsageReader = @Sendable (_ since: String, _ until: String) async throws -> (days: [DayDetail], hours: [HourUsage])

    let catalog: CityCatalog
    let seed: UInt32
    let date: String
    let calendar: Calendar
    private(set) var step: Step = .eggs
    private(set) var species: PetID?
    var homeCityId = "shanghai"
    var search = ""
    var petName = ""
    private(set) var todayItem: String?
    private(set) var logbook: Logbook?
    private(set) var isReading = false
    private(set) var hatchFrame = 0
    private var didRead = false
    private var letterFixed = false
    @ObservationIgnored private var readingTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let readUsage: UsageReader
    private let readTimeout: Duration

    init(catalog: CityCatalog, seed: UInt32, today: Date, calendar: Calendar = .current,
         readTimeout: Duration = .seconds(120), readUsage: @escaping UsageReader = OnboardingFlow.readLocalUsage) {
        self.catalog = catalog
        self.seed = seed
        self.calendar = calendar
        date = DayKey.string(from: today, calendar: calendar)
        self.readTimeout = readTimeout
        self.readUsage = readUsage
    }

    static func readLocalUsage(since: String, until: String) async throws -> (days: [DayDetail], hours: [HourUsage]) {
        try Task.checkCancellation()
        let days = try await UsageSource.fetch(since: since, until: until)
        try Task.checkCancellation()
        let hours = try await UsageSource.fetchHours(since: since, until: until)
        return (days, hours)
    }

    func startReading() {
        guard !didRead, !letterFixed else { return }
        didRead = true
        isReading = true
        let last = DayKey.date(from: date, calendar: calendar)!
        let first = calendar.date(byAdding: .day, value: -29, to: last)!
        let since = DayKey.string(from: first, calendar: calendar)
        let until = date
        let reader = readUsage
        readingTask = Task { [weak self] in
            do {
                let result = try await reader(since, until)
                guard let self, !Task.isCancelled, !self.letterFixed else { return }
                // graph can omit quiet days. Include them in the weekend denominator.
                let recorded = Dictionary(result.days.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
                var key = since
                var days: [DayDetail] = []
                for _ in 0..<30 {
                    days.append(recorded[key] ?? DayDetail(date: key, rows: []))
                    key = DayKey.next(key, calendar: self.calendar)
                }
                self.logbook = Logbook.summarize(days: days, hours: result.hours, calendar: self.calendar)
                self.finishReading()
            } catch {
                guard let self, !self.letterFixed else { return }
                self.finishReading()
            }
        }
        timeoutTask = Task { [weak self, readTimeout] in
            do { try await Task.sleep(for: readTimeout) } catch { return }
            guard let self, !self.letterFixed else { return }
            self.readingTask?.cancel()
            self.finishReading()
        }
    }

    private func finishReading() {
        isReading = false
        letterFixed = true
        timeoutTask?.cancel()
    }

    var eggs: [PetDefinition] { catalog.pets.all }

    func selectEgg(_ pet: PetID) {
        guard step == .eggs, catalog.pets.find(pet) != nil else { return }
        species = pet
    }

    func cities(l10n: L10n) -> [City] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.active.filter { city in
            query.isEmpty || ["zh-Hans", "en"].contains { language in
                city.names[language]?.range(of: query, options: .caseInsensitive) != nil
            }
        }.sorted { l10n.cityName($0).compare(l10n.cityName($1), locale: l10n.locale) == .orderedAscending }
    }

    var trimmedName: String { petName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var nameProblem: NameProblem? {
        if trimmedName.isEmpty { return .empty }
        if trimmedName.count > 12 { return .tooLong }
        return nil
    }
    var canContinue: Bool {
        switch step {
        case .eggs: species != nil
        case .home: catalog.find(homeCityId)?.status == "active"
        case .hatch: nameProblem == nil
        case .logbook, .depart: true
        }
    }

    func advance(l10n: L10n) {
        guard canContinue else { return }
        switch step {
        case .eggs: step = .home
        case .home:
            petName = l10n.defaultPetName(species!, catalog: catalog.pets)
            step = .hatch
        case .hatch: step = .logbook
        case .logbook:
            if isReading { logbook = nil }
            readingTask?.cancel()
            finishReading()
            step = .depart
        case .depart: break
        }
    }

    func hatch() async {
        guard step == .hatch, hatchFrame == 0 else { return }
        for frame in 1...2 {
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard hatchFrame < 2 else { return }
            hatchFrame = frame
        }
    }

    func skipHatching() { hatchFrame = 2 }

    func toggleItem(_ id: String) {
        guard CareState.Bag().owned.contains(id) else { return }
        todayItem = todayItem == id ? nil : id
    }

    var preview: JourneyState {
        JourneyState(seed: seed, startCityId: homeCityId, pet: species ?? catalog.pets.defaultID, date: date, logbook: logbook, catalog: catalog)
    }

    func saves(now: Date) -> (journey: JourneyState, care: CareState)? {
        guard step == .depart, let species, nameProblem == nil else { return nil }
        let journey = JourneyState(seed: seed, startCityId: homeCityId, pet: species, date: date, now: now, logbook: logbook, catalog: catalog)
        var care = CareState(petName: trimmedName, species: species, hatchedAt: date, calendar: calendar)
        care.bag.todayItem = todayItem
        CareEngine.markCompanion(date: date, care: &care, calendar: calendar)
        return (journey, care)
    }

    /// Snapshot examples never start a reader or obtain a save store.
    static func snapshot(catalog: CityCatalog, today: Date, l10n: L10n, step: Step, welcome: Bool) -> OnboardingFlow {
        let flow = OnboardingFlow(catalog: catalog, seed: 42, today: today, readUsage: { _, _ in ([], []) })
        if step != .eggs { flow.selectEgg(catalog.pets.defaultID) }
        while flow.step != step { flow.advance(l10n: l10n) }
        flow.hatchFrame = 2
        flow.didRead = true
        flow.letterFixed = true
        flow.logbook = welcome ? nil : Logbook(workdayStartHour: 9, weekendActivePercent: 25, topClients: ["codex", "claude"])
        return flow
    }
}
