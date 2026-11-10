import Foundation

extension ContentValidator {
    /// Validate generated additions against an unchanged bundled pack, including its global ID namespace.
    public static func validate(directory: URL, drafts: URL) -> [ContentIssue] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-draft-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: directory, to: temporary)
            return overlayDrafts(directory: temporary, drafts: drafts) + validate(directory: temporary)
        } catch {
            return [ContentIssue(file: directory.path, rule: "draftPack", message: "Cannot copy content pack: \(error)")]
        }
    }

    /// The caller owns this disposable directory. Preserve raw JSON so unknown sponsor fields cannot disappear during decoding.
    static func overlayDrafts(directory: URL, drafts: URL) -> [ContentIssue] {
        let manager = FileManager.default
        var issues: [ContentIssue] = []
        func report(_ file: String, _ rule: String, _ message: String) {
            issues.append(ContentIssue(file: file, rule: rule, message: message))
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: drafts.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [ContentIssue(file: drafts.path, rule: "drafts", message: "Draft directory does not exist")]
        }
        var reserved: Set<String> = []
        do {
            let published = try String(contentsOf: directory.appendingPathComponent("published-ids.txt"), encoding: .utf8)
            reserved.formUnion(published.split(whereSeparator: \.isNewline).map(String.init))
            reserved.formUnion(try CityContent.readBase(directory: directory).map(\.id))
            guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let file as URL in files where file.pathExtension == "json" {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                reserved.formUnion(draftIDs(in: json))
            }
        } catch {
            report("Content", "draftPack", "Cannot read bundled IDs: \(error)")
            return issues
        }
        var draftIDsSeen: Set<String> = []
        for kind in ["stories", "items"] {
            let folder = drafts.appendingPathComponent(kind)
            guard manager.fileExists(atPath: folder.path) else { continue }
            let files: [URL]
            do {
                files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                report(kind, "draftJSON", "Cannot read drafts: \(error)")
                continue
            }
            for file in files {
                let path = "\(kind)/\(file.lastPathComponent)"
                do {
                    let data = try Data(contentsOf: file)
                    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        report(path, "draftJSON", "Draft file must contain an array of entries")
                        continue
                    }
                    if containsSponsor(entries) { report(path, "draftSponsor", "Sponsor fields are not allowed in city drafts") }
                    for id in draftIDs(in: entries) {
                        if reserved.contains(id) { report(path, "draftID", "Draft ID collides with bundled content: \(id)") }
                        if !draftIDsSeen.insert(id).inserted { report(path, "draftID", "Duplicate draft ID: \(id)") }
                    }
                    let cityID = file.deletingPathExtension().lastPathComponent
                    let cityFile = directory.appendingPathComponent("cities/\(cityID).json")
                    let city: City
                    do { city = try JSONDecoder().decode(City.self, from: Data(contentsOf: cityFile)) }
                    catch {
                        report(path, "draftCity", "Drafts require an existing city file: \(cityID)")
                        continue
                    }
                    if kind == "stories" {
                        let stories = try JSONDecoder().decode([Story].self, from: data)
                        let facts = Set(city.facts.map(\.id))
                        for story in stories {
                            if story.cityId != cityID { report(path, "draftCity", "Story cityId must match its city file: \(story.id)") }
                            if !Set(story.factIds).isSubset(of: facts) { report(path, "draftFacts", "Story must reference only facts in cities/\(cityID).json: \(story.id)") }
                            if !["arrival", "transit"].contains(story.kind) { report(path, "draftKind", "Generated city stories must be arrival or transit: \(story.id)") }
                            if story.replies.count != 2 || Set(story.replies.map(\.habit)) != ["talkative", "observant"] {
                                report(path, "draftReplies", "Generated stories require one talkative and one observant reply: \(story.id)")
                            }
                        }
                    } else {
                        for item in try JSONDecoder().decode([Item].self, from: data) {
                            if item.cityId != cityID { report(path, "draftCity", "Item cityId must match its city file: \(item.id)") }
                            if item.kind != "souvenir" { report(path, "draftKind", "Generated items must be souvenirs: \(item.id)") }
                        }
                    }
                    let destination = directory.appendingPathComponent(path)
                    var combined: [[String: Any]] = []
                    if manager.fileExists(atPath: destination.path) {
                        guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]] else {
                            report(path, "draftJSON", "Bundled file must contain an array of entries")
                            continue
                        }
                        combined = existing
                    }
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: combined + entries, options: [.sortedKeys]).write(to: destination)
                } catch { report(path, "draftJSON", "Cannot decode or merge drafts: \(error)") }
            }
        }
        return issues
    }

    private static func draftIDs(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            return ((object["id"] as? String).map { [$0] } ?? [])
                + object.keys.sorted().filter { $0 != "id" }.flatMap { draftIDs(in: object[$0]!) }
        }
        return (value as? [Any])?.flatMap { draftIDs(in: $0) } ?? []
    }

    private static func containsSponsor(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object["sponsor"] != nil || object.values.contains(where: containsSponsor)
        }
        return (value as? [Any])?.contains(where: containsSponsor) ?? false
    }
}
