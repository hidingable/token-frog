import AppKit
import SwiftUI
import Testing
import VoyageCore
@testable import TokenVoyage

private final class JourneyRenderingDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey name: String) -> Any? { nil }
    override func string(forKey name: String) -> String? { nil }
    override func set(_ value: Any?, forKey name: String) {}
}

@Suite @MainActor struct JourneyRenderingTests {
    @Test(arguments: [Language.zhHans, .en], [ThemeScheme.dark, .light])
    func journeyAndExpandedNotchFitEachPhaseInBothLanguagesAndThemes(language: Language, scheme: ThemeScheme) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journey-rendering-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let model = AppModel(isSnapshot: true, languageOverride: language, appearanceOverride: scheme,
                             defaults: JourneyRenderingDefaults(), directory: directory, catalog: localizationCatalog,
                             themes: testThemes, now: { now }, runtimeEnabled: false)
        let metrics = NotchMetrics(notchWidth: 180, barHeight: 37)
        for phase in [JourneyState.Phase.home, .pending, .outbound, .staying, .returning] {
            let example = Snapshots.journeyPhaseExample(phase: phase, catalog: localizationCatalog, now: now, petName: "Pip")
            #expect(example.journey.travelFundKm <= example.journey.recentDailyKm(before: DayKey.string(from: now)))
            model.withSnapshotCare({ $0 = example.care }) {
                model.withSnapshotState({ $0 = example.journey }) {
                    do {
                        let journey = try render(JourneyTab(model: model, availableWidth: 736).padding(12)
                            .frame(width: 760).background(model.theme.background).localized(using: model),
                                                 name: "journey-\(phase.rawValue)", language: language, scheme: scheme)
                        #expect(journey.size.width == 760 && journey.size.height > 400 && journey.size.height < 900)
                        let notch = try render(NotchExpandedView(model: model, metrics: metrics).localized(using: model),
                                               name: "notch-\(phase.rawValue)", language: language, scheme: scheme)
                        #expect(notch.size == metrics.expandedSize)
                    } catch {
                        Issue.record(error)
                    }
                }
            }
            // Native capture is synchronous; let other main-actor tests finish their async requests.
            await Task.yield()
        }
        let world = PixelMap.homeImage(localizationCatalog.city("shanghai"), theme: model.theme)
        let picker = try render(PixelMapView(image: world, availableWidth: 720, borderColor: model.theme.mapBorder),
                                name: "world-home-picker", language: language, scheme: scheme)
        #expect(picker.size == CGSize(width: 720, height: 300))
        await Task.yield()
        model.withSnapshotState({ state in
            state = JourneyState(seed: 7, startCityId: "shanghai", date: DayKey.string(from: now), now: now, catalog: localizationCatalog)
            state.phase = .pending
        }) {
            do {
                #expect(model.canChangeStart)
                _ = try render(SettingsTab(model: model).frame(width: 760).localized(using: model),
                               name: "settings-home-picker", language: language, scheme: scheme)
            } catch { Issue.record(error) }
        }
    }

    /// Optional offline artifacts for checking layout when the windowed --snapshot cannot start.
    private func render(_ view: some View, name: String, language: Language, scheme: ThemeScheme) throws -> NSImage {
        // ImageRenderer measures SwiftUI, but cannot draw the map's NSViewRepresentable.
        let renderer = ImageRenderer(content: view)
        let measured = try #require(renderer.nsImage)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: measured.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // Catch unsupported-view placeholders: both coastline colors must actually be drawn.
        let theme = AppTheme(testThemes.standard(scheme))
        let expected = Set([theme.rgb(.mapSea), theme.rgb(.mapLand)])
        var found: Set<UInt32> = []
        scan: for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 12) {
                // A window on a real display color-matches the bitmap, shifting channels by a few units.
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
                for rgb in expected where zip(channels, [Int(rgb >> 16 & 0xFF), Int(rgb >> 8 & 0xFF), Int(rgb & 0xFF)]).allSatisfy({ abs($0 - $1) <= 6 }) {
                    found.insert(rgb)
                }
                if found == expected { break scan }
            }
        }
        #expect(found == expected, "The native map must render in \(name)")
        let image = NSImage(size: measured.size)
        image.addRepresentation(bitmap)
        if let root = ProcessInfo.processInfo.environment["VOYAGE_TEST_RENDER_DIR"] {
            let output = URL(fileURLWithPath: root).appendingPathComponent("\(language.rawValue)-\(scheme.rawValue)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        return image
    }
}
