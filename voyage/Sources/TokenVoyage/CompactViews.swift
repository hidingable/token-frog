import AppKit
import SwiftUI
import VoyageCore

/// Black panel with stepped lower corners, so it reads as part of the notch.
struct SteppedBottom: Shape {
    var step: CGFloat = 4
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - step * 2))
        path.addLine(to: CGPoint(x: rect.maxX - step, y: rect.maxY - step * 2))
        path.addLine(to: CGPoint(x: rect.maxX - step, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.maxX - step * 2, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.maxX - step * 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + step * 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + step * 2, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.minX + step, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.minX + step, y: rect.maxY - step * 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - step * 2))
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

/// The fullest status that fits the shoulder: text is swapped for a shorter form, never cut off.
struct NotchShoulderStatus: View {
    @Environment(\.theme) private var theme
    var label: String
    var distance: String
    var unread: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(label)
            row(distance)
            if unread > 0 { MailBadge(count: unread) } else { row(distance) }
        }
    }

    private func row(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Theme.pixel())
                .foregroundStyle(theme.notchText)
                .lineLimit(1)
            if unread > 0 { MailBadge(count: unread) }
        }
    }
}

struct NotchCollapsedView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    var metrics: NotchMetrics

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let display = NotchDisplay(journey: state, care: model.care, now: model.now, catalog: catalog, l10n: l10n)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    SpriteView(pet: state.pet, scale: 1, moving: model.isMoving, nightcap: model.nightcapNote != nil)
                        .background(theme.paper)
                    BlockProgress(progress: state.legProgress, blocks: 6, size: 5, inactiveColor: theme.notchControlOff)
                }
                .frame(width: metrics.shoulderWidth, alignment: .center)
                Color.clear.frame(width: metrics.notchWidth)
                NotchShoulderStatus(
                    label: display.status,
                    distance: display.compactStatus,
                    unread: model.unread
                )
                .frame(width: metrics.shoulderWidth, alignment: .center)
            }
            .frame(width: metrics.collapsedSize.width, height: metrics.collapsedSize.height)
            .background(theme.notchBackground, in: SteppedBottom(step: 2))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(display.status)
        }
    }
}

struct NotchExpandedView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    var metrics: NotchMetrics
    var onOpen: () -> Void = {}

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let display = NotchDisplay(journey: state, care: model.care, now: model.now, catalog: catalog, l10n: l10n)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(model.petName)
                        .frame(width: metrics.shoulderWidth + (metrics.expandedSize.width - metrics.collapsedSize.width) / 2)
                    Color.clear.frame(width: metrics.notchWidth)
                    Group {
                        Button(action: onOpen) {
                            if model.unread > 0 { MailBadge(count: model.unread) } else { Text(l10n("compact.open")) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n("menu.openPostOffice"))
                    }
                    .frame(width: metrics.shoulderWidth + (metrics.expandedSize.width - metrics.collapsedSize.width) / 2)
                }
                .font(Theme.pixel())
                .foregroundStyle(theme.notchTextMuted)
                .frame(height: metrics.collapsedSize.height)

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
                            Text(Format.km(model.todayKm))
                                .font(Theme.pixel(24))
                                .foregroundStyle(theme.notchMileageText)
                            Text(l10n("compact.fuel", l10n.tokens(model.todayTokens)))
                            if let totals = model.todayTotals {
                                Text(l10n("compact.cost", Format.cost(totals.cost)))
                                    .foregroundStyle(theme.notchTextMuted)
                            }
                            Text(display.status).fixedSize(horizontal: false, vertical: true)
                            BlockProgress(progress: state.legProgress, blocks: 12, size: 6, inactiveColor: theme.notchControlOff)
                            Text(display.remainingAndFund)
                                .foregroundStyle(theme.notchTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(model.todayVehicles.prefix(1), id: \.client) { share in
                                Text(l10n("vehicle.share", l10n.vehicle(share.client), share.percent))
                                    .foregroundStyle(theme.notchTextMuted)
                            }
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
            .background(theme.notchBackground, in: SteppedBottom(step: 4))
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
