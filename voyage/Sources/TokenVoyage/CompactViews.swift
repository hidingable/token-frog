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
    var count: Int
    var body: some View {
        Text("信 \(count)")
            .font(Theme.pixel())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 4)
            .background(Theme.red)
    }
}

struct NotchCollapsedView: View {
    let model: AppModel
    var metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                SpriteView(pet: model.state.pet, scale: 1, moving: model.isMoving)
                    .background(Theme.paper)
                BlockProgress(progress: model.state.legProgress, blocks: 6, size: 5)
            }
            .frame(width: metrics.shoulderWidth, alignment: .center)
            Color.clear.frame(width: metrics.notchWidth)
            HStack(spacing: 6) {
                Text("→ \(model.state.target.name)")
                    .font(Theme.pixel())
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                if model.unread > 0 { MailBadge(count: model.unread) }
            }
            .frame(width: metrics.shoulderWidth, alignment: .center)
        }
        .frame(width: metrics.collapsedSize.width, height: metrics.collapsedSize.height)
        .background(Color.black, in: SteppedBottom(step: 2))
    }
}

struct NotchExpandedView: View {
    let model: AppModel
    var metrics: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(model.state.pet.displayName)
                    .frame(width: metrics.shoulderWidth + (metrics.expandedSize.width - metrics.collapsedSize.width) / 2)
                Color.clear.frame(width: metrics.notchWidth)
                Group {
                    if model.unread > 0 { MailBadge(count: model.unread) } else { Text("点击打开") }
                }
                .frame(width: metrics.shoulderWidth + (metrics.expandedSize.width - metrics.collapsedSize.width) / 2)
            }
            .font(Theme.pixel())
            .foregroundStyle(Theme.dusk)
            .frame(height: metrics.collapsedSize.height)

            HStack(alignment: .top, spacing: 12) {
                PixelMapView(state: model.state, scale: 3).pixelBorder(Theme.blockOff)
                VStack(alignment: .leading, spacing: 5) {
                    Text(Format.km(fuel: model.todayFuel))
                        .font(Theme.pixel(24))
                        .foregroundStyle(Theme.amber)
                    Text("计入里程 \(Format.tokens(model.todayFuel)) token")
                    if let totals = model.todayTotals {
                        Text("总量 \(Format.tokens(totals.total)) · \(Format.cost(totals.cost))")
                            .foregroundStyle(Theme.dusk)
                    }
                    Text("\(model.state.current.name) → \(model.state.target.name)")
                    BlockProgress(progress: model.state.legProgress, blocks: 12, size: 6)
                    Text("还差 \(Format.km(fuel: model.state.remainingFuel))")
                        .foregroundStyle(Theme.dusk)
                    if let tight = model.tightestQuota {
                        Text("\(tight.provider) \(QuotaReport.metricName(tight.metric.label))额度剩 \(Int(tight.metric.remainingPercent.rounded()))%")
                            .foregroundStyle(QuotaTab.isLow(tight.metric) ? Theme.coral : Theme.dusk)
                    } else {
                        ForEach(model.todayVehicles.prefix(1), id: \.client) { share in
                            Text("\(Vehicle.name(share.client)) \(share.percent)%")
                                .foregroundStyle(Theme.dusk)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.pixel())
                .foregroundStyle(Theme.paper)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height, alignment: .top)
        .clipped()
        .background(Color.black, in: SteppedBottom(step: 4))
    }
}

struct FloatingView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            SpriteView(pet: model.state.pet, scale: 2, moving: model.isMoving)
                .background(Theme.paper)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.km(fuel: model.todayFuel)).foregroundStyle(Theme.amber)
                HStack(spacing: 4) {
                    Text("→ \(model.state.target.name)")
                        .foregroundStyle(Theme.paper)
                        .lineLimit(1)
                    if model.unread > 0 { Rectangle().fill(Theme.red).frame(width: 6, height: 6) }
                }
            }
            .font(Theme.pixel())
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: FloatingController.size.width, height: FloatingController.size.height)
        .background(Theme.ink)
        .pixelBorder(Theme.dusk)
    }
}
