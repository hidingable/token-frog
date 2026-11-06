import AppKit
import SwiftUI
import VoyageCore

struct MainView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State var dashboard = DashboardSelection()

    var body: some View {
        VStack(spacing: 0) {
            navigation
            if let error = model.lastError {
                HStack(alignment: .top, spacing: 12) {
                    Text(l10n.error(error)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Chip(title: l10n("action.retry"), isOn: false) { model.scheduleScan(immediately: true) }
                }
                .font(Theme.pixel())
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if model.showingSettings {
                ScrollView { SettingsTab(model: model).padding(12) }
            } else if model.ritualLetter != nil {
                RitualView(model: model)
            } else {
                secondaryNavigation
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { item in
                Button { model.navigate(to: item) } label: {
                    HStack(spacing: 4) {
                        Text(l10n.tab(item))
                        if item == .mail, model.unread > 0 { Rectangle().fill(theme.newMailFill).frame(width: 6, height: 6) }
                    }
                    .font(Theme.pixel())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(!model.showingSettings && model.tab == item ? theme.selectedText : theme.text)
                    .background(!model.showingSettings && model.tab == item ? theme.selectedFill : theme.surfaceRaised)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: 8)
            if let scan = model.lastScan {
                Text(l10n("status.updated", l10n.time(scan)))
                    .font(Theme.pixel()).foregroundStyle(theme.textMuted).fixedSize()
            }
            Button { model.showingSettings = true } label: {
                Text(l10n("nav.settings"))
                    .font(Theme.pixel())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(model.showingSettings ? theme.selectedText : theme.text)
                    .background(model.showingSettings ? theme.selectedFill : theme.surfaceRaised)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(12)
    }

    @ViewBuilder private var secondaryNavigation: some View {
        if model.tab == .mail || model.tab == .collection || model.tab == .data {
            HStack(spacing: 4) {
                switch model.tab {
                case .mail:
                    ForEach(MailFilter.allCases) { item in
                        Chip(title: l10n.mailFilter(item), isOn: model.mailFilter == item) { model.mailFilter = item }
                    }
                case .collection:
                    ForEach(CollectionTab.allCases) { item in
                        Chip(title: l10n.collectionTab(item), isOn: model.collectionTab == item) { model.collectionTab = item }
                    }
                case .data:
                    ForEach(DataTab.allCases) { item in
                        Chip(title: l10n.dataTab(item), isOn: model.dataTab == item) { model.dataTab = item }
                    }
                case .home, .journey: EmptyView()
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .home:
            switch model.homePage {
            case .room: HomeTab(model: model)
            case .profile: ScrollView { ProfileView(model: model).padding(12) }
            case .box: BoxView(model: model)
            }
        case .journey:
            GeometryReader { proxy in
                ScrollView { JourneyTab(model: model, availableWidth: proxy.size.width - 24).padding(12) }
            }
        case .mail: MailTab(model: model)
        case .collection:
            ScrollView {
                Group {
                    switch model.collectionTab {
                    case .passport: PassportTab(model: model)
                    case .bag: BagCollectionView(model: model)
                    case .souvenirs: SouvenirsCollectionView(model: model)
                    case .menus: MenusCollectionView(model: model)
                    }
                }
                .padding(12)
            }
        case .data:
            ScrollView {
                switch model.dataTab {
                case .dashboard: DashboardTab(model: model, selection: $dashboard).padding(12)
                case .quota: QuotaTab(model: model).padding(12)
                }
            }
        }
    }
}

struct JourneyTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel
    let availableWidth: CGFloat

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    SpriteView(pet: state.pet, scale: 4, moving: model.isMoving)
                        .padding(6)
                        .background(theme.paper)
                        .pixelBorder(theme.border)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.km(fuel: model.todayFuel)).font(Theme.pixel(24)).foregroundStyle(theme.mileageText)
                        Text(l10n("journey.todayFuel", l10n.tokens(model.todayFuel))).font(Theme.pixel()).foregroundStyle(theme.text)
                        Text(l10n("journey.total", Format.km(fuel: state.totalFuel)))
                            .font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(model.todayVehicles, id: \.client) { share in
                            Text(l10n("vehicle.share", l10n.vehicle(share.client), share.percent))
                        }
                    }
                    .font(Theme.pixel())
                    .foregroundStyle(theme.text)
                }

                PixelMapView(image: PixelMap.image(for: state, catalog: catalog, theme: theme),
                             availableWidth: availableWidth, borderColor: theme.mapBorder)
                    .accessibilityLabel(l10n("map.description", l10n.cityName(catalog.city(state.currentCityId)), l10n.cityName(catalog.city(state.targetCityId))))

                HStack(spacing: 12) {
                    Text(l10n("journey.route", l10n.cityName(catalog.city(state.currentCityId)), l10n.cityName(catalog.city(state.targetCityId)))).foregroundStyle(theme.text)
                    BlockProgress(progress: state.legProgress, blocks: 20, size: 8)
                    Spacer()
                    Text(l10n("journey.remaining", Format.km(fuel: state.remainingFuel))).foregroundStyle(theme.textMuted)
                }
                .font(Theme.pixel())

                RecentBars(days: model.recentDays)
            }
        }
    }
}

struct RecentBars: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    var days: [(date: String, fuel: Int)]

    var body: some View {
        let top = max(days.map(\.fuel).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.date) { day in
                VStack(spacing: 4) {
                    Text(day.fuel > 0 ? Format.km(fuel: day.fuel) : "-").foregroundStyle(theme.textMuted)
                    Rectangle()
                        .fill(day.date == days.last?.date ? theme.mileageFill : theme.textMuted)
                        .frame(height: max(2, (CGFloat(day.fuel) / CGFloat(top) * 48).rounded()))
                    Text(l10n.day(day.date)).foregroundStyle(theme.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(Theme.pixel())
        .frame(height: 88, alignment: .bottom)
    }
}

struct MailTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let catalog = model.catalog {
            let letters = model.filteredLetters
            let selected = letters.first { $0.id == model.selectedLetterID } ?? letters.first
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(letters) { letter in
                            Button { model.selectedLetterID = letter.id } label: {
                                HStack(spacing: 6) {
                                    Rectangle().fill(letter.read ? Color.clear : theme.newMailFill).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LetterComposer.text(for: letter, l10n: l10n, petName: model.petName, catalog: catalog).title)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(l10n.day(letter.date, full: true)).foregroundStyle(theme.textMuted)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(Theme.pixel())
                                .foregroundStyle(theme.text)
                                .padding(6)
                                .background(letter.id == selected?.id ? theme.surfaceRaised : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 240)

                ScrollView {
                    if let selected {
                        LetterView(letter: selected, photoURL: model.photoURL(selected), petName: model.petName, catalog: catalog, model: model)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .onAppear { model.openLetter(selected) }
                            .onChange(of: selected.id) { model.openLetter(selected) }
                            .task(id: "\(selected.id)-\(l10n.language.rawValue)") {
                                await model.enrichPlace(letterId: selected.id)
                            }
                    } else {
                        Text(l10n("mail.empty")).font(Theme.pixel()).foregroundStyle(theme.textMuted).padding()
                    }
                }
            }
        }
    }
}

struct LetterView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    var letter: Letter
    var photoURL: URL?
    var petName: String
    var catalog: CityCatalog
    var model: AppModel? = nil

    var body: some View {
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: petName, catalog: catalog)
        let place = LetterComposer.place(for: letter, l10n: l10n)
        let weather = letter.weatherCode.flatMap { code in
            letter.temperatureC.map { "\($0)°C \(Enricher.weatherName(code, l10n: l10n))" }
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(text.title).font(Theme.pixel(24)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(l10n.day(letter.date, full: true)).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let photoURL, let image = NSImage(contentsOf: photoURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(2, contentMode: .fit)
                    .frame(maxWidth: 480)
                    .pixelBorder()
                    .accessibilityLabel(l10n("letter.photo", place?.title ?? l10n("letter.localPlace")))
            }
            if let lead = text.lead {
                Text(lead).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.paperCompanionText)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            Text(text.voice).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Text(text.signature).font(Theme.pixel()).frame(maxWidth: .infinity, alignment: .trailing)

            if !letter.facts.isEmpty {
                divider
                Text(l10n("letter.sights")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                ForEach(letter.facts, id: \.id) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LetterComposer.localized(fact.names, l10n: l10n) ?? "").font(Theme.pixel())
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(fact.sources, id: \.self) { source in
                            if let url = URL(string: source) {
                                Link(l10n("letter.source", url.host ?? source), destination: url)
                                    .font(.system(size: 12)).foregroundStyle(theme.paperLink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if weather != nil || place != nil {
                divider
                if let weather {
                    Text(l10n("letter.weatherSource", weather)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                if let summary = place?.summary {
                    Text(place?.title ?? "").font(Theme.pixel()).fixedSize(horizontal: false, vertical: true)
                    Text(summary).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    if let page = place?.url, let url = URL(string: page) {
                        Link(l10n("letter.source", place?.title ?? ""), destination: url)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.paperLink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let brought = LetterComposer.brought(for: letter, care: model?.care, catalog: catalog, l10n: l10n) {
                divider
                BroughtItemsView(brought: brought)
            }
            if !text.itinerary.isEmpty {
                divider
                if letter.kind != .logbook {
                    Text(l10n("letter.itinerary")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                }
                ForEach(text.itinerary, id: \.self) { Text($0).font(Theme.pixel()).fixedSize(horizontal: false, vertical: true) }
            }
            if let model { response(model: model) }
        }
        .foregroundStyle(theme.paperText)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .pixelBorder(theme.paperBorder, width: 3)
    }

    @ViewBuilder private func response(model: AppModel) -> some View {
        if let selected = letter.replyOptions.first(where: { $0.id == letter.selectedReplyId }) {
            divider
            Text(l10n("letter.yourReply", LetterComposer.localized(selected.text, l10n: l10n) ?? ""))
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Text(l10n("letter.remembered")).font(Theme.pixel()).foregroundStyle(theme.paperCompanionText)
            if let next = model.followUp(for: letter) {
                Button { model.openFollowUp(next) } label: {
                    Text(l10n("letter.followUp", next.id)).font(Theme.pixel()).foregroundStyle(theme.paperCompanionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
        } else if !letter.replyOptions.isEmpty, letter.deliverAt <= model.now,
                  model.deferredReplyLetterID != letter.id {
            divider
            Text(l10n("letter.reply")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
            ForEach(letter.replyOptions, id: \.id) { option in
                Button { model.reply(to: letter.id, option: option.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LetterComposer.localized(option.text, l10n: l10n) ?? "")
                            .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                        Text(option.habit == "talkative" ? l10n("habit.talkative") : l10n("habit.observant"))
                            .font(Theme.pixel()).foregroundStyle(theme.paperCompanionText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .pixelBorder(theme.paperCompanionText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isLocked)
            }
            Button { model.deferReply(to: letter.id) } label: {
                Text(l10n("letter.replyLater")).font(Theme.pixel()).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).pixelBorder()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.paperRule).frame(height: 2)
    }
}

struct PassportTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let laps = Double(state.totalFuel) / Double(fuelPerKm) / 40_075
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("passport.counts", Format.grouped(state.stamps.count), Format.grouped(Set(state.route).count))).font(Theme.pixel(24)).foregroundStyle(theme.text)
                Text(l10n("passport.summary", Format.km(fuel: state.totalFuel), l10n.decimal(laps, places: 2), l10n.day(state.startDate, full: true)))
                    .font(Theme.pixel())
                    .foregroundStyle(theme.textMuted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(state.stamps, id: \.countryCode) { stamp in
                        VStack(spacing: 4) {
                            Text(l10n.countryName(catalog.countryNames(stamp.countryCode))).font(Theme.pixel())
                            Text(l10n.cityName(catalog.city(stamp.cityId))).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                            Text(l10n.day(stamp.date)).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                        }
                        .foregroundStyle(theme.onNewPlace)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.newPlaceFill)
                        .pixelBorder()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QuotaTab: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    static func isLow(_ metric: ProviderQuota.Metric) -> Bool { metric.remainingPercent < 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n("nav.quota")).foregroundStyle(theme.text)
                Spacer()
                Chip(title: l10n("action.refresh"), isOn: false) { Task { await model.loadQuotas(force: true) } }
            }
            if let error = model.quotaError {
                Text(l10n("quota.failed", l10n.error(error))).foregroundStyle(theme.quotaLowText)
            }
            if model.quotas.isEmpty, model.quotaError == nil {
                Text(model.quotasLoadedAt == nil ? l10n("quota.loading") : l10n("quota.empty"))
                    .foregroundStyle(theme.textMuted)
            }
            ForEach(model.quotas) { quota in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(quota.provider).foregroundStyle(theme.text)
                        if let plan = quota.plan { Text(plan).foregroundStyle(theme.textMuted) }
                        Spacer()
                        if quota.resetCredits > 0 {
                            Text(l10n("quota.resetCredits", Format.grouped(quota.resetCredits))).foregroundStyle(theme.textMuted)
                        }
                    }
                    ForEach(quota.metrics) { metric in
                        metricRow(metric)
                    }
                    if quota.metrics.isEmpty {
                        Text(l10n("quota.noWindows")).foregroundStyle(theme.textMuted)
                    }
                }
                .padding(8)
                .background(theme.surfaceRaised)
            }
            if let loaded = model.quotasLoadedAt {
                Text(l10n("quota.updated", l10n.time(loaded)))
                    .foregroundStyle(theme.textMuted)
            }
        }
        .font(Theme.pixel())
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadQuotas() }
    }

    private func metricRow(_ metric: ProviderQuota.Metric) -> some View {
        let low = Self.isLow(metric)
        return HStack(spacing: 8) {
            Text(l10n.quotaMetric(metric.label)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(theme.controlOff)
                    Rectangle().fill(low ? theme.quotaLowFill : theme.quotaFill)
                        .frame(width: (proxy.size.width * max(0, min(metric.remainingPercent, 100)) / 100).rounded())
                }
            }
            .frame(height: 8)
            Text(l10n("quota.remaining", Format.grouped(Int(metric.remainingPercent.rounded()))))
                .foregroundStyle(low ? theme.quotaLowText : theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(metric.remainingLabel ?? "").foregroundStyle(theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Text(metric.resetsAt.map { l10n.reset(QuotaReport.resetDescription($0, now: model.now)) } ?? "")
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
