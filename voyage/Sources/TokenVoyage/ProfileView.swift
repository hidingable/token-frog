import SwiftUI
import VoyageCore

struct ProfileView: View {
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let journey = model.state, let care = model.care, let catalog = model.catalog {
            let profile = ProfileDisplay(journey: journey, care: care, l10n: l10n)
            VStack(alignment: .leading, spacing: 16) {
                Button(l10n("profile.back")) { model.openPostOffice() }.buttonStyle(.plain)
                HStack(alignment: .top, spacing: 16) {
                    HomeCard {
                        HStack(alignment: .top, spacing: 12) {
                            SpriteView(pet: journey.pet, scale: 4)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.petName).font(Theme.pixel(24))
                                Text(l10n("profile.summary", l10n.stage(profile.stage), l10n.days(profile.days),
                                          l10n.cityName(catalog.city(journey.route[0]))))
                                    .foregroundStyle(Theme.dusk)
                                Text(l10n("profile.travel", profile.cityCount, profile.kilometers))
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        Rectangle().fill(Theme.blockOff).frame(height: 2).padding(.vertical, 4)
                        Text(l10n("profile.habits"))
                        ForEach(Habit.allCases, id: \.rawValue) { habit in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.habit(habit))
                                Text(l10n.habitDescription(habit, habits: care.habits))
                                    .foregroundStyle(Theme.dusk)
                                let value = habit == .talkative ? care.habits.talkative : care.habits.observant
                                GeometryReader { proxy in
                                    Rectangle().fill(Theme.blockOff)
                                    Rectangle().fill(Theme.rose)
                                        .frame(width: floor(proxy.size.width * Double(value) / 100))
                                }
                                .frame(height: 8)
                                .accessibilityLabel(l10n.habitDescription(habit, habits: care.habits))
                            }
                        }
                    }
                    HomeCard {
                        Text(l10n("profile.learned"))
                        if profile.learned.isEmpty {
                            Text(l10n("profile.stillLearning")).foregroundStyle(Theme.dusk)
                        }
                        ForEach(profile.learned) { learned in
                            Button { model.openCollectionLetter(learned.id) } label: {
                                Text("· " + learned.text).font(.system(size: 14)).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.letters.contains { $0.id == learned.id })
                        }
                        Text(l10n("profile.next")).padding(.top, 12)
                        Text(profile.next).foregroundStyle(Theme.dusk)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    ForEach(CareRules.stageThresholds, id: \.stage) { entry in
                        VStack(spacing: 8) {
                            Text(l10n.stage(entry.stage))
                            Text(l10n.days(entry.days))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 2)
                        .foregroundStyle(entry.stage == profile.stage ? Theme.ink : Theme.dusk)
                        .background(entry.stage == profile.stage ? Theme.rose : Theme.inkRaised)
                        .pixelBorder(entry.stage == profile.stage ? Theme.rose : Theme.blockOff)
                    }
                }
                HomeCard {
                    Text(l10n("profile.identity"))
                    Text(l10n("profile.identityHint")).foregroundStyle(Theme.dusk)
                }
            }
            .font(Theme.pixel()).foregroundStyle(Theme.paper)
        }
    }
}
