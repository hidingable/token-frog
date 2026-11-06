import AppKit
import SwiftUI
import VoyageCore

enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case journey, mail, passport, dashboard, quota
    var id: String { rawValue }
}

struct MainView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State var tab: MainTab = .journey
    @State var dashboard = DashboardSelection()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 4) {
                            Text(l10n.tab(item))
                            if item == .mail, model.unread > 0 { Rectangle().fill(Theme.red).frame(width: 6, height: 6) }
                        }
                        .font(Theme.pixel())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(tab == item ? Theme.ink : Theme.paper)
                        .background(tab == item ? Theme.amber : Theme.inkRaised)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let error = model.lastError {
                    Text(l10n.error(error)).font(Theme.pixel()).foregroundStyle(Theme.red).lineLimit(1)
                } else if let scan = model.lastScan {
                    Text(l10n("status.updated", l10n.time(scan)))
                        .font(Theme.pixel()).foregroundStyle(Theme.dusk)
                }
                Button {
                    model.scheduleScan(immediately: true)
                    if tab == .quota { Task { await model.loadQuotas(force: true) } }
                } label: {
                    Text(l10n("action.refresh")).font(Theme.pixel()).foregroundStyle(Theme.paper)
                        .padding(.horizontal, 8).padding(.vertical, 6).background(Theme.inkRaised)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            switch tab {
            case .journey: ScrollView { JourneyTab(model: model).padding(12) }
            case .mail: MailTab(model: model)
            case .passport: ScrollView { PassportTab(model: model).padding(12) }
            case .dashboard: ScrollView { DashboardTab(model: model, selection: $dashboard).padding(12) }
            case .quota: ScrollView { QuotaTab(model: model).padding(12) }
            }
        }
        .background(Theme.ink)
        .preferredColorScheme(.dark)
    }
}

struct JourneyTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    SpriteView(pet: state.pet, scale: 4, moving: model.isMoving)
                        .padding(6)
                        .background(Theme.paper)
                        .pixelBorder(Theme.dusk)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.km(fuel: model.todayFuel)).font(Theme.pixel(24)).foregroundStyle(Theme.amber)
                        Text(l10n("journey.todayFuel", l10n.tokens(model.todayFuel))).font(Theme.pixel()).foregroundStyle(Theme.paper)
                        Text(l10n("journey.total", Format.km(fuel: state.totalFuel)))
                            .font(Theme.pixel()).foregroundStyle(Theme.dusk)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(model.todayVehicles, id: \.client) { share in
                            Text(l10n("vehicle.share", l10n.vehicle(share.client), share.percent))
                        }
                    }
                    .font(Theme.pixel())
                    .foregroundStyle(Theme.paper)
                }

                PixelMapView(state: state, catalog: catalog, scale: 6).pixelBorder(Theme.dusk).frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    Text(l10n("journey.route", l10n.cityName(catalog.city(state.currentCityId)), l10n.cityName(catalog.city(state.targetCityId)))).foregroundStyle(Theme.paper)
                    BlockProgress(progress: state.legProgress, blocks: 20, size: 8)
                    Spacer()
                    Text(l10n("journey.remaining", Format.km(fuel: state.remainingFuel))).foregroundStyle(Theme.dusk)
                }
                .font(Theme.pixel())

                if model.canChangeStart {
                    HStack(spacing: 8) {
                        Text(l10n("journey.start")).font(Theme.pixel()).foregroundStyle(Theme.dusk)
                        Picker(l10n("journey.start"), selection: Binding(get: { state.route[0] }, set: { model.setStart($0) })) {
                            ForEach(model.startCities) { Text(l10n("city.country", l10n.cityName($0), l10n.countryName(catalog.countryNames($0.countryCode)))).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text(l10n("journey.changeStart")).font(Theme.pixel()).foregroundStyle(Theme.dusk)
                    }
                }

                RecentBars(days: model.recentDays)
                DestinationCards(model: model)
            }
        }
    }
}

struct RecentBars: View {
    @Environment(\.l10n) private var l10n
    var days: [(date: String, fuel: Int)]

    var body: some View {
        let top = max(days.map(\.fuel).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.date) { day in
                VStack(spacing: 4) {
                    Text(day.fuel > 0 ? Format.km(fuel: day.fuel) : "-").foregroundStyle(Theme.dusk)
                    Rectangle()
                        .fill(day.date == days.last?.date ? Theme.amber : Theme.dusk)
                        .frame(height: max(2, (CGFloat(day.fuel) / CGFloat(top) * 48).rounded()))
                    Text(l10n.day(day.date)).foregroundStyle(Theme.dusk)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(Theme.pixel())
        .frame(height: 88, alignment: .bottom)
    }
}

struct DestinationCards: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n("destination.prompt", l10n.cityName(catalog.city(state.targetCityId)), model.petName))
                    .font(Theme.pixel())
                    .foregroundStyle(Theme.paper)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(state.destinationCards(catalog: catalog)) { card in
                        let selected = state.nextChoiceId == card.city.id
                        Button {
                            model.choose(selected ? nil : card.city.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l10n.cityName(card.city)).font(Theme.pixel(24))
                                Text(l10n.countryName(catalog.countryNames(card.city.countryCode)))
                                Text(l10n("destination.distance", Format.km(fuel: card.distanceFuel))).foregroundStyle(Theme.sea)
                                Text(l10n("destination.tokens", l10n.tokens(card.distanceFuel)))
                                Text(reasonText(card.reason)).foregroundStyle(Theme.brown)
                            }
                            .font(Theme.pixel())
                            .foregroundStyle(Theme.ink)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.paper)
                            .pixelBorder(selected ? Theme.amber : Theme.ink, width: selected ? 4 : 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func reasonText(_ reason: DestinationCard.Reason) -> String {
        switch reason {
        case .nearest: l10n("destination.nearest")
        case .reachable: l10n("destination.reachable")
        case .newCountry: l10n("destination.newCountry")
        }
    }
}

struct MailTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel
    @State private var selectedId: Int?

    var body: some View {
        if let catalog = model.catalog {
            let letters = model.letters
            let selected = letters.first { $0.id == selectedId } ?? letters.first
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(letters) { letter in
                            Button { selectedId = letter.id } label: {
                                HStack(spacing: 6) {
                                    Rectangle().fill(letter.read ? Color.clear : Theme.red).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LetterComposer.text(for: letter, l10n: l10n, petName: model.petName, catalog: catalog).title).lineLimit(1)
                                        Text(l10n.day(letter.date, full: true)).foregroundStyle(Theme.dusk)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(Theme.pixel())
                                .foregroundStyle(Theme.paper)
                                .padding(6)
                                .background(letter.id == selected?.id ? Theme.inkRaised : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 240)

                ScrollView {
                    if let selected {
                        LetterView(letter: selected, photoURL: model.photoURL(selected), petName: model.petName, catalog: catalog)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .onAppear { model.markRead(selected) }
                            .onChange(of: selected.id) { model.markRead(selected) }
                    } else {
                        Text(l10n("mail.empty")).font(Theme.pixel()).foregroundStyle(Theme.dusk).padding()
                    }
                }
            }
        }
    }
}

struct LetterView: View {
    @Environment(\.l10n) private var l10n
    var letter: Letter
    var photoURL: URL?
    var petName: String
    var catalog: CityCatalog

    var body: some View {
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: petName, catalog: catalog)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(text.title).font(Theme.pixel(24))
                Spacer()
                Text(l10n.day(letter.date, full: true)).font(Theme.pixel()).foregroundStyle(Theme.brown)
            }
            if let photoURL, let image = NSImage(contentsOf: photoURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(2, contentMode: .fit)
                    .frame(maxWidth: 480)
                    .pixelBorder()
                    .accessibilityLabel(l10n("letter.photo", letter.placeTitle ?? l10n("letter.localPlace")))
            }
            Text(text.voice).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Text(text.signature).font(Theme.pixel()).frame(maxWidth: .infinity, alignment: .trailing)

            if letter.weather != nil || letter.placeSummary != nil {
                divider
                Text(l10n("letter.sights")).font(Theme.pixel()).foregroundStyle(Theme.brown)
                if let weather = letter.weather {
                    Text(l10n("letter.weatherSource", weather)).font(.system(size: 13))
                }
                if let summary = letter.placeSummary {
                    Text(summary).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    if let page = letter.placeURL, let url = URL(string: page) {
                        Link(l10n("letter.source", letter.placeTitle ?? ""), destination: url)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sea)
                    }
                }
            }

            divider
            Text(l10n("letter.itinerary")).font(Theme.pixel()).foregroundStyle(Theme.brown)
            ForEach(text.itinerary, id: \.self) { Text($0).font(Theme.pixel()) }
        }
        .foregroundStyle(Theme.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .pixelBorder(Theme.ink, width: 3)
    }

    private var divider: some View {
        Rectangle().fill(Theme.ink).frame(height: 2)
    }
}

struct PassportTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let state = model.state, let catalog = model.catalog {
            let laps = Double(state.totalFuel) / Double(fuelPerKm) / 40_075
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n("passport.counts", Format.grouped(state.stamps.count), Format.grouped(Set(state.route).count))).font(Theme.pixel(24)).foregroundStyle(Theme.amber)
                Text(l10n("passport.summary", Format.km(fuel: state.totalFuel), l10n.decimal(laps, places: 2), l10n.day(state.startDate, full: true)))
                    .font(Theme.pixel())
                    .foregroundStyle(Theme.dusk)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(state.stamps, id: \.countryCode) { stamp in
                        VStack(spacing: 4) {
                            Text(l10n.countryName(catalog.countryNames(stamp.countryCode))).font(Theme.pixel())
                            Text(l10n.cityName(catalog.city(stamp.cityId))).font(Theme.pixel()).foregroundStyle(Theme.brown)
                            Text(l10n.day(stamp.date)).font(Theme.pixel()).foregroundStyle(Theme.brown)
                        }
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.mint)
                        .pixelBorder()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QuotaTab: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    static func isLow(_ metric: ProviderQuota.Metric) -> Bool { metric.remainingPercent < 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.quotaError {
                Text(l10n("quota.failed", l10n.error(error))).foregroundStyle(Theme.coral)
            }
            if model.quotas.isEmpty, model.quotaError == nil {
                Text(model.quotasLoadedAt == nil ? l10n("quota.loading") : l10n("quota.empty"))
                    .foregroundStyle(Theme.dusk)
            }
            ForEach(model.quotas) { quota in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(quota.provider).foregroundStyle(Theme.paper)
                        if let plan = quota.plan { Text(plan).foregroundStyle(Theme.dusk) }
                        Spacer()
                        if quota.resetCredits > 0 {
                            Text(l10n("quota.resetCredits", Format.grouped(quota.resetCredits))).foregroundStyle(Theme.dusk)
                        }
                    }
                    ForEach(quota.metrics) { metric in
                        metricRow(metric)
                    }
                    if quota.metrics.isEmpty {
                        Text(l10n("quota.noWindows")).foregroundStyle(Theme.dusk)
                    }
                }
                .padding(8)
                .background(Theme.inkRaised)
            }
            if let loaded = model.quotasLoadedAt {
                Text(l10n("quota.updated", l10n.time(loaded)))
                    .foregroundStyle(Theme.dusk)
            }
        }
        .font(Theme.pixel())
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadQuotas() }
    }

    private func metricRow(_ metric: ProviderQuota.Metric) -> some View {
        let low = Self.isLow(metric)
        return HStack(spacing: 8) {
            Text(l10n.quotaMetric(metric.label)).foregroundStyle(Theme.paper).fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.blockOff)
                    Rectangle().fill(low ? Theme.coral : Theme.mint)
                        .frame(width: (proxy.size.width * max(0, min(metric.remainingPercent, 100)) / 100).rounded())
                }
            }
            .frame(height: 8)
            Text(l10n("quota.remaining", Format.grouped(Int(metric.remainingPercent.rounded()))))
                .foregroundStyle(low ? Theme.coral : Theme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Text(metric.remainingLabel ?? "").foregroundStyle(Theme.dusk).fixedSize(horizontal: false, vertical: true)
            Text(metric.resetsAt.map { l10n.reset(QuotaReport.resetDescription($0, now: model.now)) } ?? "")
                .foregroundStyle(Theme.dusk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
