import AppKit
import SwiftUI
import VoyageCore

/// Hosts SwiftUI inside a non-activating panel. It takes all mouse input itself because the app is
/// usually inactive, where SwiftUI hover and buttons would not respond.
final class PanelHostView<Content: View>: NSView {
    private let hosting: NSHostingView<Content>
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var draggable = false
    private var dragged = false

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRootView(_ view: Content) { hosting.rootView = view }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard draggable, !dragged else { return }
        dragged = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }
}

@MainActor
private func makePanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var barHeight: CGFloat
    var shoulderWidth: CGFloat = 96
    var collapsedSize: CGSize { CGSize(width: notchWidth + shoulderWidth * 2, height: barHeight) }
    var expandedSize: CGSize { CGSize(width: max(collapsedSize.width, 560), height: barHeight + 176) }

    @MainActor init(screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            notchWidth = screen.frame.width - left.width - right.width
            barHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            barHeight = max(NSStatusBar.system.thickness, 24)
        }
    }

    init(notchWidth: CGFloat, barHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.barHeight = barHeight
    }
}

@MainActor
final class NotchController {
    private struct Root: View {
        let model: AppModel
        let metrics: NotchMetrics
        let expanded: Bool
        var body: some View {
            VStack(spacing: 0) {
                if expanded {
                    NotchExpandedView(model: model, metrics: metrics)
                } else {
                    NotchCollapsedView(model: model, metrics: metrics)
                }
                Spacer(minLength: 0)
            }
            .localized(using: model)
        }
    }

    private let model: AppModel
    private let onOpen: () -> Void
    private var panel: NSPanel?
    private var host: PanelHostView<Root>?
    private var expanded = false
    private var collapseTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel, onOpen: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    func show() {
        guard panel == nil else { return }
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.close()
        panel = nil
        host = nil
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func rebuild() {
        panel?.close()
        guard let screen = targetScreen else { return }
        let metrics = NotchMetrics(screen: screen)
        expanded = false
        let host = PanelHostView(rootView: Root(model: model, metrics: metrics, expanded: false))
        host.onClick = { [weak self] in self?.onOpen() }
        host.onHover = { [weak self] inside in self?.hover(inside, metrics: metrics, screen: screen) }
        let panel = makePanel(frame: frame(for: metrics.collapsedSize, screen: screen))
        panel.level = .statusBar
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
    }

    private func frame(for size: CGSize, screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func hover(_ inside: Bool, metrics: NotchMetrics, screen: NSScreen) {
        collapseTask?.cancel()
        if inside {
            setExpanded(true, metrics: metrics, screen: screen)
        } else {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false, metrics: metrics, screen: screen)
            }
        }
    }

    private func setExpanded(_ value: Bool, metrics: NotchMetrics, screen: NSScreen) {
        guard value != expanded else { return }
        expanded = value
        host?.setRootView(Root(model: model, metrics: metrics, expanded: value))
        panel?.setFrame(frame(for: value ? metrics.expandedSize : metrics.collapsedSize, screen: screen), display: true)
    }
}

@MainActor
final class FloatingController {
    static let size = CGSize(width: 150, height: 48)

    private let model: AppModel
    private let onOpen: () -> Void
    private var panel: NSPanel?

    init(model: AppModel, onOpen: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    func show() {
        guard panel == nil else { return }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let panel = makePanel(frame: NSRect(x: visible.maxX - Self.size.width - 24, y: visible.maxY - Self.size.height - 24, width: Self.size.width, height: Self.size.height))
        panel.level = .floating
        let host = PanelHostView(rootView: FloatingView(model: model).localized(using: model))
        host.draggable = true
        host.onClick = onOpen
        panel.contentView = host
        panel.setFrameAutosaveName("TokenVoyageFloating")
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Keys {
        static let notch = "notchEnabled"
        static let floating = "floatingEnabled"
    }

    private lazy var model = AppModel(isSnapshot: ProcessInfo.processInfo.arguments.contains("--snapshot"), languageOverride: snapshotLanguage)
    private var snapshotLanguage: Language?
    private var l10n: L10n { model.l10n }
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private lazy var notch = NotchController(model: model) { [weak self] in self?.openMain() }
    private lazy var floating = FloatingController(model: model) { [weak self] in self?.openMain() }

    private var notchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.notch) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notch) }
    }

    private var floatingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.floating) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.floating) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            if let languageIndex = arguments.firstIndex(of: "--language") {
                guard arguments.count > languageIndex + 1,
                      let language = Language(rawValue: arguments[languageIndex + 1]) else {
                    let l10n = L10n(language: Language.resolve(systemLanguages: Locale.preferredLanguages))
                    FileHandle.standardError.write(Data(l10n("snapshot.invalidLanguage").utf8))
                    exit(EXIT_FAILURE)
                }
                snapshotLanguage = language
            }
            let preference = UserDefaults.standard.string(forKey: "language").flatMap(LanguagePreference.init(rawValue:)) ?? .system
            let l10n = L10n(language: snapshotLanguage ?? preference.resolve(systemLanguages: Locale.preferredLanguages))
            // Keep this before the first access to the lazy model: no real save directory is touched.
            guard let dataDirectory = ProcessInfo.processInfo.environment["TOKEN_VOYAGE_DATA_DIR"], !dataDirectory.isEmpty else {
                FileHandle.standardError.write(Data(l10n("snapshot.missingDataDirectory").utf8))
                exit(EXIT_FAILURE)
            }
            guard arguments.count > index + 1, !arguments[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data(l10n("snapshot.missingOutput").utf8))
                exit(EXIT_FAILURE)
            }
            Theme.registerFonts()
            let directory = URL(fileURLWithPath: arguments[index + 1])
            Task {
                await model.scan()
                await model.loadDashboard()
                Snapshots.write(model: model, to: directory)
                NSApp.terminate(nil)
            }
            return
        }
        Theme.registerFonts()
        model.onLockChange = { [weak self] in self?.updateSurfaces() }
        model.onLanguageChange = { [weak self] in
            guard let self else { return }
            rebuildMenu()
            mainWindow?.title = l10n("app.name")
            statusItem?.button?.setAccessibilityLabel(l10n("app.name"))
        }
        setUpStatusItem()
        model.start()
        updateSurfaces()
    }

    private func updateSurfaces() {
        rebuildMenu()
        statusItem?.button?.image = statusImage()
        if model.isLocked {
            notch.hide()
            floating.hide()
            openMain()
        } else {
            if notchEnabled { notch.show() }
            if floatingEnabled { floating.show() }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage()
        item.button?.setAccessibilityLabel(l10n("app.name"))
        statusItem = item
        rebuildMenu()
    }

    private func statusImage() -> NSImage {
        let image = NSImage(cgImage: Sprites.image(model.state?.pet ?? .pigeon, .rest), size: NSSize(width: 16, height: 17))
        return image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(makeItem(l10n("menu.open"), #selector(openMainAction)))
        if !model.isLocked {
            menu.addItem(makeItem(l10n("menu.refresh"), #selector(refreshAction)))
            menu.addItem(.separator())
            menu.addItem(makeItem(l10n("menu.notch"), #selector(toggleNotch), checked: notchEnabled))
            menu.addItem(makeItem(l10n("menu.floating"), #selector(toggleFloating), checked: floatingEnabled))
            let petMenu = NSMenu()
            for pet in PetKind.allCases {
                let item = makeItem(pet.displayName, #selector(selectPet(_:)), checked: model.state?.pet == pet)
                item.representedObject = pet.rawValue
                petMenu.addItem(item)
            }
            let petItem = NSMenuItem(title: l10n("menu.pet"), action: nil, keyEquivalent: "")
            petItem.submenu = petMenu
            menu.addItem(petItem)
            menu.addItem(.separator())
        }
        let languageMenu = NSMenu()
        for preference in LanguagePreference.allCases {
            let item = makeItem(l10n(L10n.languageKeys[preference]!), #selector(selectLanguage(_:)), checked: model.languagePreference == preference)
            item.representedObject = preference.rawValue
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: l10n("menu.language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: l10n("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func openMainAction() { openMain() }
    @objc private func refreshAction() { model.scheduleScan(immediately: true) }

    @objc private func toggleNotch() {
        notchEnabled.toggle()
        if notchEnabled { notch.show() } else { notch.hide() }
        rebuildMenu()
    }

    @objc private func toggleFloating() {
        floatingEnabled.toggle()
        if floatingEnabled { floating.show() } else { floating.hide() }
        rebuildMenu()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preference = LanguagePreference(rawValue: raw) else { return }
        model.languagePreference = preference
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pet = PetKind(rawValue: raw) else { return }
        model.setPet(pet)
        statusItem?.button?.image = statusImage()
        rebuildMenu()
    }

    private func openMain() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = l10n("app.name")
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.ink)
            window.minSize = NSSize(width: 760, height: 520)
            window.contentView = NSHostingView(rootView: SaveAwareMainView(model: model, onImport: { [weak self] file in
                self?.importBackup(for: file)
            }).localized(using: model))
            window.center()
            mainWindow = window
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func importBackup(for file: SaveFile) {
        let panel = NSOpenPanel()
        panel.title = l10n("backup.choose", file.rawValue)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.restoreSave(SaveBackup(file: file, url: url))
    }
}

private struct SaveAwareMainView: View {
    let model: AppModel
    let onImport: (SaveFile) -> Void

    var body: some View {
        if model.isLocked {
            SaveRecoveryView(
                issues: model.recoveryIssues, error: model.recoveryError,
                onRestore: { model.restoreSave($0) }, onImport: onImport,
                onRestart: { model.restartSave($0) }, onRetry: { model.retrySaves() },
                onQuit: { NSApp.terminate(nil) }
            )
        } else {
            MainView(model: model)
        }
    }
}

/// Renders every surface to PNG for offline visual checks: `TokenVoyage --snapshot <dir>`.
@MainActor
enum Snapshots {
    static func write(model: AppModel, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metrics = NotchMetrics(notchWidth: 180, barHeight: 37)
        render(MainView(model: model, tab: .journey), size: CGSize(width: 760, height: 780), name: "main-journey", directory, model: model)
        render(MainView(model: model, tab: .mail), size: CGSize(width: 760, height: 780), name: "main-mail", directory, model: model)
        render(MainView(model: model, tab: .passport), size: CGSize(width: 760, height: 400), name: "main-passport", directory, model: model)
        render(MainView(model: model, tab: .dashboard, dashboard: DashboardSelection(period: .month)), size: CGSize(width: 940, height: 1240), name: "dashboard-month", directory, model: model)
        render(MainView(model: model, tab: .dashboard, dashboard: DashboardSelection(period: .all, client: "codex")), size: CGSize(width: 940, height: 1240), name: "dashboard-all-codex", directory, model: model)
        render(MainView(model: model, tab: .dashboard, dashboard: DashboardSelection(period: .today)), size: CGSize(width: 760, height: 1240), name: "dashboard-today-narrow", directory, model: model)
        if let peak = model.dashboardDays.map({ UsageDashboard(days: $0, start: nil, end: DayKey.string(from: model.now)) })?.peak {
            render(MainView(model: model, tab: .dashboard, dashboard: DashboardSelection(day: peak.date, metric: .fuel, showModels: true)), size: CGSize(width: 940, height: 1240), name: "dashboard-peak-day", directory, model: model)
        }
        render(MainView(model: model, tab: .quota), size: CGSize(width: 760, height: 420), name: "main-quota", directory, model: model)
        render(NotchCollapsedView(model: model, metrics: metrics), size: metrics.collapsedSize, name: "notch-collapsed", directory, model: model)
        render(NotchExpandedView(model: model, metrics: metrics), size: metrics.expandedSize, name: "notch-expanded", directory, model: model)
        render(FloatingView(model: model), size: FloatingController.size, name: "floating", directory, model: model)
        // These examples are in memory only and never enter the SaveStore.
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
