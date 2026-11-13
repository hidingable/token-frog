import SwiftUI
import VoyageCore

struct ProfileView: View {
    @Environment(\.theme) private var theme
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
                            SpriteView(pet: journey.pet, scale: 4, form: model.petForm, nightcap: model.nightcapNote != nil)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.petName).font(Theme.pixel(24))
                                Text(l10n("profile.summary", l10n.stage(profile.stage), l10n.days(profile.days),
                                          l10n.cityName(catalog.city(journey.homeCityId))))
                                    .foregroundStyle(theme.textMuted)
                                Text(l10n("profile.travel", profile.cityCount, profile.kilometers))
                                    .foregroundStyle(theme.mileageText)
                            }
                        }
                        Rectangle().fill(theme.controlOff).frame(height: 2).padding(.vertical, 4)
                        Text(l10n("profile.habits"))
                        ForEach(Habit.allCases, id: \.rawValue) { habit in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.habit(habit))
                                Text(l10n.habitDescription(habit, habits: care.habits))
                                    .foregroundStyle(theme.textMuted)
                                let value = habit == .talkative ? care.habits.talkative : care.habits.observant
                                GeometryReader { proxy in
                                    Rectangle().fill(theme.controlOff)
                                    Rectangle().fill(theme.companionFill)
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
                            Text(l10n("profile.stillLearning")).foregroundStyle(theme.textMuted)
                        }
                        ForEach(profile.learned) { learned in
                            Button { model.openCollectionLetter(learned.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("· " + learned.text).font(.system(size: 14)).lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(learned.sponsorTags, id: \.self) { SponsorTag(text: $0) }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.letters.contains { $0.id == learned.id })
                        }
                        Text(l10n("profile.next")).padding(.top, 12)
                        Text(profile.next).foregroundStyle(theme.textMuted)
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
                        .foregroundStyle(entry.stage == profile.stage ? theme.companionOnFill : theme.textMuted)
                        .background(entry.stage == profile.stage ? theme.companionFill : theme.surfaceRaised)
                        .pixelBorder(entry.stage == profile.stage ? theme.companionFill : theme.controlOff)
                    }
                }
                if !model.canArrangeRoom {
                    Text(l10n("profile.arrangementUnlock")).foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HomeCard {
                    Text(l10n("profile.identity"))
                    if let identity = IdentityDisplay(journey: journey, care: care, catalog: catalog, now: model.now, l10n: l10n) {
                        Text(identity.name)
                        Text(identity.basis).foregroundStyle(theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let id = identity.letterID {
                            Button(l10n("identity.openLetter")) { model.openCollectionLetter(id) }
                                .buttonStyle(.plain)
                        }
                    } else {
                        Text(l10n("profile.identityHint")).foregroundStyle(theme.textMuted)
                    }
                }
            }
            .font(Theme.pixel()).foregroundStyle(theme.text)
        }
    }
}
