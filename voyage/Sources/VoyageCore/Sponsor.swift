import Foundation

/// Partner attribution is saved with delivered content, independent of the remote library.
public struct Sponsor: Codable, Equatable, Sendable {
    public var id: String
    public var label: [String: String]

    public init(id: String, label: [String: String]) {
        self.id = id
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case id, label }
    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode([String: String].self, forKey: .label)
        guard Set(fields.allKeys.map(\.stringValue)) == ["id", "label"],
              id.range(of: #"^[a-z0-9][a-z0-9-]{1,39}$"#, options: .regularExpression) == id.startIndex..<id.endIndex,
              Set(label.keys) == ["zh-Hans", "en"],
              label.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 24 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid partner attribution"))
        }
    }
}
