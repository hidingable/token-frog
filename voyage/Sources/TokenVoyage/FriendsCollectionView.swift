import SwiftUI
import VoyageCore

struct FriendDisplay {
    let name: String
    let intro: String
    let meeting: String
    let note: String
    let letterID: Int?

    init(friend: FriendContent.Entry, met: CareState.MetFriend, journey: JourneyState, catalog: CityCatalog, now: Date, l10n: L10n) {
        name = LetterComposer.localized(friend.name, l10n: l10n)!
        intro = LetterComposer.localized(friend.intro, l10n: l10n)!
        let place = met.cityId.map { l10n.cityName(catalog.city($0)) } ?? l10n("friends.onTheRoad")
        meeting = l10n("friends.metAt", l10n.day(met.date, full: true), place)
        let index = FriendRules.noteIndex(seed: journey.seed, friendId: friend.id, date: DayKey.string(from: now), count: friend.notes.count)
        note = LetterComposer.localized(friend.notes[index], l10n: l10n)!
        letterID = journey.letters.first { $0.id == met.letterId && $0.kind == .adventure && $0.deliverAt <= now }?.id
    }
}

struct FriendsCollectionView: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let model: AppModel

    var body: some View {
        if let catalog = model.catalog, let care = model.care, let journey = model.state {
            VStack(alignment: .leading, spacing: 24) {
                Text(l10n("friends.intro")).font(Theme.pixel()).foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(catalog.friends.friends.sorted { $0.id < $1.id }) { friend in
                        if let met = care.metFriends?.first(where: { $0.id == friend.id }) {
                            let display = FriendDisplay(friend: friend, met: met, journey: journey, catalog: catalog, now: model.now, l10n: l10n)
                            ItemPaper {
                                CollectionHeading {
                                    PixelArtView(image: Sprites.friend(friend, catalog: catalog.pets), scale: 3)
                                        .fixedSize().accessibilityHidden(true)
                                } content: {
                                    Text(display.name).font(Theme.pixel(24)).fixedSize(horizontal: false, vertical: true)
                                }
                                Text(display.intro).font(.system(size: 14)).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(display.meeting).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(l10n("friends.todayNote")).font(Theme.pixel()).foregroundStyle(theme.paperMuted)
                                Text(display.note).font(.system(size: 14)).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let id = display.letterID {
                                    Button { model.openCollectionLetter(id) } label: {
                                        Text(l10n("friends.openLetter")).font(Theme.pixel()).underline()
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(l10n("friends.openNamedLetter", display.name))
                                }
                            }
                        } else {
                            VStack(spacing: 10) {
                                Text("?").font(Theme.pixel(36)).frame(height: 36)
                                Text(l10n("friends.unknown")).font(Theme.pixel())
                            }
                            .modifier(CollectionTileStyle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(l10n("friends.unknown"))
                        }
                    }
                }
            }
        }
    }
}
