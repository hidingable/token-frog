import SwiftUI
import VoyageCore

enum MemoryCategory: CaseIterable, Identifiable {
    case replies, learned, special
    var id: Self { self }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .replies: l10n("memory.replies")
        case .learned: l10n("memory.learned")
        case .special: l10n("memory.special")
        }
    }

    func empty(_ l10n: L10n) -> String {
        switch self {
        case .replies: l10n("memory.repliesEmpty")
        case .learned: l10n("memory.learnedEmpty")
        case .special: l10n("memory.specialEmpty")
        }
    }
}

struct MemoryBookDisplay {
    struct Entry: Identifiable {
        let id: String
        let category: MemoryCategory
        let date: String
        let text: String
        let location: String?
        let letterId: Int?
        var cause: String?
        var sourceLetterId: Int?
        var citedLetterIds: [Int] = []
        var sponsorTags: [String] = []
    }

    let entries: [Entry]

    init(journey: JourneyState, care: CareState, now: Date, l10n: L10n, catalog: CityCatalog) {
        // Save validation does not guarantee unique letter IDs, so a damaged import must not trap here.
        let letters = Dictionary(journey.letters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func replyText(_ memory: CareState.Memory) -> String? {
            letters[memory.letterId]?.replyOptions.first { $0.id == memory.replyId }
                .flatMap { LetterComposer.localized($0.text, l10n: l10n) }
        }
        func location(_ letter: Letter?) -> String? {
            letter.map { l10n.cityName(catalog.city($0.cityId)) }
        }
        func visible(_ letter: Letter?) -> Bool { letter.map { $0.deliverAt <= now } ?? true }

        var entries: [Entry] = []
        // M1 memories retain event order, including replies to an older letter made later.
        // Pair promises in that order, so repeated reply IDs and backlogs keep their true cause.
        var pending: [CareState.Memory] = []
        for memory in care.memories {
            let letter = letters[memory.letterId]
            switch memory.kind {
            case "reply":
                pending.append(memory)
                guard visible(letter) else { continue }
                entries.append(Entry(id: "reply:\(memory.letterId)", category: .replies, date: memory.date,
                                     text: replyText(memory).map { l10n("memory.youSaid", $0) } ?? l10n("memory.unavailable"),
                                     location: location(letter), letterId: letter?.id))
            case "fulfilled":
                let source = pending.firstIndex { $0.replyId == memory.replyId }.map { pending.remove(at: $0) }
                guard visible(letter) else { continue }
                let learned = letter.flatMap { LetterComposer.localized($0.learnedTexts, l10n: l10n) }
                var entry = Entry(id: "fulfilled:\(memory.letterId)", category: .learned, date: memory.date,
                                  text: learned ?? l10n("memory.unavailable"), location: location(letter), letterId: letter?.id)
                if let source, let text = replyText(source), let origin = letters[source.letterId], visible(origin) {
                    entry.cause = l10n("memory.because", l10n.day(source.date, full: true), l10n.cityName(catalog.city(origin.cityId)), text)
                    entry.sourceLetterId = origin.id
                } else {
                    entry.cause = l10n("memory.causeUnavailable")
                }
                entries.append(entry)
            default: break
            }
        }
        for day in care.specialDays {
            let letter = day.letterId.flatMap { letters[$0] }
            guard visible(letter) else { continue }
            let text: String
            switch day.kind {
            case .hatched: text = l10n("memory.hatched", care.petName)
            case .firstLetter: text = l10n("memory.firstLetter", care.petName)
            case .hundredDays: text = l10n("memory.hundredDays", care.petName)
            case .friendMet:
                let names = letter?.friendSettlement?.names
                    ?? catalog.friends.friends.first { $0.id == care.metFriends?.first { $0.letterId == day.letterId }?.id }?.name
                text = l10n("friends.memoryMet", LetterComposer.localized(names, l10n: l10n) ?? l10n("friends.unknown"))
            }
            entries.append(Entry(id: "special:\(day.id)", category: .special, date: day.date,
                                 text: text, location: day.kind == .friendMet && letter?.friendSettlement?.cityId == nil ? nil : location(letter), letterId: letter?.id))
        }
        for index in entries.indices {
            let entry = entries[index]
            entries[index].sponsorTags = [entry.letterId, entry.sourceLetterId].compactMap { $0 }
                .compactMap { letters[$0] }.flatMap { LetterComposer.sponsorTags(for: $0, l10n: l10n, letters: journey.letters) }
                .reduce(into: []) { tags, tag in if !tags.contains(tag) { tags.append(tag) } }
            let kind = entry.category == .replies ? "reply" : "fulfilled"
            guard entry.category != .special else { continue }
            entries[index].citedLetterIds = Array(Set(journey.letters.filter {
                $0.deliverAt <= now && $0.memoryReference?.kind == kind
                    && $0.memoryReference?.letterId == entry.letterId && $0.memoryReference?.date == entry.date
            }.map(\.id))).sorted()
        }
        self.entries = entries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.letterId != $1.letterId { return ($0.letterId ?? -1) > ($1.letterId ?? -1) }
            return $0.id < $1.id
        }
    }

    func entries(in category: MemoryCategory) -> [Entry] { entries.filter { $0.category == category } }
}

struct MemoryBookView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let journey = model.state, let care = model.care, let catalog = model.catalog {
            let display = MemoryBookDisplay(journey: journey, care: care, now: model.now, l10n: l10n, catalog: catalog)
            VStack(alignment: .leading, spacing: 24) {
                Text(l10n("memory.intro")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(MemoryCategory.allCases) { category in
                    let entries = display.entries(in: category)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(category.title(l10n)).font(Theme.pixel(24)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 16) {
                            if entries.isEmpty {
                                Text(category.empty(l10n)).font(.system(size: 14)).foregroundStyle(theme.paperMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(entries) { entry in
                                    if entry.id != entries.first?.id { Rectangle().fill(theme.paperBorder).frame(height: 2) }
                                    memory(entry)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(theme.paper).pixelBorder(theme.paperBorder)
                    }
                }
            }
        }
    }

    private func memory(_ entry: MemoryBookDisplay.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(l10n.day(entry.date, full: true))
                if let location = entry.location { Text(location) }
            }
            .font(Theme.pixel()).foregroundStyle(theme.paperMuted)
            .fixedSize(horizontal: false, vertical: true)
            Text(entry.text).font(.system(size: 14)).lineSpacing(4).foregroundStyle(theme.paperText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ForEach(entry.sponsorTags, id: \.self) { SponsorTag(text: $0).foregroundStyle(theme.paperMuted) }
            if let cause = entry.cause {
                Text(cause).font(.system(size: 13)).lineSpacing(4).foregroundStyle(theme.paperMuted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let letterId = entry.letterId { letterLink(letterId, title: l10n("memory.openLetter")) }
            if let source = entry.sourceLetterId { letterLink(source, title: l10n("memory.openReply")) }
            ForEach(entry.citedLetterIds, id: \.self) { id in
                if let letter = model.state?.letters.first(where: { $0.id == id }) {
                    letterLink(id, title: LetterComposer.citation(for: letter, letters: model.state?.letters ?? [], l10n: l10n))
                }
            }
        }
    }

    private func letterLink(_ id: Int, title: String) -> some View {
        Button { model.openCollectionLetter(id) } label: {
            Text(title).font(Theme.pixel()).underline().foregroundStyle(theme.paperText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
    }
}
