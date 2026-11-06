import AppKit
import SwiftUI
import VoyageCore

enum MainTab: String, CaseIterable, Identifiable {
    case journey = "旅途", mail = "信箱", passport = "护照", dashboard = "看板", quota = "额度"
    var id: String { rawValue }
}

struct MainView: View {
    let model: AppModel
    @State var tab: MainTab = .journey
    @State var dashboard = DashboardSelection()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 4) {
                            Text(item.rawValue)
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
                    Text(error).font(Theme.pixel()).foregroundStyle(Theme.red).lineLimit(1)
                } else if let scan = model.lastScan {
                    Text("更新于 \(scan.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.pixel()).foregroundStyle(Theme.dusk)
                }
                Button {
                    model.scheduleScan(immediately: true)
                    if tab == .quota { Task { await model.loadQuotas(force: true) } }
                } label: {
                    Text("刷新").font(Theme.pixel()).foregroundStyle(Theme.paper)
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
    let model: AppModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SpriteView(pet: state.pet, scale: 4, moving: model.isMoving)
                    .padding(6)
                    .background(Theme.paper)
                    .pixelBorder(Theme.dusk)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.km(fuel: model.todayFuel)).font(Theme.pixel(24)).foregroundStyle(Theme.amber)
                    Text("今天计入里程 \(Format.tokens(model.todayFuel)) token").font(Theme.pixel()).foregroundStyle(Theme.paper)
                    Text("累计 \(Format.km(fuel: state.totalFuel)) · 1 万 token = 1 km")
                        .font(Theme.pixel()).foregroundStyle(Theme.dusk)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.todayVehicles, id: \.client) { share in
                        Text("\(Vehicle.name(share.client)) \(share.percent)%")
                    }
                }
                .font(Theme.pixel())
                .foregroundStyle(Theme.paper)
            }

            PixelMapView(state: state, scale: 6).pixelBorder(Theme.dusk).frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Text("\(state.current.name) → \(state.target.name)").foregroundStyle(Theme.paper)
                BlockProgress(progress: state.legProgress, blocks: 20, size: 8)
                Spacer()
                Text("还差 \(Format.km(fuel: state.remainingFuel))").foregroundStyle(Theme.dusk)
            }
            .font(Theme.pixel())

            if model.canChangeStart {
                HStack(spacing: 8) {
                    Text("起点").font(Theme.pixel()).foregroundStyle(Theme.dusk)
                    Picker("起点", selection: Binding(get: { state.route[0] }, set: { model.setStart($0) })) {
                        ForEach(City.all) { Text("\($0.name)（\($0.country)）").tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Text("今天内可以更改").font(Theme.pixel()).foregroundStyle(Theme.dusk)
                }
            }

            RecentBars(days: model.recentDays)
            DestinationCards(model: model)
        }
    }
}

struct RecentBars: View {
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
                    Text(String(day.date.suffix(5))).foregroundStyle(Theme.dusk)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(Theme.pixel())
        .frame(height: 88, alignment: .bottom)
    }
}

struct DestinationCards: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("到\(model.state.target.name)之后去哪？不选就交给\(model.state.pet.displayName)决定")
                .font(Theme.pixel())
                .foregroundStyle(Theme.paper)
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.state.destinationCards()) { card in
                    let selected = model.state.nextChoiceId == card.city.id
                    Button {
                        model.choose(selected ? nil : card.city.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.city.name).font(Theme.pixel(24))
                            Text(card.city.country)
                            Text("约 \(Format.km(fuel: card.distanceFuel))").foregroundStyle(Theme.sea)
                            Text("约 \(Format.tokens(card.distanceFuel)) token")
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

    private func reasonText(_ reason: DestinationCard.Reason) -> String {
        switch reason {
        case .nearest: "轻松到"
        case .reachable: "够得着"
        case .newCountry: "新地方：可盖新章"
        }
    }
}

struct MailTab: View {
    let model: AppModel
    @State private var selectedId: Int?

    var body: some View {
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
                                    Text(LetterComposer.text(for: letter).title).lineLimit(1)
                                    Text(letter.date).foregroundStyle(Theme.dusk)
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
            .frame(width: 190)

            ScrollView {
                if let selected {
                    LetterView(letter: selected, photoURL: model.photoURL(selected))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .onAppear { model.markRead(selected) }
                        .onChange(of: selected.id) { model.markRead(selected) }
                } else {
                    Text("第一封信还在路上").font(Theme.pixel()).foregroundStyle(Theme.dusk).padding()
                }
            }
        }
    }
}

struct LetterView: View {
    var letter: Letter
    var photoURL: URL?

    var body: some View {
        let text = LetterComposer.text(for: letter)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(text.title).font(Theme.pixel(24))
                Spacer()
                Text(letter.date).font(Theme.pixel()).foregroundStyle(Theme.brown)
            }
            if let photoURL, let image = NSImage(contentsOf: photoURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 480, height: 240)
                    .pixelBorder()
                    .accessibilityLabel("\(letter.placeTitle ?? "当地")的像素风照片")
            }
            Text(text.voice).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Text(text.signature).font(Theme.pixel()).frame(maxWidth: .infinity, alignment: .trailing)

            if letter.weather != nil || letter.placeSummary != nil {
                divider
                Text("今日见闻").font(Theme.pixel()).foregroundStyle(Theme.brown)
                if let weather = letter.weather {
                    Text("\(weather) · Open-Meteo").font(.system(size: 13))
                }
                if let summary = letter.placeSummary {
                    Text(summary).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    if let page = letter.placeURL, let url = URL(string: page) {
                        Link("来源：Wikipedia · \(letter.placeTitle ?? "")", destination: url)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sea)
                    }
                }
            }

            divider
            Text("行程单").font(Theme.pixel()).foregroundStyle(Theme.brown)
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
    let model: AppModel

    var body: some View {
        let state = model.state
        let laps = Double(state.totalFuel) / Double(fuelPerKm) / 40_075
        VStack(alignment: .leading, spacing: 12) {
            Text("\(state.stamps.count) 个国家和地区 · \(Set(state.route).count) 座城市").font(Theme.pixel(24)).foregroundStyle(Theme.amber)
            Text("累计 \(Format.km(fuel: state.totalFuel)) · 绕地球 \(String(format: "%.2f", laps)) 圈 · 从 \(state.startDate) 出发")
                .font(Theme.pixel())
                .foregroundStyle(Theme.dusk)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(state.stamps, id: \.country) { stamp in
                    VStack(spacing: 4) {
                        Text(stamp.country).font(Theme.pixel())
                        Text(City.find(stamp.cityId)?.name ?? "").font(Theme.pixel()).foregroundStyle(Theme.brown)
                        Text(String(stamp.date.suffix(5))).font(Theme.pixel()).foregroundStyle(Theme.brown)
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

struct QuotaTab: View {
    let model: AppModel

    static func isLow(_ metric: ProviderQuota.Metric) -> Bool { metric.remainingPercent < 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.quotaError {
                Text("额度读取失败：\(error)").foregroundStyle(Theme.coral)
            }
            if model.quotas.isEmpty, model.quotaError == nil {
                Text(model.quotasLoadedAt == nil ? "正在读取额度……" : "tokscale 没有读到任何工具的额度")
                    .foregroundStyle(Theme.dusk)
            }
            ForEach(model.quotas) { quota in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(quota.provider).foregroundStyle(Theme.paper)
                        if let plan = quota.plan { Text(plan).foregroundStyle(Theme.dusk) }
                        Spacer()
                        if quota.resetCredits > 0 {
                            Text("重置券 \(quota.resetCredits) 张").foregroundStyle(Theme.dusk)
                        }
                    }
                    ForEach(quota.metrics) { metric in
                        metricRow(metric)
                    }
                    if quota.metrics.isEmpty {
                        Text("没有额度窗口").foregroundStyle(Theme.dusk)
                    }
                }
                .padding(8)
                .background(Theme.inkRaised)
            }
            if let loaded = model.quotasLoadedAt {
                Text("读取于 \(loaded.formatted(date: .omitted, time: .shortened)) · 每 10 分钟刷新 · 只显示 tokscale 能读到的工具")
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
            Text(QuotaReport.metricName(metric.label)).foregroundStyle(Theme.paper).frame(width: 72, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.blockOff)
                    Rectangle().fill(low ? Theme.coral : Theme.mint)
                        .frame(width: (proxy.size.width * max(0, min(metric.remainingPercent, 100)) / 100).rounded())
                }
            }
            .frame(height: 8)
            Text("剩 \(Int(metric.remainingPercent.rounded()))%")
                .foregroundStyle(low ? Theme.coral : Theme.paper)
                .frame(width: 56, alignment: .trailing)
            Text(metric.remainingLabel ?? "").foregroundStyle(Theme.dusk).frame(width: 96, alignment: .trailing)
            Text(metric.resetsAt.map { QuotaReport.resetDescription($0, now: model.now) } ?? "")
                .foregroundStyle(Theme.dusk)
                .frame(width: 140, alignment: .trailing)
        }
    }
}
