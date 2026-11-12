import AppKit
import SwiftUI
import VoyageCore

/// One continuous shell: straight-topped camera body, or concave top flares and rounded panel bottom.
struct NotchShell: Shape {
    static let bodyBottomRadius: CGFloat = 10
    static let panelTopRadius: CGFloat = 8
    static let panelBottomRadius: CGFloat = 22

    var size: CGSize
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = Self.bodyBottomRadius

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), AnimatablePair(topRadius, bottomRadius)) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Keep spring overshoot within the expanded envelope, so the window never clips the shell.
        let width = min(rect.width, max(0, size.width))
        let height = min(rect.height, max(0, size.height))
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        let top = min(max(0, topRadius), width / 4, height / 2)
        let bottom = min(max(0, bottomRadius), (width - 2 * top) / 2, height - top)
        let k: CGFloat = 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: body.minX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        path.addCurve(to: CGPoint(x: body.maxX - top, y: body.minY + top),
                      control1: CGPoint(x: body.maxX - k * top, y: body.minY),
                      control2: CGPoint(x: body.maxX - top, y: body.minY + (1 - k) * top))
        path.addLine(to: CGPoint(x: body.maxX - top, y: body.maxY - bottom))
        path.addCurve(to: CGPoint(x: body.maxX - top - bottom, y: body.maxY),
                      control1: CGPoint(x: body.maxX - top, y: body.maxY - (1 - k) * bottom),
                      control2: CGPoint(x: body.maxX - top - (1 - k) * bottom, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + top + bottom, y: body.maxY))
        path.addCurve(to: CGPoint(x: body.minX + top, y: body.maxY - bottom),
                      control1: CGPoint(x: body.minX + top + (1 - k) * bottom, y: body.maxY),
                      control2: CGPoint(x: body.minX + top, y: body.maxY - (1 - k) * bottom))
        path.addLine(to: CGPoint(x: body.minX + top, y: body.minY + top))
        path.addCurve(to: CGPoint(x: body.minX, y: body.minY),
                      control1: CGPoint(x: body.minX + top, y: body.minY + (1 - k) * top),
                      control2: CGPoint(x: body.minX + k * top, y: body.minY))
        path.closeSubpath()
        return path
    }
}

struct MailBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    var count: Int
    var body: some View {
        Text(l10n("compact.mail", Format.grouped(count)))
            .font(Theme.pixel())
            .foregroundStyle(theme.onNewMail)
            .padding(.horizontal, 4)
            .background(theme.newMailFill)
    }
}

/// Full next-stop text or the original six progress blocks; text is never truncated.
struct NotchCollapsedProgress: View {
    @Environment(\.theme) private var theme
    var destination: String?
    var progress: Double

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let destination {
                Text(destination).font(Theme.pixel()).foregroundStyle(theme.notchText)
                    .fixedSize()
            }
            BlockProgress(progress: progress, blocks: 6, size: 5, inactiveColor: theme.notchControlOff)
        }
    }
}

/// Palette-backed raster marks share the sprite pipeline's integer grid and nearest-neighbour drawing.
enum NotchPixelMark {
    case flag, envelope

    func image(theme: AppTheme) -> CGImage {
        let rows: [String]
        switch self {
        case .flag:
            rows = ["t.........", "taaaaaaaa.", "taaaaaaaa.", "taaaaaaa..", "taaaaaa...",
                    "taaaaaaa..", "taaaaaaaa.", "t.........", "t.........", "t.........",
                    "t.........", "t.........", "t........."]
        case .envelope:
            rows = ["rrrrrrrrrrrr", "rprrrrrrrrpr", "rrprrrrrrprr", "rrrprrrrprrr", "rrrrpppprrrr",
                    "rrrrrrrrrrrr", "rrrrrrrrrrrr", "rrrrrrrrrrrr", "rrrrrrrrrrrr"]
        }
        let palette: [Character: UInt32] = ["t": theme.rgb(.notchText), "a": theme.rgb(.notchMileageText),
                                            "r": theme.rgb(.newMailFill), "p": theme.rgb(.paper)]
        return PixelImage.make(width: rows[0].count, height: rows.count,
                               pixels: rows.flatMap { row in row.map { palette[$0] } })
    }
}

extension NotchCollapsedProgress {
    // Preserve the previous next-stop slot: 98 - 16 pt pet - 6 pt gap - 20 pt padding.
    static let maximumNextStopWidth: CGFloat = 56
    static let blocksWidth: CGFloat = 40

    @MainActor static func width(destination: String?) -> CGFloat {
        guard let destination else { return blocksWidth }
        // Measure the same SwiftUI font as the displayed text, including its system fallback.
        let text = NSHostingView(rootView: Text(destination).font(Theme.pixel()).fixedSize())
        let width = ceil(text.fittingSize.width)
        return width <= maximumNextStopWidth ? width : blocksWidth
    }
}

extension NotchMetrics {
    @MainActor func fitting(model: AppModel) -> Self {
        var result = self
        if let state = model.state, let catalog = model.catalog {
            let display = NotchDisplay(journey: state, care: model.care, now: model.now, catalog: catalog, l10n: model.l10n)
            let destination = display.pending.map { model.l10n("compact.destination", $0.destination) }
            result.leftChipWidth = 16 + Self.chipContentGap + NotchCollapsedProgress.width(destination: destination)
                + (display.showsFlag ? Self.chipContentGap + 10 : 0) + 2 * Self.chipPadding
        }
        result.rightChipWidth = model.unread > 0 ? Self.mailChipWidth : 0
        return result
    }
}

struct NotchLeftChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    var metrics: NotchMetrics

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let display = NotchDisplay(journey: state, care: model.care, now: model.now, catalog: catalog, l10n: l10n)
            HStack(spacing: NotchMetrics.chipContentGap) {
                SpriteView(pet: state.pet, scale: 1, moving: model.isMoving, nightcap: model.nightcapNote != nil)
                    .scaleEffect(x: display.petFacesLeft ? -1 : 1, y: 1)
                    .background(theme.paper)
                let destination = display.pending.map { l10n("compact.destination", $0.destination) }
                NotchCollapsedProgress(destination: destination, progress: state.legProgress)
                    .frame(width: NotchCollapsedProgress.width(destination: destination))
                if display.showsFlag {
                    Image(decorative: NotchPixelMark.flag.image(theme: theme), scale: 1).interpolation(.none)
                }
            }
            .padding(.horizontal, NotchMetrics.chipPadding)
            .frame(width: metrics.leftChipWidth, height: metrics.chipHeight)
            .background(.black, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display.accessibilityLabel(unread: model.unread, l10n: l10n))
        }
    }
}

struct NotchMailChip: View {
    @Environment(\.theme) private var theme
    var height: CGFloat
    var body: some View {
        Image(decorative: NotchPixelMark.envelope.image(theme: theme), scale: 1).interpolation(.none)
            .frame(width: NotchMetrics.mailChipWidth, height: height)
            .background(.black, in: Capsule())
    }
}

/// Static final-state rendering; the live panel uses these same chips and shell during its transition.
struct NotchCollapsedView: View {
    let model: AppModel
    var metrics: NotchMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            NotchShell(size: metrics.notchSize).fill(.black)
                .frame(width: metrics.notchSize.width, height: metrics.notchSize.height)
                .offset(x: metrics.bodyRect.minX)
            NotchLeftChip(model: model, metrics: metrics)
                .offset(x: metrics.leftChipRect.minX, y: metrics.leftChipRect.minY)
            if metrics.rightChipWidth > 0 {
                NotchMailChip(height: metrics.chipHeight)
                    .offset(x: metrics.rightChipRect.minX, y: metrics.rightChipRect.minY)
            }
        }
        .frame(width: metrics.collapsedSize.width, height: metrics.collapsedSize.height, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }
}

struct NotchExpandedView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    var metrics: NotchMetrics
    var onOpen: () -> Void = {}
    var drawsShell = true

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let display = NotchDisplay(journey: state, care: model.care, now: model.now, catalog: catalog, l10n: l10n)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(model.petName)
                        .frame(width: (metrics.expandedSize.width - metrics.notchSize.width) / 2)
                    Color.clear.frame(width: metrics.notchSize.width)
                    Group {
                        Button(action: onOpen) {
                            if model.unread > 0 { MailBadge(count: model.unread) } else { Text(l10n("compact.open")) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n("menu.openPostOffice"))
                    }
                    .frame(width: (metrics.expandedSize.width - metrics.notchSize.width) / 2)
                }
                .font(Theme.pixel())
                .foregroundStyle(theme.notchTextMuted)
                .frame(height: max(metrics.notchSize.height, metrics.menuBarHeight))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: onOpen) {
                            JourneyMapView(state: state, catalog: catalog,
                                           availableWidth: min(metrics.expandedSize.width - 32 - 12 - 230, model.roadClueText == nil ? .infinity : 300),
                                           borderColor: theme.notchControlOff, animate: !model.isSnapshotMode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n("menu.openPostOffice"))
                        if let clue = model.roadClueText {
                            Text(l10n("journey.roadClue")).font(Theme.pixel()).foregroundStyle(theme.notchTextMuted)
                            Text(clue).font(.system(size: 12)).lineSpacing(2).foregroundStyle(theme.notchText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: metrics.expandedSize.width - 32 - 12 - 230, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        if let pending = display.pending {
                            Text(l10n("notch.nextStop")).foregroundStyle(theme.notchTextMuted)
                            Text(pending.destination).font(Theme.pixel(24)).foregroundStyle(theme.notchMileageText)
                            Text(pending.distanceAndBand)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(l10n("notch.carrying")).foregroundStyle(theme.notchTextMuted)
                            let owned = catalog.items.all.filter { model.care?.bag.owned.contains($0.id) == true }
                            // The carried item always shows; the notch has room for three chips, the ritual lists the whole bag.
                            let chips = (owned.filter { $0.id == pending.carriedItemID } + owned.filter { $0.id != pending.carriedItemID }).prefix(3)
                            if chips.isEmpty {
                                Text(l10n("home.status.emptyBag"))
                            } else {
                                HStack(spacing: 4) {
                                    ForEach(Array(chips)) { item in
                                        let selected = item.id == pending.carriedItemID
                                        Button { model.setTodayItem(item.id) } label: {
                                            Text(l10n.itemName(item)).lineLimit(1)
                                                .padding(.horizontal, 5).padding(.vertical, 3)
                                                .foregroundStyle(selected ? theme.notchBackground : theme.notchTextMuted)
                                                .background(selected ? theme.notchMileageText : theme.notchControlOff)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(model.isLocked)
                                        .accessibilityLabel(l10n("notch.changeItem"))
                                        .accessibilityValue(l10n.itemName(item))
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                    }
                                }
                            }
                            Button(l10n("notch.departNow")) { model.departNow() }
                                .buttonStyle(.plain)
                                .padding(6).background(theme.notchControlOff)
                                .accessibilityLabel(l10n("notch.departNow"))
                                .disabled(!model.canDepartNow)
                            Text(pending.countdown).foregroundStyle(theme.notchTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if state.phase == .outbound {
                                Text(l10n("notch.headingTo")).foregroundStyle(theme.notchTextMuted)
                                Text(display.destination).font(Theme.pixel(24)).foregroundStyle(theme.notchMileageText)
                            } else {
                                Text(display.status).fixedSize(horizontal: false, vertical: true)
                            }
                            BlockProgress(progress: state.legProgress, blocks: 12, size: 6, inactiveColor: theme.notchControlOff)
                            if state.phase == .outbound {
                                Text(l10n("journey.remaining", Format.km(state.remainingKm)))
                            }
                            Text(l10n("notch.todayDistance", Format.km(model.todayKm)))
                                .foregroundStyle(theme.notchTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Theme.pixel())
                    .foregroundStyle(theme.notchText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height, alignment: .top)
            .clipped()
            .background {
                if drawsShell {
                    NotchShell(size: metrics.expandedSize, topRadius: NotchShell.panelTopRadius,
                               bottomRadius: NotchShell.panelBottomRadius).fill(.black)
                }
            }
        }
    }
}

enum FloatingLayout {
    static let size = CGSize(width: 150, height: 48)
    static func normalSize(form: PetForm) -> CGSize {
        form == .hatchling ? size : CGSize(width: 158, height: 56)
    }
    static let maximumReactionSize = CGSize(width: 300, height: 128)

    static func reactionSize(text: String, sponsorTags: [String] = [], maximum: CGSize = maximumReactionSize, form: PetForm = .hatchling) -> CGSize {
        let normal = normalSize(form: form)
        let inset: CGFloat = form == .hatchling ? 50 : 58
        let font = NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        // Sprite (32), gap (6), and the panel's horizontal padding (12).
        let tagAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        let tagWidth = sponsorTags.map { ceil(($0 as NSString).size(withAttributes: tagAttributes).width) + 12 + inset }.max() ?? 0
        let width = min(maximum.width, max(normal.width, ceil((text as NSString).size(withAttributes: attributes).width) + inset, tagWidth))
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width - inset, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let twoLines = ceil((font.ascender - font.descender + font.leading) * 2 + 2)
        let tagHeight = sponsorTags.reduce(CGFloat.zero) { total, tag in
            let bounds = (tag as NSString).boundingRect(with: CGSize(width: width - inset - 12, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: tagAttributes)
            return total + ceil(bounds.height) + 4 + 4 // Tag padding and the stack gap.
        }
        let height = max(normal.height, ceil(min(bounds.height, twoLines)) + 24 + tagHeight)
        return CGSize(width: width, height: min(maximum.height, height))
    }

    static func availableReactionSize(normal: CGRect, visible: CGRect) -> CGSize {
        CGSize(width: min(maximumReactionSize.width, visible.maxX - normal.minX),
               height: min(maximumReactionSize.height, normal.maxY - visible.minY))
    }

    static func reactionFrame(normal: CGRect, size: CGSize) -> CGRect {
        CGRect(x: normal.minX, y: normal.maxY - size.height, width: size.width, height: size.height)
    }

    static func restoredFrame(normal: CGRect, speech: CGRect, current: CGRect, visible: CGRect) -> CGRect {
        let x = normal.minX + current.minX - speech.minX
        let y = normal.minY + current.maxY - speech.maxY
        return CGRect(x: max(visible.minX, min(x, visible.maxX - normal.width)),
                      y: max(visible.minY, min(y, visible.maxY - normal.height)), width: normal.width, height: normal.height)
    }
}

struct FloatingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    var maximumReactionSize = FloatingLayout.maximumReactionSize

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            HStack(spacing: 6) {
                SpriteView(pet: state.pet, scale: 2, form: model.petForm, moving: model.isMoving, nightcap: model.nightcapNote != nil)
                    .background(theme.paper)
                    .offset(y: model.floatingJump ? -4 : 0)
                if model.floatingReaction {
                    if model.floatingSponsorTags.isEmpty {
                        reactionWords
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.floatingSponsorTags, id: \.self) { SponsorTag(text: $0).layoutPriority(1) }
                            Text(model.floatingWords).font(.system(size: 12)).lineSpacing(2).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, surfaceSize.height > 56 ? 6 : 0)
                        .foregroundStyle(theme.text)
                        .frame(width: surfaceSize.width - (model.petForm == .hatchling ? 50 : 58), alignment: .leading)
                        .frame(height: max(0, surfaceSize.height - 12), alignment: .top)
                        .clipped()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.km(model.todayKm)).foregroundStyle(theme.mileageText)
                        HStack(spacing: 4) {
                            Text(l10n("compact.destination", l10n.cityName(catalog.city(state.targetCityId))))
                                .foregroundStyle(theme.text)
                            if model.unread > 0 { Rectangle().fill(theme.newMailFill).frame(width: 6, height: 6) }
                        }
                    }
                    .font(Theme.pixel())
                    Spacer(minLength: 0)
                }
            }
            .padding(6)
            .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .leading)
            .background(theme.background)
            .pixelBorder(theme.border)
        }
    }

    private var surfaceSize: CGSize {
        model.floatingReaction ? FloatingLayout.reactionSize(text: model.floatingWords, sponsorTags: model.floatingSponsorTags, maximum: maximumReactionSize, form: model.petForm) : FloatingLayout.normalSize(form: model.petForm)
    }

    private var reactionWords: some View {
        Text(model.floatingWords).font(.system(size: 12)).lineSpacing(2)
            .lineLimit(2).padding(.vertical, surfaceSize.height > 48 ? 6 : 0)
            .foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            .frame(width: surfaceSize.width - (model.petForm == .hatchling ? 50 : 58), alignment: .leading)
    }
}
