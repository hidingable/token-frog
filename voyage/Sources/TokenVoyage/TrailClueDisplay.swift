import VoyageCore

struct TrailClueDisplay: Equatable {
    let summary: String
    let status: String?

    init?(cityId: String, care: CareState, library: StoryLibrary, l10n: L10n) {
        let count = care.trailClues[cityId, default: 0]
        guard count > 0 else { return nil }
        switch RevisitStories.progress(in: cityId, care: care, library: library) {
        case let .collecting(required):
            summary = l10n("collection.revisitProgress", count, required)
            status = nil
        case .unlocked:
            summary = l10n("collection.clueCount", count)
            status = l10n("collection.revisitUnlocked")
        case .told:
            summary = l10n("collection.clueCount", count)
            status = l10n("collection.revisitTold")
        case .unavailable:
            summary = l10n("collection.clueCount", count)
            status = nil
        }
    }
}
