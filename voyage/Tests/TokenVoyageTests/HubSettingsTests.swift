import AppKit
import Foundation
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private final class HubSettingsDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private(set) var writes: [String] = []

    override func object(forKey name: String) -> Any? { values[name] }
    override func string(forKey name: String) -> String? { values[name] as? String }
    override func set(_ value: Any?, forKey name: String) {
        values[name] = value
        writes.append(name)
    }
}

@Suite @MainActor struct HubSettingsTests {
    @Test func networkPreferencesDefaultOnAndPersistIndependently() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-hub-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = HubSettingsDefaults()
        func model() -> AppModel {
            AppModel(defaults: defaults, directory: directory, catalog: localizationCatalog,
                     themes: testThemes, runtimeEnabled: false)
        }
        let first = model()
        #expect(first.cityContentEnabled && first.wishResolveEnabled && first.sponsorContentEnabled)
        #expect(defaults.writes.isEmpty)

        first.cityContentEnabled = false
        let second = model()
        #expect(!second.cityContentEnabled && second.wishResolveEnabled)
        #expect(defaults.object(forKey: "cityContentEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "wishResolveEnabled") == nil)

        second.wishResolveEnabled = false
        second.cityContentEnabled = true
        let third = model()
        #expect(third.cityContentEnabled && !third.wishResolveEnabled)
        #expect(defaults.object(forKey: "wishResolveEnabled") as? Bool == false)
        #expect(defaults.writes == ["cityContentEnabled", "wishResolveEnabled", "cityContentEnabled"])
        third.sponsorContentEnabled = false
        #expect(!model().sponsorContentEnabled)
        #expect(defaults.object(forKey: "sponsorContentEnabled") as? Bool == false)
        #expect(model().cityContentEnabled && !model().wishResolveEnabled)
    }

    @Test func snapshotNetworkPreferencesNeverWriteDefaultsOrCreateSaves() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-hub-settings-snapshot-\(UUID().uuidString)")
        let defaults = HubSettingsDefaults()
        defaults.set(false, forKey: "cityContentEnabled")
        defaults.set(false, forKey: "wishResolveEnabled")
        defaults.set(false, forKey: "sponsorContentEnabled")
        let writes = defaults.writes
        let model = AppModel(isSnapshot: true, defaults: defaults, directory: directory,
                             catalog: localizationCatalog, themes: testThemes, runtimeEnabled: false)
        model.cityContentEnabled = true
        model.wishResolveEnabled = true
        model.sponsorContentEnabled = true
        #expect(model.cityContentEnabled && model.wishResolveEnabled)
        #expect(defaults.object(forKey: "cityContentEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "wishResolveEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "sponsorContentEnabled") as? Bool == false)
        #expect(defaults.writes == writes)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func networkSettingsHaveBothLanguagesAndExplainWishTextSharing() {
        let chinese = L10n(language: .zhHans)
        let english = L10n(language: .en)
        #expect(chinese("settings.accountPrivacy") == "账号与隐私")
        #expect(english("settings.accountPrivacy") == "Accounts & privacy")
        #expect(chinese("settings.cityContent") == "城市新内容")
        #expect(english("settings.cityContent") == "New city content")
        #expect(chinese("settings.wishResolve") == "联网解析心愿")
        #expect(english("settings.wishResolve") == "Resolve wishes online")
        #expect(chinese("settings.cityContentHint").contains("目的地城市"))
        #expect(english("settings.cityContentHint").contains("destination city"))
        #expect(chinese("settings.wishResolveHint").contains("发送心愿文字"))
        #expect(english("settings.wishResolveHint").contains("Send wish text"))
        #expect(chinese("settings.sponsorContent") == "合作内容")
        #expect(english("settings.sponsorContent") == "Partner content")
        #expect(chinese("settings.sponsorContentHint").contains("始终标注"))
        #expect(chinese("settings.sponsorContentHint").contains("每周最多一次"))
        #expect(chinese("settings.sponsorContentHint").contains("保留"))
        #expect(english("settings.sponsorContentHint").contains("always labelled"))
        #expect(english("settings.sponsorContentHint").contains("at most once a week"))
        #expect(english("settings.sponsorContentHint").contains("stays once received"))
    }

    @Test(arguments: [false, true], [false, true])
    func sponsorSelectionGateRequiresBothHubAndLocalSwitches(hubEnabled: Bool, localEnabled: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-sponsor-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = HubConfig.defaults
        config.sponsorContentEnabled = hubEnabled
        let data = try JSONEncoder().encode(config)
        let hub = HubClient(baseURL: URL(string: "https://hub.invalid"), transport: { request in
            #expect(request.url?.path == "/v1/config")
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let model = AppModel(defaults: HubSettingsDefaults(), directory: directory, catalog: localizationCatalog,
                             themes: testThemes, hubClient: hub, runtimeEnabled: false)
        model.sponsorContentEnabled = localEnabled
        #expect(!model.sponsorContentAllowed)
        await model.refreshHubConfiguration()
        #expect(model.sponsorContentAllowed == (hubEnabled && localEnabled))
    }

    @Test func networkSettingsSnapshotsCoverBothLanguagesAndBothAppearances() {
        let cases = Snapshots.settingsNetworkCases
        #expect(cases.count == 4)
        #expect(Set(cases.map(\.name)) == [
            "settings-network-zh-Hans-dark", "settings-network-zh-Hans-light",
            "settings-network-en-dark", "settings-network-en-light",
        ])
        for language in Language.allCases {
            #expect(Set(cases.filter { $0.language == language }.map(\.scheme.rawValue)) == ["dark", "light"])
        }
    }

    @Test func networkSettingsRenderOffscreenInBothLanguagesAndAppearances() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        for example in Snapshots.settingsNetworkCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voyage-settings-render-\(UUID().uuidString)")
            let defaults = HubSettingsDefaults()
            let model = AppModel(isSnapshot: true, languageOverride: example.language,
                                 appearanceOverride: example.scheme, defaults: defaults, directory: directory,
                                 catalog: localizationCatalog, themes: testThemes, now: { now }, runtimeEnabled: false)
            var rendered: NSImage?
            model.withSnapshotState({ state in
                state.startDate = DayKey.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
                state.openDate = DayKey.next(state.startDate)
            }) {
                // Avoid the native map picker: this fixture only needs the settings and privacy controls.
                #expect(!model.canChangeStart)
                let view = SettingsTab(model: model).padding(12)
                    .frame(width: 760).fixedSize(horizontal: false, vertical: true)
                    .background(model.theme.background).localized(using: model)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
                rendered = renderer.nsImage
            }
            let image = try #require(rendered)
            // The unconstrained height includes the final About/privacy group instead of clipping a viewport.
            #expect(image.size.width == 760)
            #expect(image.size.height > 900 && image.size.height < 2300)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(bitmap.pixelsWide == 760)
            #expect(bitmap.pixelsHigh >= Int(image.size.height))
            #expect(!png.isEmpty)
            #expect(defaults.writes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            if let outputPath = ProcessInfo.processInfo.environment["VOYAGE_TEST_RENDER_DIR"] {
                let output = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent(example.name + ".png"))
            }
        }
    }
}
