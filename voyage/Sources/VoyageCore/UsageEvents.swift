import Foundation

/// Literal bilingual text, frozen when the event happens rather than looked up when it is read.
public struct UsageEventNote: Codable, Equatable, Sendable {
    public var id: String
    public var contentVersion: Int
    public var texts: [String: String]
}

public struct ToolTicket: Codable, Equatable, Sendable {
    public var toolID: String
    public var date: String
}

public struct NightcapEvent: Codable, Equatable, Sendable {
    public var date: String
    public var observedAt: Date
    public var note: UsageEventNote
}

/// Presentation only. None of these records enter the care or reward engines.
public struct UsageEvents: Codable, Equatable, Sendable {
    public var eligibleFrom: String
    public var seenTools: [String] = []
    public var tickets: [ToolTicket] = []
    public var pendingTea: UsageEventNote?
    public var pendingFirstVoyage: UsageEventNote?
    public var pendingFirstVoyageTicket: ToolTicket?
    public var nightcapWeeks: [String] = []
    public var nightcap: NightcapEvent?

    public init(eligibleFrom: String) { self.eligibleFrom = eligibleFrom }
}

public struct UsageEventContent: Codable, Sendable {
    struct Line: Codable, Sendable {
        var id: String
        var texts: [String: String]
    }
    var version: Int
    var tea: [Line]
    var nightcap: [Line]
    var firstVoyage: [Line]

    static func load(directory: URL) throws -> Self {
        let content = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("usage-events.json")))
        let groups = [content.tea, content.nightcap, content.firstVoyage]
        let lines = groups.flatMap { $0 }
        guard content.version > 0, groups.allSatisfy({ $0.count >= 4 }),
              Set(lines.map(\.id)).count == lines.count,
              lines.allSatisfy({ line in
                  !line.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Language.allCases.allSatisfy {
                      guard let text = line.texts[$0.rawValue] else { return false }
                      let literal = text.replacingOccurrences(of: "{tool}", with: "")
                      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !literal.contains("{") && !literal.contains("}")
                          && (text.contains("{tool}") == (line.texts["en"]?.contains("{tool}") == true))
                  }
              }),
              (content.tea + content.nightcap).allSatisfy({ !$0.texts.values.contains { $0.contains("{tool}") } }),
              content.firstVoyage.allSatisfy({ $0.texts.values.allSatisfy { $0.contains("{tool}") } }) else {
            throw ContentValidationError(issues: [.init(file: "usage-events.json", rule: "usageEvents", message: "Each event needs at least four unique, complete bilingual lines with supported slots")])
        }
        return content
    }

    func note(_ kind: String, seed: UInt32, date: String, tool: String? = nil) -> UsageEventNote {
        let lines: [Line]
        switch kind {
        case "tea": lines = tea
        case "nightcap": lines = nightcap
        default: lines = firstVoyage
        }
        // A private stream makes adding copy independent of story, drop and destination randomness.
        var random = SplitMix64(seed: seed, stopCount: Int(date.replacingOccurrences(of: "-", with: ""))!, salt: .usageEvent)
        for byte in (kind + (tool ?? "")).utf8 { random.state = (random.state ^ UInt64(byte)) &* 0x100000001b3 }
        let ordered = lines.sorted { $0.id < $1.id }
        let line = ordered[Int(random.next() % UInt64(ordered.count))]
        return UsageEventNote(id: line.id, contentVersion: version, texts: line.texts.mapValues {
            $0.replacingOccurrences(of: "{tool}", with: tool.map(Vehicle.toolName) ?? "")
        })
    }
}

extension JourneyState {
    /// Activate before catch-up. Existing tools are a baseline, including those only in old letters.
    public mutating func enableUsageEvents(on date: String) {
        guard usageEvents == nil else { return }
        var events = UsageEvents(eligibleFrom: date)
        let clients = days.values.flatMap { $0.byClient.filter { $0.value > 0 }.map(\.key) }
            + letters.flatMap { $0.vehicles.map(\.client) }
        events.seenTools = Set(clients.map(Vehicle.normalizeClientID).filter { !$0.isEmpty }).sorted()
        usageEvents = events
    }

    mutating func recordFirstVoyages(_ usage: DayUsage, content: UsageEventContent) {
        guard var events = usageEvents else { return }
        let clients = Set(usage.usedToolIDs.map(Vehicle.normalizeClientID)).sorted()
        for client in clients where !client.isEmpty && !events.seenTools.contains(client) {
            events.seenTools.append(client)
            let ticket = ToolTicket(toolID: client, date: usage.date)
            events.tickets.append(ticket)
            let earlier = events.pendingFirstVoyageTicket.map {
                ticket.date < $0.date || (ticket.date == $0.date && ticket.toolID < $0.toolID)
            } ?? false
            if events.pendingFirstVoyage == nil || earlier {
                events.pendingFirstVoyage = content.note("firstVoyage", seed: seed, date: usage.date, tool: client)
                events.pendingFirstVoyageTicket = ticket
            }
        }
        events.seenTools.sort()
        events.tickets.sort { $0.date == $1.date ? $0.toolID < $1.toolID : $0.date < $1.date }
        usageEvents = events
    }

    mutating func settleUsageEvents(_ usage: DayUsage, content: UsageEventContent) {
        days[usage.date, default: DayRecord()].finalUsageFuel = usage.fuel
        guard let events = usageEvents, usage.date >= events.eligibleFrom else { return }
        var values: [Int] = []
        for entry in days.filter({ $0.key < usage.date && $0.key < openDate }).sorted(by: { $0.key > $1.key }) {
            // An unknown final cannot be skipped in favor of an older sample: it may be active.
            guard let final = entry.value.finalUsageFuel else { return }
            if final > 0 { values.append(final) }
            if values.count == 14 { break }
        }
        values.sort()
        guard values.count == 14, usage.fuel > values[6], usage.fuel - values[6] > values[7] else { return }
        if usageEvents?.pendingTea == nil {
            usageEvents?.pendingTea = content.note("tea", seed: seed, date: usage.date)
        }
    }

    mutating func takeUsageEventNotes() -> [UsageEventNote]? {
        let notes = [usageEvents?.pendingTea, usageEvents?.pendingFirstVoyage].compactMap { $0 }
        usageEvents?.pendingTea = nil
        usageEvents?.pendingFirstVoyage = nil
        usageEvents?.pendingFirstVoyageTicket = nil
        return notes.isEmpty ? nil : notes
    }

    public func nightcapNote(at now: Date, calendar: Calendar = .current) -> UsageEventNote? {
        guard let night = usageEvents?.nightcap, now >= night.observedAt else { return nil }
        let start = calendar.startOfDay(for: night.observedAt)
        let endDay = calendar.component(.hour, from: night.observedAt) >= 23
            ? calendar.date(byAdding: .day, value: 1, to: start)! : start
        let end = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: endDay)!
        return now < end ? night.note : nil
    }
}

/// Session-local scan baseline: restarting, importing a save or waking never replays offline work.
public struct NightWorkObserver: Sendable {
    private var previous: DayUsage?
    public init() {}

    public mutating func observe(_ usage: DayUsage, at now: Date, journey: inout JourneyState,
                                 content: UsageEventContent, calendar: Calendar = .current) {
        guard usage.date == DayKey.string(from: now, calendar: calendar) else { previous = nil; return }
        let baseline = previous
        previous = usage
        if let baseline, baseline.date == usage.date {
            previous?.observedTokens = max(baseline.observedTokens, usage.observedTokens)
        }
        guard let baseline, usage.date >= baseline.date,
              usage.observedTokens > (usage.date == baseline.date ? baseline.observedTokens : 0),
              calendar.component(.hour, from: now) >= 23 || calendar.component(.hour, from: now) < 5 else { return }
        journey.enableUsageEvents(on: usage.date)
        let offset = (calendar.component(.weekday, from: now) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -offset, to: now)!
        let week = DayKey.string(from: monday, calendar: calendar)
        guard !journey.usageEvents!.nightcapWeeks.contains(week) else { return }
        journey.usageEvents?.nightcapWeeks.append(week)
        journey.usageEvents?.nightcap = NightcapEvent(date: usage.date, observedAt: now,
            note: content.note("nightcap", seed: journey.seed, date: usage.date))
    }
}
