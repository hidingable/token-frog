import AppKit
import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class PhotoTestDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey key: String) -> Any? { nil }
    override func string(forKey key: String) -> String? { nil }
    override func set(_ value: Any?, forKey key: String) {}
}

@MainActor @Test func photoPathsAcceptOnlyGeneratedFilenames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-photo-security-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(defaults: PhotoTestDefaults(), directory: directory, catalog: localizationCatalog,
                         themes: testThemes, enrichmentReader: { _ in Enrichment() }, runtimeEnabled: false)
    var letter = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog).letters[0]
    for filename in ["../journey.json", "/tmp/letter-1.png", "nested/letter-1.png", "letter-1.jpg",
                     "letter-.png", "letter--1.png", "letter-１.png", "letter-1.png\n", "letter-1.png/", "letter-1.png.bak"] {
        letter.photoFile = filename
        letter = try JSONDecoder().decode(Letter.self, from: JSONEncoder().encode(letter))
        #expect(model.photoURL(letter) == nil, "Rejected: \(filename)")
        #expect(letter.photoFile == filename)
    }
    for filename in ["letter-0.png", "letter-123.png", "letter-001.png"] {
        letter.photoFile = filename
        #expect(model.photoURL(letter) == directory.appendingPathComponent("photos").appendingPathComponent(filename))
    }
    letter.photoFile = nil
    #expect(model.photoURL(letter) == nil)
}

@MainActor @Test func enrichedPhotoWritesAndReplacementsArePrivate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-photo-write-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    var journey = JourneyState(seed: 42, startCityId: "shanghai", date: "2026-11-01", catalog: localizationCatalog)
    journey.letters[0].enrichmentDone = false
    for _ in 0..<2 {
        let store = SaveStore(directory: directory, pets: localizationCatalog.pets, journeyMigrations: .journey(catalog: localizationCatalog))
        store.load()
        try store.save(journey)
        try store.save(CareState.legacy(from: journey, pets: localizationCatalog.pets))
        let model = AppModel(defaults: PhotoTestDefaults(), directory: directory, catalog: localizationCatalog, themes: testThemes,
                             enrichmentReader: { _ in Enrichment(photoData: png) }, runtimeEnabled: false)
        await model.enrichLatest()
        let letter = try #require(model.state?.letters.first)
        let photoURL = model.photoURL(letter)
        let photo = try #require(photoURL)
        let photos = directory.appendingPathComponent("photos")
        #expect(try FileManager.default.attributesOfItem(atPath: photos.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: photo.path)[.posixPermissions] as? Int == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: photo.path)
    }
}
