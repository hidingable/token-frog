import AppKit
import Observation
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
    // The notch keeps a fixed SwiftUI canvas while AppKit changes only the window's hit-test bounds.
    var contentFrame: CGRect? { didSet { needsLayout = true } }
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
        hosting.frame = contentFrame ?? bounds
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

/// All sizes are points. Local rectangles use SwiftUI's top-left origin; screen frames use AppKit's.
struct NotchMetrics: Equatable {
    static let fallbackNotchSize = CGSize(width: 185, height: 32)
    static let chipGap: CGFloat = 6
    static let chipPadding: CGFloat = 10
    static let chipContentGap: CGFloat = 6
    static let maximumChipHeight: CGFloat = 24
    static let mailChipWidth: CGFloat = 32

    var notchSize: CGSize
    var menuBarHeight: CGFloat
    var leftChipWidth: CGFloat
    var rightChipWidth: CGFloat
    var notchCenterOffsetX: CGFloat = 0
    var expandedWidth: CGFloat

    init(notchSize: CGSize = Self.fallbackNotchSize, menuBarHeight: CGFloat,
         leftChipWidth: CGFloat = 82, rightChipWidth: CGFloat = 0, notchCenterOffsetX: CGFloat = 0,
         expandedWidth: CGFloat? = nil) {
        self.notchSize = notchSize
        self.menuBarHeight = menuBarHeight
        self.leftChipWidth = leftChipWidth
        self.rightChipWidth = rightChipWidth
        self.notchCenterOffsetX = notchCenterOffsetX
        self.expandedWidth = expandedWidth ?? max(notchSize.width + 480, 560)
    }

    var chipHeight: CGFloat { min(Self.maximumChipHeight, menuBarHeight) }
    var bodyRect: CGRect {
        CGRect(x: leftChipWidth + Self.chipGap, y: 0, width: notchSize.width, height: notchSize.height)
    }
    var leftChipRect: CGRect {
        CGRect(x: 0, y: (menuBarHeight - chipHeight) / 2, width: leftChipWidth, height: chipHeight)
    }
    var rightChipRect: CGRect {
        CGRect(x: bodyRect.maxX + Self.chipGap, y: leftChipRect.minY, width: rightChipWidth, height: chipHeight)
    }
    var collapsedSize: CGSize {
        CGSize(width: bodyRect.maxX + (rightChipWidth > 0 ? Self.chipGap + rightChipWidth : 0),
               height: max(notchSize.height, leftChipRect.maxY))
    }
    var expandedSize: CGSize { CGSize(width: expandedWidth, height: menuBarHeight + 240) }

    func bodyFrame(screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.midX + notchCenterOffsetX - notchSize.width / 2,
               y: screenFrame.maxY - notchSize.height, width: notchSize.width, height: notchSize.height)
    }

    func frame(screenFrame: CGRect, expanded: Bool) -> CGRect {
        let body = bodyFrame(screenFrame: screenFrame)
        let size = expanded ? expandedSize : collapsedSize
        return CGRect(x: expanded ? body.midX - size.width / 2 : body.minX - bodyRect.minX,
                      y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Includes both chips until they have faded, even when a long next stop exceeds the panel's left edge.
    func animationFrame(screenFrame: CGRect) -> CGRect {
        frame(screenFrame: screenFrame, expanded: true).union(frame(screenFrame: screenFrame, expanded: false))
    }

    @MainActor private static func nativeNotch(_ screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    @MainActor init(screen: NSScreen) {
        let native = Self.nativeNotch(screen)
        let reference = NSScreen.screens.compactMap { Self.nativeNotch($0)?.size }.first ?? Self.fallbackNotchSize
        // visibleFrame excludes this display's menu bar (and, on a notched display, the camera strip).
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        self.init(notchSize: native?.size ?? reference,
                  menuBarHeight: topInset > 0 ? topInset : NSStatusBar.system.thickness,
                  notchCenterOffsetX: native.map { $0.midX - screen.frame.midX } ?? 0,
                  expandedWidth: native.map { max($0.width + 480, 560) } ?? 560)
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

/// Owns the transition independently of NSPanel, including cancellation and the final hit-test bounds.
@MainActor @Observable
final class NotchPresentation {
    private(set) var metrics: NotchMetrics
    private(set) var canvasFrame: CGRect
    private(set) var expanded = false
    private(set) var shellExpanded = false
    private(set) var contentVisible = false
    private(set) var chipsVisible = true
    private(set) var leftChipVisible = true
    private(set) var mailVisible: Bool
    private(set) var reduceMotion = false
    private(set) var transitioning = false

    let screenFrame: CGRect
    let animationsEnabled: Bool
    @ObservationIgnored var onFrameChange: (CGRect) -> Void = { _ in }
    @ObservationIgnored var onInteractiveChange: (Bool) -> Void = { _ in }
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var transitionID = 0
    @ObservationIgnored private var layoutID = 0
    @ObservationIgnored private var layoutChanging = false
    @ObservationIgnored private var pendingLayouts = 0

    init(metrics: NotchMetrics, screenFrame: CGRect, animationsEnabled: Bool) {
        self.metrics = metrics
        self.screenFrame = screenFrame
        self.animationsEnabled = animationsEnabled
        canvasFrame = metrics.frame(screenFrame: screenFrame, expanded: false)
        mailVisible = metrics.rightChipWidth > 0
    }

    func cancel() {
        hoverTask?.cancel()
        contentTask?.cancel()
        transitionID += 1
        layoutID += 1
    }

    func setReduceMotion(_ value: Bool) {
        guard reduceMotion != value else { return }
        reduceMotion = value
        // A preference change during a spring settles immediately into the current requested state.
        settle()
    }

    private func resize(_ frame: CGRect) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { canvasFrame = frame }
        onFrameChange(frame)
    }

    private func settle() {
        contentTask?.cancel()
        transitionID += 1
        layoutID += 1
        layoutChanging = false
        pendingLayouts = 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transitioning = false
            shellExpanded = expanded
            contentVisible = expanded
            chipsVisible = !expanded
            leftChipVisible = true
            mailVisible = metrics.rightChipWidth > 0
        }
        resize(metrics.frame(screenFrame: screenFrame, expanded: expanded))
        onInteractiveChange(expanded)
    }

    func updateMetrics(_ next: NotchMetrics) {
        guard next != metrics else { return }
        guard animationsEnabled else { metrics = next; settle(); return }
        layoutID += 1
        layoutChanging = true
        let id = layoutID
        let hasMail = next.rightChipWidth > 0
        let mailChanged = mailVisible != hasMail
        let widthChanged = next.leftChipWidth != metrics.leftChipWidth
        pendingLayouts = (mailChanged ? 1 : 0) + (widthChanged ? 1 : 0)
        let target = transitioning ? next.animationFrame(screenFrame: screenFrame)
            : next.frame(screenFrame: screenFrame, expanded: expanded)
        // Retain the old bounds until the width animation and disappearing mail have finished.
        resize(canvasFrame.union(target))
        if widthChanged && reduceMotion {
            withAnimation(.easeOut(duration: 0.08), completionCriteria: .removed) {
                leftChipVisible = false
            } completion: { [weak self] in
                guard let self, self.layoutID == id else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.metrics = next }
                withAnimation(.easeIn(duration: 0.1), completionCriteria: .removed) {
                    self.leftChipVisible = true
                } completion: { [weak self] in self?.finishLayout(id: id) }
            }
        } else if widthChanged {
            withAnimation(.easeInOut(duration: 0.18), completionCriteria: .removed) {
                metrics = next
                leftChipVisible = true
            } completion: { [weak self] in self?.finishLayout(id: id) }
        } else {
            metrics = next
        }
        if mailChanged {
            let animation: Animation = hasMail && !reduceMotion
                ? .spring(response: 0.22, dampingFraction: 1) : .easeOut(duration: 0.15)
            withAnimation(animation, completionCriteria: .removed) {
                mailVisible = hasMail
            } completion: { [weak self] in self?.finishLayout(id: id) }
        }
        if !widthChanged && !mailChanged { finishLayout(id: id) }
    }

    private func finishLayout(id: Int) {
        guard layoutID == id else { return }
        pendingLayouts = max(0, pendingLayouts - 1)
        guard pendingLayouts == 0 else { return }
        layoutChanging = false
        if !transitioning { resize(metrics.frame(screenFrame: screenFrame, expanded: expanded)) }
    }

    private func finishResizing(expanded: Bool) {
        let frame = metrics.frame(screenFrame: screenFrame, expanded: expanded)
        resize(layoutChanging ? canvasFrame.union(frame) : frame)
    }

    func hover(_ inside: Bool) {
        hoverTask?.cancel()
        if inside { setExpanded(true) }
        else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }

    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        contentTask?.cancel()
        transitionID += 1
        let id = transitionID
        expanded = value
        onInteractiveChange(false)
        guard animationsEnabled else { settle(); return }
        transitioning = true
        // AppKit resizes first; SwiftUI then animates inside a canvas covering both endpoints.
        resize(canvasFrame.union(metrics.animationFrame(screenFrame: screenFrame)))
        if value {
            contentTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.transitionID == id else { return }
                withAnimation(.easeOut(duration: 0.1)) { self.chipsVisible = false }
                withAnimation(self.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8),
                              completionCriteria: .removed) {
                    self.shellExpanded = true
                } completion: { [weak self] in
                    guard let self, self.transitionID == id else { return }
                    self.transitioning = false
                    self.finishResizing(expanded: true)
                }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, self.transitionID == id else { return }
                withAnimation(.easeOut(duration: 0.15)) { self.contentVisible = true }
                self.onInteractiveChange(true)
            }
        } else {
            withAnimation(.easeOut(duration: 0.1), completionCriteria: .removed) {
                contentVisible = false
            } completion: { [weak self] in
                guard let self, self.transitionID == id else { return }
                withAnimation(self.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.8),
                              completionCriteria: .removed) {
                    self.shellExpanded = false
                } completion: { [weak self] in
                    guard let self, self.transitionID == id else { return }
                    self.transitioning = false
                    self.finishResizing(expanded: false)
                    withAnimation(.easeIn(duration: 0.15)) { self.chipsVisible = true }
                }
            }
        }
    }
}

/// Every display uses the same shell and chip layout, anchored to that display's camera position.
@MainActor
private final class NotchSurface {
    private struct Root: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let model: AppModel
        let presentation: NotchPresentation
        let onOpen: () -> Void

        var body: some View {
            let metrics = presentation.metrics
            let centerX = metrics.expandedSize.width / 2
            let chipY = metrics.menuBarHeight / 2
            ZStack(alignment: .topLeading) {
                if reduceMotion {
                    shell(expanded: false).opacity(presentation.shellExpanded ? 0 : 1)
                        .position(x: centerX, y: metrics.expandedSize.height / 2)
                    shell(expanded: true).opacity(presentation.shellExpanded ? 1 : 0)
                        .position(x: centerX, y: metrics.expandedSize.height / 2)
                } else {
                    shell(expanded: presentation.shellExpanded)
                        .position(x: centerX, y: metrics.expandedSize.height / 2)
                }
                if presentation.expanded || presentation.transitioning {
                    NotchExpandedView(model: model, metrics: metrics, onOpen: onOpen, drawsShell: false)
                        .mask { shell(expanded: reduceMotion || presentation.shellExpanded) }
                        .opacity(presentation.contentVisible ? 1 : 0)
                        .allowsHitTesting(presentation.contentVisible)
                        .accessibilityHidden(!presentation.contentVisible)
                        .position(x: centerX, y: metrics.expandedSize.height / 2)
                        .transition(.identity)
                }
                NotchLeftChip(model: model, metrics: metrics)
                    .opacity(presentation.chipsVisible && presentation.leftChipVisible ? 1 : 0)
                    .accessibilityHidden(!presentation.chipsVisible)
                    .position(x: centerX - metrics.notchSize.width / 2 - NotchMetrics.chipGap - metrics.leftChipWidth / 2, y: chipY)
                if presentation.mailVisible {
                    NotchMailChip(height: metrics.chipHeight)
                        .opacity(presentation.chipsVisible ? 1 : 0)
                        .accessibilityHidden(!presentation.chipsVisible)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                        .position(x: centerX + metrics.notchSize.width / 2 + NotchMetrics.chipGap + NotchMetrics.mailChipWidth / 2, y: chipY)
                }
            }
            .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height, alignment: .topLeading)
            .localized(using: model)
            .onChange(of: metrics.fitting(model: model)) { _, next in presentation.updateMetrics(next) }
            .onChange(of: reduceMotion, initial: true) { _, next in presentation.setReduceMotion(next) }
        }

        private func shell(expanded: Bool) -> some View {
            let metrics = presentation.metrics
            return NotchShell(size: expanded ? metrics.expandedSize : metrics.notchSize,
                              topRadius: expanded ? NotchShell.panelTopRadius : 0,
                              bottomRadius: expanded ? NotchShell.panelBottomRadius : NotchShell.bodyBottomRadius)
                .fill(.black)
                .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height)
        }
    }

    private let panel: NSPanel
    private let host: PanelHostView<Root>
    private let presentation: NotchPresentation

    init(model: AppModel, screen: NSScreen, onOpen: @escaping () -> Void) {
        let metrics = NotchMetrics(screen: screen).fitting(model: model)
        presentation = NotchPresentation(metrics: metrics, screenFrame: screen.frame, animationsEnabled: !model.isSnapshotMode)
        host = PanelHostView(rootView: Root(model: model, presentation: presentation, onOpen: onOpen))
        panel = makePanel(frame: presentation.canvasFrame)
        let contentFrame = metrics.frame(screenFrame: screen.frame, expanded: true)
        host.contentFrame = contentFrame.offsetBy(dx: -presentation.canvasFrame.minX, dy: -presentation.canvasFrame.minY)
        presentation.onFrameChange = { [weak panel, weak host] frame in
            host?.contentFrame = contentFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            panel?.setFrame(frame, display: true)
            host?.layoutSubtreeIfNeeded()
        }
        presentation.onInteractiveChange = { [weak host] value in host?.interactiveContent = value }
        host.onClick = onOpen
        host.onHover = { [weak presentation] inside in presentation?.hover(inside) }
        panel.level = .statusBar
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func close() {
        presentation.cancel()
        panel.close()
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
                let size = FloatingLayout.reactionSize(text: model.floatingWords, sponsorTags: model.floatingSponsorTags, maximum: maximum, form: model.petForm)
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
