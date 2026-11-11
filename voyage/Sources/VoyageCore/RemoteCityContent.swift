import Foundation

/// Immutable, validated additions. Never decode away unknown fields before checking sponsor/IDs.
public struct RemoteCityContent: Sendable {
    public var stories: [String: Story] = [:]
    public var items: [String: Item] = [:]
    public init() {}
    public var ids: Set<String> { Set(stories.keys).union(items.keys) }

    public func merging(into catalog: CityCatalog) -> CityCatalog {
        catalog.addingRemoteContent(stories: Array(stories.values), items: Array(items.values))
    }
}

public struct RemoteContentValidator: Sendable {
    private let catalog: CityCatalog
    private let reserved: Set<String>

    public init(directory: URL, catalog: CityCatalog) throws {
        self.catalog = catalog
        var ids = Set(catalog.all.map(\.id))
        let published = try String(contentsOf: directory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
        ids.formUnion(published.split(whereSeparator: \.isNewline).map(String.init))
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let file as URL in files where file.pathExtension == "json" {
            ids.formUnion(ContentValidator.draftIDs(in: try JSONSerialization.jsonObject(with: Data(contentsOf: file))))
        }
        reserved = ids
    }

    /// Items first so a story can reference a souvenir in the same response. First acceptance wins.
    public func accepting(_ entries: [Data], cityID: String, into existing: RemoteCityContent) -> RemoteCityContent {
        guard catalog.find(cityID)?.id == cityID else { return existing }
        let decoder = JSONDecoder()
        var result = existing
        var occupied = reserved.union(existing.ids)
        occupied.formUnion(existing.stories.values.flatMap { $0.replies.map(\.id) })
        func entryIDs(_ object: [String: Any]) -> [String] {
            ContentValidator.draftIDs(in: object.filter { $0.key != "sponsor" })
        }
        let objects = entries.compactMap { data -> (Data, [String: Any])? in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["cityId"] as? String == cityID else { return nil }
            let content = object.filter { $0.key != "sponsor" }
            guard !ContentValidator.containsSponsor(content) else { return nil }
            if let sponsor = object["sponsor"] {
                guard let data = try? JSONSerialization.data(withJSONObject: sponsor, options: [.fragmentsAllowed]),
                      (try? decoder.decode(Sponsor.self, from: data)) != nil else { return nil }
            }
            let ids = entryIDs(object)
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({
                !$0.isEmpty && $0.count <= 128 && $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            }) else { return nil }
            return (data, object)
        }
        func available(_ object: [String: Any]) -> Bool {
            Set(entryIDs(object)).isDisjoint(with: occupied)
        }
        let cities = Dictionary(uniqueKeysWithValues: catalog.all.map { ($0.id, $0) })
        for (data, object) in objects where object["kind"] as? String == "souvenir" {
            guard available(object), let item = try? decoder.decode(Item.self, from: data), item.source == nil,
                  ContentValidator.validate(item: item, cities: cities, icons: Set(catalog.pets.icons.keys)).isEmpty else { continue }
            result.items[item.id] = item
            occupied.formUnion(entryIDs(object))
        }
        let items = Dictionary(uniqueKeysWithValues: (catalog.items.all + result.items.values).map { ($0.id, $0) })
        let bundledReplies = Set(catalog.stories.all.flatMap { $0.replies.map(\.id) })
            .union(existing.stories.values.flatMap { $0.replies.map(\.id) })
        var candidates = objects.compactMap { data, object -> (Story, [String: Any])? in
            guard ["arrival", "transit"].contains(object["kind"] as? String ?? ""), available(object),
                  let story = try? decoder.decode(Story.self, from: data),
                  story.sponsor == nil ? !story.factIds.isEmpty : story.factIds.isEmpty,
                  story.replies.count == 2,
                  Set(story.replies.map(\.habit)) == ["talkative", "observant"] else { return nil }
            return (story, object)
        }
        // Recheck dependants when an invalid story removes a referenced reply from the response.
        while !candidates.isEmpty {
            let replies = bundledReplies.union(candidates.flatMap { $0.0.replies.map(\.id) })
            var used = occupied
            let valid = candidates.filter { story, object in
                let ids = entryIDs(object)
                guard Set(ids).isDisjoint(with: used),
                      ContentValidator.validate(story: story, cities: cities, tags: Set(catalog.wishes.tagIDs),
                                                items: items, replyIds: replies).isEmpty else { return false }
                used.formUnion(ids)
                return true
            }
            if valid.count == candidates.count {
                for (story, _) in valid { result.stories[story.id] = story }
                break
            }
            candidates = valid
        }
        return result
    }
}
