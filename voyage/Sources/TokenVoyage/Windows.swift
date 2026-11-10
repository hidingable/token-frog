import AppKit
import SwiftUI
import VoyageCore

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts SwiftUI inside a non-activating panel. It takes all mouse input itself because the app is
/// usually inactive; expanded notch controls receive input through a first-mouse hosting view.
final class PanelHostView<Content: View>: NSView {
    private let hosting: NSHostingView<Content>
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onClickCount: ((Int, Bool) -> Void)?
    var onPress: (() -> Void)?
    var draggable = false
    var interactiveContent = false
    private var dragged = false

    init(rootView: Content) {
        hosting = FirstMouseHostingView(rootView: rootView)
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
        guard frame.contains(point) else { return nil }
        return interactiveContent ? hosting.hitTest(convert(point, from: superview)) : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { dragged = false; onPress?() }

    override func mouseDragged(with event: NSEvent) {
        guard draggable, !dragged else { return }
        dragged = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        onClickCount?(event.clickCount, dragged)
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
    var shoulderWidth: CGFloat = 240
    var collapsedSize: CGSize { CGSize(width: notchWidth + shoulderWidth * 2, height: barHeight) }
    var expandedSize: CGSize { CGSize(width: max(collapsedSize.width, 560), height: barHeight + 240) }

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
    private let model: AppModel
    private let onOpen: () -> Void
    private var surfaces: [NotchSurface] = []
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel, onOpen: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    func show() {
        guard screenObserver == nil else { return }
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
        surfaces.forEach { $0.close() }
        surfaces = []
    }

    private func rebuild() {
        surfaces.forEach { $0.close() }
        surfaces = NSScreen.screens.map { NotchSurface(model: model, screen: $0, onOpen: onOpen) }
    }
}

/// Each display keeps its own hover state, including the camera-free top bar on external displays.
@MainActor
private final class NotchSurface {
    private struct Root: View {
        let model: AppModel
        let metrics: NotchMetrics
        let expanded: Bool
        let onOpen: () -> Void
        var body: some View {
            VStack(spacing: 0) {
                if expanded {
                    NotchExpandedView(model: model, metrics: metrics, onOpen: onOpen)
                } else {
                    NotchCollapsedView(model: model, metrics: metrics)
                }
                Spacer(minLength: 0)
            }
            .localized(using: model)
        }
    }

    private let model: AppModel
    private let screen: NSScreen
    private let metrics: NotchMetrics
    private let onOpen: () -> Void
    private let panel: NSPanel
    private let host: PanelHostView<Root>
    private var expanded = false
    private var collapseTask: Task<Void, Never>?

    init(model: AppModel, screen: NSScreen, onOpen: @escaping () -> Void) {
        self.model = model
        self.screen = screen
        self.onOpen = onOpen
        metrics = NotchMetrics(screen: screen)
        host = PanelHostView(rootView: Root(model: model, metrics: metrics, expanded: false, onOpen: onOpen))
        panel = makePanel(frame: Self.frame(for: metrics.collapsedSize, screen: screen))
        host.onClick = onOpen
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel.level = .statusBar
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func close() {
        collapseTask?.cancel()
        panel.close()
    }

    private static func frame(for size: CGSize, screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside { setExpanded(true) }
        else {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        host.interactiveContent = value
        host.setRootView(Root(model: model, metrics: metrics, expanded: value, onOpen: onOpen))
        panel.setFrame(Self.frame(for: value ? metrics.expandedSize : metrics.collapsedSize, screen: screen), display: true)
    }
}

@MainActor
final class FloatingController {
    static let size = FloatingLayout.size

    private struct Root: View {
        let model: AppModel
        var onFormChange: () -> Void = {}
        var maximumReactionSize = FloatingLayout.maximumReactionSize
        var body: some View {
            FloatingView(model: model, maximumReactionSize: maximumReactionSize).localized(using: model)
                .onChange(of: model.petForm) { onFormChange() }
        }
    }

    private let model: AppModel
    private let onOpen: () -> Void
    private var panel: NSPanel?
    private var host: PanelHostView<Root>?
    private var clickTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?
    private var normalFrame: NSRect?
    private var speechFrame: NSRect?

    init(model: AppModel, onOpen: @escaping () -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    func show() {
        guard panel == nil else { return }
        let size = FloatingLayout.normalSize(form: model.petForm)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let panel = makePanel(frame: NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24, width: size.width, height: size.height))
        panel.level = .floating
        let host = PanelHostView(rootView: root())
        host.draggable = true
        host.onPress = { [weak self] in self?.clickTask?.cancel() }
        host.onClickCount = { [weak self] count, dragged in self?.click(count: count, dragged: dragged) }
        panel.contentView = host
        panel.setFrameAutosaveName("TokenVoyageFloating")
        panel.setContentSize(size)
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
    }

    private func root(maximum: CGSize = FloatingLayout.maximumReactionSize) -> Root {
        Root(model: model, onFormChange: { [weak self] in self?.resizeForForm() }, maximumReactionSize: maximum)
    }

    private func resizeForForm() {
        restoreFrame()
        guard let panel else { return }
        let size = FloatingLayout.normalSize(form: model.petForm)
        let visible = panel.screen?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.size = size
        frame.origin.x = min(frame.minX, visible.maxX - size.width)
        frame.origin.y = min(frame.minY, visible.maxY - size.height)
        panel.setFrame(frame, display: true)
    }

    func hide() {
        clickTask?.cancel()
        reactionTask?.cancel()
        restoreFrame()
        model.endFloatingReaction()
        panel?.close()
        panel = nil
        host = nil
    }

    private func click(count: Int, dragged: Bool) {
        clickTask?.cancel()
        switch FloatingClick.action(clickCount: count, dragged: dragged) {
        case .none: break
        case .openPostOffice: onOpen()
        case .react:
            clickTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled, let self, let panel else { return }
                reactionTask?.cancel()
                restoreFrame()
                model.reactToFloatingClick()
                let original = panel.frame
                let visible = panel.screen?.visibleFrame ?? original
                let maximum = FloatingLayout.availableReactionSize(normal: original, visible: visible)
                let size = FloatingLayout.reactionSize(text: model.floatingWords, maximum: maximum, form: model.petForm)
                let frame = FloatingLayout.reactionFrame(normal: original, size: size)
                normalFrame = original
                speechFrame = frame
                panel.setFrameAutosaveName("")
                host?.setRootView(root(maximum: maximum))
                panel.setFrame(frame, display: true)
                reactionTask = Task { [weak self, weak panel] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }
                    self.restoreFrame()
                    self.reactionTask = nil
                }
            }
        }
    }

    private func restoreFrame() {
        guard let panel, let normalFrame, let speechFrame else { return }
        let visible = panel.screen?.visibleFrame ?? normalFrame
        let frame = FloatingLayout.restoredFrame(normal: normalFrame, speech: speechFrame, current: panel.frame, visible: visible)
        model.endFloatingReaction()
        host?.setRootView(root())
        panel.setFrame(frame, display: true)
        panel.saveFrame(usingName: "TokenVoyageFloating")
        panel.setFrameAutosaveName("TokenVoyageFloating")
        self.normalFrame = nil
        self.speechFrame = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private lazy var model = AppModel(isSnapshot: ProcessInfo.processInfo.arguments.contains("--snapshot"), languageOverride: snapshotLanguage, appearanceOverride: snapshotAppearance)
    private var snapshotLanguage: Language?
    private var snapshotAppearance: ThemeScheme?
    private var appearanceObservation: NSKeyValueObservation?
    private var l10n: L10n { model.l10n }
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private lazy var notch = NotchController(model: model) { [weak self] in self?.openPostOffice() }
    private lazy var floating = FloatingController(model: model) { [weak self] in self?.openPostOffice() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--measure-dashboard") {
            // Validate before accessing any model; the normal lazy model must never be created.
            do {
                let options = try DashboardMeasurementOptions.parse(
                    arguments: arguments, dataDirectory: ProcessInfo.processInfo.environment["TOKEN_VOYAGE_DATA_DIR"]
                )!
                Theme.registerFonts()
                let measurementModel = try DashboardMeasurement.makeModel(options: options)
                Task {
                    do {
                        try await DashboardMeasurement.run(model: measurementModel)
                        exit(EXIT_SUCCESS)
                    } catch {
                        FileHandle.standardError.write(Data("Dashboard measurement failed: \(error)\n".utf8))
                        exit(EXIT_FAILURE)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
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
            do { snapshotAppearance = try SnapshotAppearance.parse(arguments: arguments) }
            catch {
                FileHandle.standardError.write(Data(l10n("snapshot.invalidAppearance").utf8))
                exit(EXIT_FAILURE)
            }
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
                await Snapshots.prepareDashboards(model: model)
                Snapshots.write(model: model, to: directory)
                NSApp.terminate(nil)
            }
            return
        }
        Theme.registerFonts()
        model.onLockChange = { [weak self] in self?.updateSurfaces() }
        model.onDisplayChange = { [weak self] in self?.updateSurfaces() }
        model.onLanguageChange = { [weak self] in
            guard let self else { return }
            mainWindow?.title = l10n("app.name")
            statusItem?.button?.setAccessibilityLabel(l10n("app.name"))
        }
        model.onAppearanceChange = { [weak self] in self?.updateWindowTheme() }
        model.onNotificationOpen = { [weak self] in self?.openMain() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated { self?.model.systemAppearanceChanged(to: ThemeScheme(appearance: app.effectiveAppearance)) }
        }
        setUpStatusItem()
        model.start()
        updateSurfaces()
    }

    private func updateSurfaces() {
        statusItem?.button?.image = statusImage()
        if model.isLocked || model.onboarding != nil {
            notch.hide()
            floating.hide()
            openMain()
        } else {
            if model.notchEnabled { notch.show() } else { notch.hide() }
            if model.floatingEnabled { floating.show() } else { floating.hide() }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage()
        item.button?.setAccessibilityLabel(l10n("app.name"))
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    private func statusImage() -> NSImage {
        guard let pets = model.catalog?.pets else { return NSImage(size: NSSize(width: 16, height: 17)) }
        let image = NSImage(cgImage: Sprites.image(model.state?.pet ?? pets.defaultID, .rest, catalog: pets), size: NSSize(width: 16, height: 17))
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeItem(model.isLocked || model.onboarding != nil ? l10n("menu.open") : l10n("menu.openPostOffice"), #selector(openMainAction)))
        if !model.isLocked && model.onboarding == nil {
            var summary = l10n("menu.today", Format.km(model.todayKm))
            if model.unread > 0 { summary += " · " + l10n("menu.newMail", Format.grouped(model.unread)) }
            addInformation(summary, to: menu)
            if let error = model.lastError { addInformation(l10n("menu.usageFailed", l10n.error(error)), to: menu) }
            menu.addItem(.separator())
            menu.addItem(makeItem(l10n("menu.refresh"), #selector(refreshAction)))
            menu.addItem(makeItem(l10n("menu.notch"), #selector(toggleNotch), checked: model.notchEnabled))
            menu.addItem(makeItem(l10n("menu.floating"), #selector(toggleFloating), checked: model.floatingEnabled))
            menu.addItem(.separator())
            menu.addItem(makeItem(l10n("menu.settings"), #selector(openSettings)))
        }
        let quit = NSMenuItem(title: l10n("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addInformation(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func makeItem(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func openMainAction() { openPostOffice() }
    @objc private func refreshAction() { model.scheduleScan(immediately: true) }
    @objc private func toggleNotch() { model.notchEnabled.toggle() }
    @objc private func toggleFloating() { model.floatingEnabled.toggle() }

    @objc private func openSettings() {
        model.showingSettings = true
        openMain()
    }

    private func openPostOffice() {
        model.openPostOffice()
        openMain()
    }

    private func openMain() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = l10n("app.name")
            window.delegate = self
            window.isReleasedWhenClosed = false
            // No fullSizeContentView: the content starts below the transparent title bar.
            window.applyTheme(model.theme)
            window.minSize = NSSize(width: 760, height: 520)
            window.contentView = NSHostingView(rootView: SaveAwareMainView(model: model, onImport: { [weak self] file in
                self?.importBackup(for: file)
            }).localized(using: model))
            window.center()
            mainWindow = window
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        model.setMainWindowPresented(true)
    }

    private func updateWindowTheme() {
        mainWindow?.applyTheme(model.theme)
    }

    func windowDidBecomeKey(_ notification: Notification) { model.setMainWindowPresented(true) }
    func windowDidResignKey(_ notification: Notification) { model.setMainWindowPresented(false) }
    func windowWillClose(_ notification: Notification) { model.setMainWindowPresented(false) }
    func windowDidMiniaturize(_ notification: Notification) { model.setMainWindowPresented(false) }
    func applicationDidHide(_ notification: Notification) { model.setMainWindowPresented(false) }

    private func importBackup(for file: SaveFile) {
        SaveArchivePanels.importSave(model: model, legacyFile: file)
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
        } else if let flow = model.onboarding {
            OnboardingView(flow: flow, onDepart: { model.completeOnboarding() })
        } else {
            MainView(model: model)
        }
    }
}

/// Used by the same main window for onboarding, normal content and save recovery.
extension NSWindow {
    func applyTheme(_ theme: AppTheme) {
        titlebarAppearsTransparent = true
        appearance = theme.scheme.appKitAppearance
        backgroundColor = NSColor(theme.background)
    }
}
