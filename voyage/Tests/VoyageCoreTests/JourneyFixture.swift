import Foundation
@testable import VoyageCore

/// Legacy fixtures enter through the same ordered migrations as SaveStore.
func decodeOldJourneyFixture(_ data: Data) throws -> JourneyState {
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let migrations = SaveMigrations.journey(catalog: testCatalog)
    var version = json["version"] as! Int
    while version < JourneyState.currentVersion {
        json = try migrations.steps[version]!(json)
        version += 1
        json["version"] = version
    }
    return try JSONDecoder().decode(JourneyState.self, from: JSONSerialization.data(withJSONObject: json))
}
