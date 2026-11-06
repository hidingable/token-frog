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
                                HomeCard {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(model.petName).font(Theme.pixel(24))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(l10n.stage(Stage.current(companionDays: care.companionDays.count)))
                                                .foregroundStyle(theme.textMuted)
                                        }
                                        Spacer(minLength: 4)
                                        Button(l10n("home.profile")) { model.showProfile() }
                                            .buttonStyle(.plain).foregroundStyle(theme.textMuted).fixedSize()
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
                                HomeCard {
                                    Text(l10n("home.now")).foregroundStyle(theme.textMuted)
                                    Text(l10n("home.onRoad", l10n.cityName(catalog.city(state.targetCityId))))
                                    BlockProgress(progress: state.legProgress, blocks: 16, size: 8)
                                    Text(l10n("home.today", Format.km(fuel: model.todayFuel))).foregroundStyle(theme.mileageText)
                                    Text(l10n("journey.remaining", Format.km(fuel: state.remainingFuel))).foregroundStyle(theme.textMuted)
                                }
                            }
                            .frame(width: layout.rightWidth)
                        }
                        WeekCard(model: model, care: care)
                    }
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        let scale = CGFloat(RoomLayout.scale(availableWidth: layout.roomWidth))
                        let shelfX = floor((proxy.size.width - 24 - layout.contentWidth) / 2) + 78 * scale
                        let shelf = CGRect(x: shelfX, y: 37 * scale, width: 76 * scale, height: 18 * scale)
                        if !shelf.contains(tap.location) { selectedSouvenir = nil }
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
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 4) {
                ForEach(week.days) { day in
                    VStack(spacing: 4) {
                        Text(day.label).font(Theme.pixel())
                        Rectangle().fill(day.today ? theme.text : .clear).frame(height: 2)
                    }
                    .foregroundStyle(day.stamped ? theme.companionOnFill : theme.textMuted)
                    .padding(.horizontal, 1).padding(.top, 6)
                    .frame(maxWidth: .infinity)
                    .background(day.stamped ? theme.companionFill : theme.background)
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

    var body: some View {
        if let state = model.state, let care = model.care, let catalog = model.catalog {
            let scale = RoomLayout.scale(availableWidth: availableWidth)
            let factor = CGFloat(scale)
            let width = CGFloat(RoomLayout.width * scale)
            let height = CGFloat(RoomLayout.height * scale)
            let shelf = RoomLayout.shelf(care).compactMap { catalog.items.find($0.id) }
            ZStack(alignment: .topLeading) {
                PixelArtView(image: RoomArt.image(pet: state.pet, shelf: shelf, theme: theme), scale: scale)
                    .frame(width: width, height: height).accessibilityHidden(true)
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
                Button { selectedSouvenir = nil; model.showProfile() } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(width: 36 * factor, height: 36 * factor)
                .position(x: 132 * factor, y: 92 * factor)
                .accessibilityLabel(l10n("home.profile"))
                Button { selectedSouvenir = nil; model.openCollection(.souvenirs) } label: {
                    Text(l10n("home.allSouvenirs")).padding(4)
                        .background(theme.background).pixelBorder(theme.border)
                }
                .buttonStyle(.plain).fixedSize()
                .position(x: 181 * factor, y: 32 * factor)
                if let id = selectedSouvenir, let item = catalog.items.find(id) {
                    roomBubble(l10n.itemDescription(item), region: RoomLayout.bubbleRegion(scale: scale, souvenir: true)) {
                        selectedSouvenir = nil
                    }
                } else if let bubble = model.petBubble {
                    roomBubble(l10n(bubble.titleKey), region: RoomLayout.bubbleRegion(scale: scale, souvenir: false)) {
                        model.activateBubble(bubble)
                    }
                }
            }
            .frame(width: width, height: height).pixelBorder(theme.border)
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

    private func roomBubble(_ text: String, region: CGRect, action: @escaping () -> Void) -> some View {
        ScrollView {
            Button(action: action) {
                Text(text).font(.system(size: 12)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: region.width - 16, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: true)
                    .foregroundStyle(theme.paperText).padding(8).background(theme.paper).pixelBorder(theme.paperBorder)
            }
            .buttonStyle(.plain)
        }
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .offset(x: region.minX, y: region.minY)
    }
}
