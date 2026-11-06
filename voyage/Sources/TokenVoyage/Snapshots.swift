import AppKit
import SwiftUI
import VoyageCore

/// Renders every surface to PNG for offline visual checks: `TokenVoyage --snapshot <dir>`.
@MainActor
enum Snapshots {
    static func write(model: AppModel, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metrics = NotchMetrics(notchWidth: 180, barHeight: 37)
        let mainSize = CGSize(width: 760, height: 780)

        func main(_ tab: MainTab, name: String, size: CGSize = mainSize, dashboard: DashboardSelection = DashboardSelection(), update: (inout JourneyState) -> Void = { _ in }) {
            model.withSnapshotState(update) {
                model.navigate(to: tab)
                render(MainView(model: model, dashboard: dashboard), size: size, name: name, directory, model: model)
            }
        }

        main(.home, name: "main-home", update: { state in
            // Even a fixture with only read mail shows the new-mail home variant.
            if let index = state.letters.indices.first {
                state.letters[index].read = false
                state.letters[index].deliverAt = min(state.letters[index].deliverAt, model.now)
            }
        })
        main(.home, name: "main-home-no-mail", update: { state in
            for index in state.letters.indices { state.letters[index].read = true }
        })
        main(.journey, name: "main-journey")
        model.mailFilter = .all
        model.selectedLetterID = nil
        main(.mail, name: "main-mail")
        model.collectionTab = .passport
        main(.collection, name: "collection-passport", size: CGSize(width: 760, height: 400))
        model.collectionTab = .bag
        main(.collection, name: "collection-bag", size: CGSize(width: 760, height: 400))
        model.showingSettings = true
        render(MainView(model: model), size: CGSize(width: 760, height: 520), name: "main-settings", directory, model: model)

        model.dataTab = .dashboard
        let dashboardSize = CGSize(width: 940, height: 1240)
        main(.data, name: "dashboard-month", size: dashboardSize, dashboard: DashboardSelection(period: .month))
        main(.data, name: "dashboard-all-codex", size: dashboardSize, dashboard: DashboardSelection(period: .all, client: "codex"))
        main(.data, name: "dashboard-today-narrow", size: CGSize(width: 760, height: 1240), dashboard: DashboardSelection(period: .today))
        let peak = model.dashboardDays.map { UsageDashboard(days: $0, start: nil, end: DayKey.string(from: model.now)) }?.peak
        main(.data, name: "dashboard-peak-day", size: dashboardSize, dashboard: DashboardSelection(day: peak?.date ?? DayKey.string(from: model.now), metric: .fuel, showModels: true))
        model.dataTab = .quota
        main(.data, name: "data-quota", size: CGSize(width: 760, height: 420))

        render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-collapsed", directory, model: model)
        model.withSnapshotState({ state in
            state.legCost = max(state.legCost, 12 * fuelPerKm)
            state.legFuel = state.legCost - 12 * fuelPerKm
            for index in state.letters.indices { state.letters[index].read = true }
        }) {
            render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-near-arrival", directory, model: model)
        }
        render(NotchExpandedView(model: model, metrics: metrics), size: metrics.expandedSize, name: "notch-expanded", directory, model: model)
        render(FloatingView(model: model), size: FloatingController.size, name: "floating", directory, model: model)

        let exampleDirectory = model.l10n("snapshot.exampleDirectory")
        let quarantinedPath = "\(exampleDirectory)/backups/journey.json.v1.2026-11-06.corrupted.json"
        let exampleBackup = SaveBackup(file: .journey, url: URL(fileURLWithPath: "\(exampleDirectory)/backups/journey.json.v1.2026-11-05.migration.json"))
        render(SaveRecoveryView(
            issues: [SaveRecoveryIssue(file: .journey, problem: .corrupted(backupPath: quarantinedPath), backups: [exampleBackup])],
            onRestore: { _ in }, onImport: { _ in }, onRestart: { _ in }, onRetry: {}, onQuit: {}
        ), size: CGSize(width: 760, height: 620), name: "save-recovery-corrupted", directory, model: model)
        render(SaveRecoveryView(
            issues: [SaveRecoveryIssue(file: .journey, problem: .tooNew(version: 2))],
            onRestore: { _ in }, onImport: { _ in }, onRestart: { _ in }, onRetry: {}, onQuit: {}
        ), size: CGSize(width: 760, height: 420), name: "save-recovery-too-new", directory, model: model)
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, name: String, _ directory: URL, model: AppModel) {
        let hosting = NSHostingView(rootView: view.localized(using: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .darkGray
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
