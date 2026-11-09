/// Revisit eligibility is derived from cumulative clues and the current content pack.
/// Nothing is spent or decided until a settled travel letter actually tells the story.
public enum RevisitStories {
    public enum Progress: Equatable, Sendable {
        case unavailable
        case collecting(required: Int)
        case unlocked
        case told
    }

    // StoryLibrary keeps IDs sorted, including the stable order of a city's stories.
    private static func stories(in cityId: String, library: StoryLibrary) -> [Story] {
        library.all.filter { $0.kind == "revisit" && $0.cityId == cityId }
    }

    public static func next(in cityId: String, care: CareState, library: StoryLibrary) -> Story? {
        let told = Set(care.toldRevisitStoryIds ?? [])
        return stories(in: cityId, library: library).enumerated().first {
            !told.contains($0.element.id) && care.trailClues[cityId, default: 0] / 3 >= $0.offset + 1
        }?.element
    }

    public static func unlockedCities(care: CareState, library: StoryLibrary) -> Set<String> {
        Set(care.trailClues.keys.filter { next(in: $0, care: care, library: library) != nil })
    }

    public static func progress(in cityId: String, care: CareState, library: StoryLibrary) -> Progress {
        let stories = stories(in: cityId, library: library)
        guard !stories.isEmpty else { return .unavailable }
        if next(in: cityId, care: care, library: library) != nil { return .unlocked }
        let told = Set(care.toldRevisitStoryIds ?? [])
        if let index = stories.firstIndex(where: { !told.contains($0.id) }) {
            return .collecting(required: 3 * (index + 1))
        }
        return .told
    }
}
