import SwiftUI
import VoyageCore

struct HomeTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedSouvenir: String?

    var body: some View {
        GeometryReader { proxy in
            if let state = model.state, let catalog = model.catalog, let care = model.care {
                let layout = HomeLayout(windowWidth: proxy.size.width)
                ScrollView {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            RoomSceneView(model: model, availableWidth: layout.roomWidth, selectedSouvenir: $selectedSouvenir)
                            VStack(alignment: .leading, spacing: 12) {
                                HomeCard(grows: true) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(model.petName).font(Theme.pixel(24))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(l10n.stage(Stage.current(companionDays: care.companionDays.count)))
                                                .foregroundStyle(theme.textMuted)
                                        }
                                        Spacer(minLength: 4)
                                        VStack(alignment: .trailing, spacing: 10) {
                                            if state.petIsHome { Button(l10n("home.profile")) { model.showProfile() } }
                                            if model.canArrangeRoom {
                                                Button(l10n("room.arrange")) { model.showRoomArrangement() }
                                                    .accessibilityLabel(l10n("room.arrange"))
                                            }
                                        }.buttonStyle(.plain).foregroundStyle(theme.textMuted).fixedSize()
                                    }
                                    let habit = ProfileDisplay.habitSummary(care.habits, l10n: l10n)
                                    Text(l10n("home.companionDay", care.companionDays.count)
                                         + (habit.map { " · " + $0 } ?? ""))
                                        .foregroundStyle(theme.textMuted)
                                }
                                Button { model.activateHomeAction() } label: {
                                    Text(model.unread > 0 ? l10n("home.openMail") : l10n("home.findPet"))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundStyle(model.unread > 0 ? theme.newMailText : theme.text)
                                        .frame(maxWidth: .infinity).padding(12)
                                        .background(model.unread > 0 ? theme.newMailFill : theme.surfaceRaised)
                                        .pixelBorder(model.unread > 0 ? theme.newMailFill : theme.textMuted)
                                }
                                .buttonStyle(.plain)
                                HomeCard(grows: true) {
                                    Text(l10n("home.now")).foregroundStyle(theme.textMuted)
                                    let status = HomeStatusDisplay(journey: state, care: care, now: model.now, catalog: catalog, l10n: l10n)
                                    Text(status.title).fixedSize(horizontal: false, vertical: true)
                                    Text(status.detail).foregroundStyle(theme.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let fund = status.fund { Text(fund).foregroundStyle(theme.mileageText) }
                                }
                                WeekCard(model: model, care: care)
                            }
                            .frame(width: layout.rightWidth)
                        }
                        // Both columns take the taller one's height; the floor and the growing cards absorb the rest.
                        .fixedSize(horizontal: false, vertical: true)
                        WishCard(model: model, care: care)
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        let scale = CGFloat(RoomLayout.scale(availableWidth: layout.roomWidth))
                        let shelfX = floor((proxy.size.width - 24 - layout.contentWidth) / 2) + 78 * scale
                        let shelf = CGRect(x: shelfX, y: 37 * scale, width: 76 * scale, height: 18 * scale)
                        let inPlacement = model.canArrangeRoom && RoomSlot.allCases.contains { slot in
                            RoomLayout.slotBounds(slot).insetBy(dx: -1, dy: -1)
                                .applying(CGAffineTransform(scaleX: scale, y: scale))
                                .offsetBy(dx: shelfX - 78 * scale, dy: 0).contains(tap.location)
                        }
                        if !shelf.contains(tap.location) && !inPlacement { selectedSouvenir = nil }
                    })
                    .padding(12)
                }
            }
        }
        .font(Theme.pixel()).foregroundStyle(theme.text)
        .onAppear { model.postOfficeDidDisplay() }
    }
}

struct HomeCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var grows = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: grows ? .infinity : nil, alignment: .topLeading)
            .padding(12).background(theme.surfaceRaised).pixelBorder(theme.border)
    }
}

private struct WeekCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let care: CareState

    var body: some View {
        let week = WeekDisplay(care: care, now: model.now, l10n: l10n)
        HomeCard {
            HStack(alignment: .top) {
                Text(l10n("home.week"))
                Spacer(minLength: 8)
                if let progress = week.progressText(l10n: l10n) {
                    Text(progress).foregroundStyle(theme.textMuted).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 0) {
                ForEach(week.days) { day in
                    VStack(spacing: 4) {
                        Text(day.label)
                        Text(day.stamped ? "●" : "·")
                    }
                    .foregroundStyle(day.stamped || day.today ? theme.text : theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(l10n.day(day.id, full: true))
                    .accessibilityValue(day.stamped ? l10n("home.week.stamped") : "")
                }
            }
            Text(l10n("home.week.noStreak")).foregroundStyle(theme.textMuted)
            if let title = week.boxButton(l10n: l10n) {
                CollectionAction(title: title) { model.showBoxes() }
            }
        }
    }
}

private struct RoomSceneView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let availableWidth: CGFloat
    @Binding var selectedSouvenir: String?
    @State private var floorNote: FloorNote?

    private struct FloorNote: Identifiable {
        var id: String
        var title: String
        var text: String
        var sponsorTags: [String] = []
    }

    var body: some View {
        if let state = model.state, let care = model.care, let catalog = model.catalog {
            let scale = RoomLayout.scale(availableWidth: availableWidth)
            let factor = CGFloat(scale)
            let width = CGFloat(RoomLayout.width * scale)
            let height = CGFloat(RoomLayout.height * scale)
            let shelf = RoomLayout.shelf(care).compactMap { model.ownedItem($0.id) }
            let placements = roomItems(care: care, catalog: catalog, letters: state.letters)
            let petBounds = RoomLayout.petBounds(form: model.petForm)
            let floorDisplay = HomeFloorDisplay(journey: state, care: care, now: model.now, catalog: catalog, l10n: l10n)
            GeometryReader { proxy in
                let rows = Int(ceil(proxy.size.height / factor))
                ZStack(alignment: .topLeading) {
                    PixelArtView(image: RoomArt.image(pet: state.pet, shelf: shelf, theme: theme, catalog: catalog.pets, form: model.petForm, placements: placements, nightcap: model.nightcapNote != nil, petIsHome: state.petIsHome), scale: scale)
                        .frame(width: width, height: height).accessibilityHidden(true)
                    PixelArtView(image: RoomArt.floor(display: floorDisplay, rows: rows, theme: theme, catalog: catalog.pets), scale: scale)
                        .frame(width: width, height: CGFloat(rows) * factor).accessibilityHidden(true)
                    Color.clear.contentShape(Rectangle()).onTapGesture { selectedSouvenir = nil }
                    ForEach(Array(shelf.enumerated()), id: \.element.id) { index, item in
                        Button { selectedSouvenir = item.id } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16 * factor, height: 18 * factor)
                        .position(x: CGFloat(86 + index * 19) * factor, y: 46 * factor)
                        .accessibilityLabel(l10n.itemName(item))
                    }
                    ForEach(RoomSlot.allCases, id: \.rawValue) { slot in
                        if let item = placements[slot] {
                            let bounds = RoomLayout.slotBounds(slot)
                            Button { selectedSouvenir = item.id } label: { Color.clear.contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                                .frame(width: 14 * factor, height: 14 * factor)
                                .position(x: bounds.midX * factor, y: bounds.midY * factor)
                                .accessibilityLabel(l10n("room.placedItem", l10n.roomSlot(slot), l10n.itemName(item)))
                        }
                    }
                    if state.petIsHome {
                    Button { selectedSouvenir = nil; model.showProfile() } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).frame(width: (petBounds.width + 4) * factor, height: (petBounds.height + 4) * factor)
                    .position(x: petBounds.midX * factor, y: petBounds.midY * factor)
                    .accessibilityLabel(l10n("home.profile"))
                    }
                    Button { selectedSouvenir = nil; model.openCollection(.souvenirs) } label: {
                        Text(l10n("home.allSouvenirs")).padding(4)
                            .background(theme.background).pixelBorder(theme.border)
                    }
                    .buttonStyle(.plain).fixedSize()
                    .position(x: 181 * factor, y: 32 * factor)
                    if let id = selectedSouvenir, let item = model.ownedItem(id) {
                        roomBubble(l10n.itemDescription(item), sponsorTag: l10n.sponsorTag(item.sponsor), region: RoomLayout.bubbleRegion(scale: scale, souvenir: true, form: model.petForm)) {
                            selectedSouvenir = nil
                        }
                    } else if state.phase == .pending {
                        roomBubble(l10n("home.status.pendingBubble", l10n.cityName(catalog.city(state.targetCityId))), region: RoomLayout.bubbleRegion(scale: scale, souvenir: false, form: model.petForm)) {}
                    } else if state.phase == .home, let returned = state.homecoming?.returnedAt,
                              model.now.timeIntervalSince(returned) < 3600 {
                        roomBubble(l10n("home.bubble.returned"), region: RoomLayout.bubbleRegion(scale: scale, souvenir: false, form: model.petForm)) {}
                    } else if state.petIsHome, let text = model.nightcapText {
                        roomBubble(text, region: RoomLayout.bubbleRegion(scale: scale, souvenir: false, form: model.petForm)) {}
                    } else if state.petIsHome, let bubble = model.petBubble {
                        roomBubble(l10n(bubble.titleKey), region: RoomLayout.bubbleRegion(scale: scale, souvenir: false, form: model.petForm)) {
                            model.activateBubble(bubble)
                        }
                    }
                    ForEach(Array(floorDisplay.parcels.enumerated()), id: \.element.id) { index, parcel in
                        floorButton(bounds: RoomLayout.parcel(index), factor: factor,
                                    label: l10n("floor.parcel.open", model.ownedItem(parcel.itemID).map(l10n.itemName) ?? parcel.itemID)) {
                            if model.openFloorParcel(parcel.id), let item = model.ownedItem(parcel.itemID) {
                                floorNote = FloorNote(id: parcel.id, title: l10n("floor.parcel.collected", l10n.itemName(item)), text: l10n.itemDescription(item), sponsorTags: [l10n.sponsorTag(item.sponsor)].compactMap { $0 })
                            }
                        }
                    }
                    ForEach(Array(floorDisplay.patches.enumerated()), id: \.element.id) { index, patch in
                        let title = l10n("floor.rug.patch", l10n.cityName(catalog.city(patch.id)), l10n.day(patch.firstStay, full: true))
                        floorButton(bounds: RoomLayout.rugPatch(index), factor: factor, label: title) {
                            floorNote = FloorNote(id: patch.id, title: l10n.cityName(catalog.city(patch.id)), text: l10n("floor.rug.firstStay", l10n.day(patch.firstStay, full: true)))
                        }
                    }
                    if let line = floorDisplay.looseBoard {
                        floorButton(bounds: RoomLayout.looseBoard, factor: factor, label: l10n("floor.board.open")) {
                            floorNote = FloorNote(id: "board", title: l10n.day(line.date, full: true), text: line.text, sponsorTags: line.sponsorTags)
                        }
                    }
                    floorButton(bounds: RoomLayout.crate, factor: factor, label: l10n("floor.crate.label", floorDisplay.crateLabel(l10n: l10n))) {
                        if floorDisplay.crate == .ready { model.showBoxes() }
                        else { floorNote = FloorNote(id: "crate", title: l10n("floor.crate.title"), text: floorDisplay.crateLabel(l10n: l10n)) }
                    }
                    Text(floorDisplay.crateLabel(l10n: l10n)).font(.system(size: 12))
                        .foregroundStyle(theme.paperText).padding(4).background(theme.paper).pixelBorder(theme.paperBorder)
                        .frame(width: 66 * factor)
                        .position(x: 34 * factor, y: 158 * factor)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
                .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            }
            .frame(width: width)
            .frame(minHeight: CGFloat(RoomLayout.height + RoomLayout.floorMinRows) * factor, maxHeight: .infinity)
            .clipped()
            .popover(item: $floorNote) { note in
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.title).font(Theme.pixel()).foregroundStyle(theme.text)
                    ForEach(note.sponsorTags, id: \.self) { SponsorTag(text: $0).foregroundStyle(theme.textMuted) }
                    Text(note.text).font(.system(size: 14)).foregroundStyle(theme.textMuted)
                }.padding(16).frame(width: 280).fixedSize(horizontal: false, vertical: true)
                    .background(theme.background)
            }
            .pixelBorder(theme.border)
            .padding(.leading, floor((availableWidth - width) / 2))
            .frame(width: availableWidth, alignment: .leading)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selectedSouvenir = nil })
            .task(id: selectedSouvenir) {
                guard selectedSouvenir != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                selectedSouvenir = nil
            }
        }
    }

    private func floorButton(bounds: CGRect, factor: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button { selectedSouvenir = nil; action() } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .frame(width: bounds.width * factor, height: bounds.height * factor)
            .position(x: bounds.midX * factor, y: bounds.midY * factor)
            .accessibilityLabel(label)
    }

    private func roomBubble(_ text: String, sponsorTag: String? = nil, region: CGRect, action: @escaping () -> Void) -> some View {
        ScrollView {
            Button(action: action) {
                // Short text hugs its width; a nil-width measure would size wrapped text as one line and clip it.
                VStack(alignment: .leading, spacing: 4) {
                    if let sponsorTag { SponsorTag(text: sponsorTag) }
                    ViewThatFits(in: .horizontal) {
                        Text(text).font(.system(size: 12)).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(text).font(.system(size: 12)).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: region.width - 16, alignment: .leading)
                    }
                }
                .foregroundStyle(theme.paperText).padding(8).background(theme.paper).pixelBorder(theme.paperBorder)
            }
            .buttonStyle(.plain)
        }
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .offset(x: region.minX, y: region.minY)
    }
}
