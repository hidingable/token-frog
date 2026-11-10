import Foundation
import VoyageCore

/// Permanent archive, separate from the frozen per-trip IDs in journey.json.
actor RemoteContentStore {
    private let url: URL
    private let validator: RemoteContentValidator
    private var content: RemoteCityContent
    private var archive: [String: Data]?

    init(url: URL, validator: RemoteContentValidator, content: RemoteCityContent) {
        self.url = url
        self.validator = validator
        self.content = content
        archive = try? Self.readArchive(url: url)
    }

    nonisolated static func load(url: URL, validator: RemoteContentValidator) -> RemoteCityContent {
        guard let entries = try? readArchive(url: url) else { return RemoteCityContent() }
        var byCity: [String: [Data]] = [:]
        for id in entries.keys.sorted() {
            let data = entries[id]!
            guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["id"] as? String == id, let city = entry["cityId"] as? String else { continue }
            byCity[city, default: []].append(data)
        }
        return byCity.keys.sorted().reduce(into: RemoteCityContent()) { result, city in
            result = validator.accepting(byCity[city]!, cityID: city, into: result)
        }
    }

    /// Runs on this actor, never the main actor. A disk failure cannot expose nonpersistent candidates.
    func accept(_ entries: [Data], cityID: String) throws -> (content: RemoteCityContent, ids: [String]) {
        // Preserve an unknown/corrupt archive untouched instead of replacing permanent content.
        guard var archive else { throw CocoaError(.fileReadCorruptFile) }
        let accepted = validator.accepting(entries, cityID: cityID, into: RemoteCityContent())
        let fresh = try encodedEntries(accepted)
        let additions = fresh.keys.sorted().filter { archive[$0] == nil }.map { fresh[$0]! }
        let next = validator.accepting(additions, cityID: cityID, into: content)
        for (id, data) in try encodedEntries(next) where archive[id] == nil { archive[id] = data }
        var json: [String: Any] = [:]
        for (id, data) in archive { json[id] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        let document: [String: Any] = ["schemaVersion": 1, "entries": json]
        try PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        try PrivateStorage.write(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), to: url)
        content = next
        self.archive = archive
        return (next, accepted.ids.intersection(next.ids).sorted())
    }

    private nonisolated static func readArchive(url: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["schemaVersion"] as? Int == 1, let entries = document["entries"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try entries.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
    }

    private func encodedEntries(_ content: RemoteCityContent) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        for (id, story) in content.stories { entries[id] = try JSONEncoder().encode(story) }
        for (id, item) in content.items { entries[id] = try JSONEncoder().encode(item) }
        return entries
    }
}
