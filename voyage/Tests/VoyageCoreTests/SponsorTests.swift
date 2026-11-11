import Foundation
import Testing
@testable import VoyageCore

let testSponsor = Sponsor(id: "local-partner", label: ["zh-Hans": "路边小店", "en": "Corner Shop"])

private func partnerFixture(seed: UInt32 = 7) -> (JourneyState, CareState, CityCatalog, StoryLibrary) {
    var story = engineStory("partner.story", kind: "transit", city: "shanghai")
    story.sponsor = testSponsor
    var item = engineItem("partner.item", city: "shanghai")
    item.sponsor = testSponsor
    var arrival = engineStory("ordinary.arrival", city: "shanghai")
    arrival.rewards.itemIds = [item.id]
    let library = engineStories([arrival]).addingRemote([story])
    let catalog = testCatalog.addingRemoteContent(stories: [story], items: [item])
    var (journey, care) = engineState(seed: seed)
    journey.letters = []
    journey.remoteContentByTrip = [1: .init(cityID: "shanghai", entryIDs: [story.id, item.id])]
    care.memories = []
    return (journey, care, catalog, library)
}

private func partnerLetter(_ id: Int, date: String, transit: Bool) -> Letter {
    var letter = engineLetter(id, arrivals: transit ? [] : ["shanghai"], date: date)
    letter.tripNumber = 1
    return letter
}

private let commonSeed = (UInt32(0)..<1000).first { seed in
    (1...4).allSatisfy { ItemDropRules.rarity(seed: seed, letterId: $0, pity: $0 - 1) == "common" }
}!

@Suite struct SponsorTests {
    @Test(arguments: [false, true])
    func weeklyCapIsSharedByStoriesAndItemsAndResetsMonday(storyFirst: Bool) throws {
        var (journey, care, catalog, stories) = partnerFixture(seed: commonSeed)
        let initialCare = care
        let dates = ["2026-11-02", "2026-11-08", "2026-11-09", "2026-11-10"]
        for (index, date) in dates.enumerated() {
            let first = index.isMultiple(of: 2)
            journey.letters.append(partnerLetter(index + 1, date: date, transit: first == storyFirst))
        }
        let pending = journey
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                           sponsorContentEnabled: true, calendar: careCalendar)
        #expect(journey.letters.map(\.hasSponsoredContent) == [true, false, true, false])
        #expect(care.sponsoredDeliveryWeeks == ["2026-11-02": 1, "2026-11-09": 3])
        #expect((journey.letters[0].sponsor != nil) == storyFirst)
        #expect(journey.letters[0].rewardItems.contains { $0.sponsor != nil } == !storyFirst)
        if storyFirst { #expect(journey.letters[0].facts.isEmpty) }
        let delivered = journey, completed = care
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                           sponsorContentEnabled: false, calendar: careCalendar)
        #expect(journey == delivered && care == completed)

        // Repair the care half after the authoritative journey write, even with the gate now off.
        var replay = delivered, replayCare = initialCare
        CareEngine.process(journey: &replay, care: &replayCare, stories: stories, catalog: catalog,
                           sponsorContentEnabled: false, calendar: careCalendar)
        #expect(replay == delivered && replayCare == completed)

        // Incremental arrival and catch-up use the same chronological draws and weekly ledger.
        var incremental = pending, incrementalCare = initialCare
        incremental.letters = []
        for letter in pending.letters {
            incremental.letters.append(letter)
            CareEngine.process(journey: &incremental, care: &incrementalCare, stories: stories, catalog: catalog,
                               sponsorContentEnabled: true, calendar: careCalendar)
        }
        #expect(incremental == delivered && incrementalCare == completed)
        let savedCare = try JSONDecoder().decode(CareState.self, from: JSONEncoder().encode(completed))
        #expect(savedCare == completed)
    }

    @Test func multipleArrivalSegmentsAndDropShareOneSlot() {
        var (journey, care, catalog, _) = partnerFixture(seed: commonSeed)
        var story = engineStory("partner.arrival", city: "shanghai")
        story.sponsor = testSponsor
        let stories = engineStories().addingRemote([story])
        journey.remoteContentByTrip?[1]?.entryIDs?.append(story.id)
        var letter = partnerLetter(1, date: "2026-11-02", transit: false)
        letter.arrivals = ["shanghai", "shanghai", "shanghai"]
        journey.letters = [letter]
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                           sponsorContentEnabled: true, calendar: careCalendar)
        #expect(journey.letters[0].arrivalStories.filter { $0.sponsor != nil }.count == 1)
        #expect(journey.letters[0].rewardItems.allSatisfy { $0.sponsor == nil })
        #expect(care.sponsoredDeliveryWeeks == ["2026-11-02": 1])
    }

    @Test func rarityPityAndDoubledUsageRemainIndependentOfPartnerCandidates() {
        for seed in UInt32(0)..<12 {
            var (with, care, catalog, stories) = partnerFixture(seed: seed)
            var (without, ordinaryCare, _, _) = partnerFixture(seed: seed)
            var doubled = with, doubledCare = care
            var count = 0
            for id in 1...24 {
                let date = String(format: "2026-11-%02d", id)
                let letter = partnerLetter(id, date: date, transit: id.isMultiple(of: 2))
                with.letters.append(letter); without.letters.append(letter)
                var doubleLetter = letter
                doubleLetter.fuel *= 2; doubleLetter.tokens = (letter.tokens ?? letter.fuel) * 2
                doubled.letters.append(doubleLetter)
                CareEngine.process(journey: &with, care: &care, stories: stories, catalog: catalog,
                                   sponsorContentEnabled: true, calendar: careCalendar)
                CareEngine.process(journey: &without, care: &ordinaryCare, stories: stories, catalog: testCatalog,
                                   sponsorContentEnabled: false, calendar: careCalendar)
                CareEngine.process(journey: &doubled, care: &doubledCare, stories: stories, catalog: catalog,
                                   sponsorContentEnabled: true, calendar: careCalendar)
                #expect(with.letters.last?.rewards.dropRarity == without.letters.last?.rewards.dropRarity)
                #expect(care.pity == ordinaryCare.pity)
                #expect(with.letters.last?.storyId == doubled.letters.last?.storyId)
                #expect(with.letters.last?.rewards == doubled.letters.last?.rewards)
                #expect(with.letters.last?.arrivalStories == doubled.letters.last?.arrivalStories)
                #expect(care == doubledCare)
                #expect(with.letters.last!.rewardItems.allSatisfy { $0.sponsor != nil })
                count += with.letters.last!.hasSponsoredContent ? 1 : 0
            }
            #expect(count > 0)
        }
    }

    @Test func absentFrozenCandidateAndClosedGateRemovePartnerBeforeChoice() {
        for gate in [false, true] {
            var (journey, care, catalog, stories) = partnerFixture(seed: commonSeed)
            journey.letters = [partnerLetter(1, date: "2026-11-02", transit: true)]
            if gate { journey.remoteContentByTrip?[1]?.entryIDs = [] }
            CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                               sponsorContentEnabled: gate, calendar: careCalendar)
            #expect(!journey.letters[0].hasSponsoredContent)
            #expect(care.sponsoredDeliveryWeeks.isEmpty)
        }
    }

    @Test func archiveRoundTripsDeliveredSponsorSnapshotsAndFrozenEntries() throws {
        var (journey, care, catalog, stories) = partnerFixture(seed: commonSeed)
        journey.letters = [partnerLetter(1, date: "2026-11-02", transit: false),
                           partnerLetter(2, date: "2026-11-09", transit: true)]
        CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                           sponsorContentEnabled: true, calendar: careCalendar)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let store = SaveStore(directory: source, pets: catalog.pets, items: catalog.items,
                              journeyMigrations: .journey(catalog: catalog))
        store.load(); try store.save(journey); try store.save(care)
        let remote = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [
            "partner.item": JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog.items.find("partner.item")!)),
        ]])
        let archiveData = try store.exportArchive(appVersion: "1", remoteContent: remote)
        let receiver = SaveStore(directory: target, pets: catalog.pets, items: catalog.items,
                                 journeyMigrations: .journey(catalog: catalog))
        receiver.load()
        let archive = try receiver.validateArchive(archiveData)
        #expect(archive.journey == journey && archive.care == care)
        #expect(try JSONSerialization.jsonObject(with: #require(archive.remoteContent)) as? NSDictionary
                == JSONSerialization.jsonObject(with: remote) as? NSDictionary)
        try receiver.importArchive(archive)
        guard case .loaded(let restored) = receiver.journey, case .loaded(let restoredCare) = receiver.care else {
            Issue.record("Imported partner snapshots must load"); return
        }
        #expect(restored == journey && restoredCare == care)
        #expect(restored.letters[0].rewardItems.first?.sponsor == testSponsor)
        #expect(restored.letters[1].sponsor == testSponsor)
        #expect(restoredCare.souvenirs.first { $0.id == "partner.item" }?.sponsor == testSponsor)
    }

    @Test(arguments: ["top", "nested"])
    func bundledPackRejectsSponsorKeysAtEveryDepth(position: String) throws {
        let box = try ContentSandbox()
        defer { box.cleanUp() }
        let file = try #require(ContentValidator.itemFiles(directory: box.directory).first)
        var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let sponsor = try JSONSerialization.jsonObject(with: JSONEncoder().encode(testSponsor))
        if position == "top" { entries[0]["sponsor"] = sponsor }
        else { entries[0]["metadata"] = ["nested": [["sponsor": sponsor]]] }
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        #expect(ContentValidator.validate(directory: box.directory).contains { $0.rule == "sponsor" })
    }
}

@Test(arguments: ["Asia/Tokyo", "America/Los_Angeles"])
func sponsorWeekStartsOnMondayInTheUsersLocalCalendar(zone: String) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    let first = ISO8601DateFormatter().date(from: "2026-11-09T03:00:00Z")!
    let next = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
    var (journey, care, catalog, stories) = partnerFixture(seed: commonSeed)
    journey.letters = [partnerLetter(1, date: DayKey.string(from: first, calendar: calendar), transit: true),
                       partnerLetter(2, date: DayKey.string(from: next, calendar: calendar), transit: true)]
    CareEngine.process(journey: &journey, care: &care, stories: stories, catalog: catalog,
                       sponsorContentEnabled: true, calendar: calendar)
    #expect(journey.letters.map(\.hasSponsoredContent) == (zone == "Asia/Tokyo" ? [true, false] : [true, true]))
}

@Test(arguments: [Letter.Kind.postcard, .reunion])
func companionMailNeverQuotesSponsoredMemories(kind: Letter.Kind) {
    var (journey, care) = engineState()
    var source = engineLetter(1, date: "2026-11-02")
    source.storyId = "partner.story"
    source.sponsor = testSponsor
    source.replyOptions = [.init(id: "partner.reply", habit: "observant", text: testSponsor.label)]
    source.learnedTexts = testSponsor.label
    journey.letters = [source]
    care.memories = [.init(kind: "reply", date: source.date, letterId: 1, replyId: "partner.reply"),
                     .init(kind: "fulfilled", date: source.date, letterId: 1)]
    var companion = engineLetter(2, date: "2026-11-03")
    companion.kind = kind
    CareEngine.snapshotCompanionMail(letter: &companion, journey: journey, care: care,
                                     stories: testCatalog.stories, catalog: testCatalog)
    #expect(!companion.hasSponsoredContent && companion.leadTexts.isEmpty && companion.memoryReference == nil)
    for label in testSponsor.label.values { #expect(!(companion.texts ?? [:]).values.contains { $0.contains(label) }) }
}

@Test func weeklyMailNeverQuotesSponsoredStoryHighlights() throws {
    var (journey, _) = engineState()
    journey.openDate = "2026-11-08"
    journey.weeklyMailEligibleFrom = "2026-11-08"
    journey.days["2026-11-02"] = DayRecord()
    journey.days["2026-11-02"]?.mainWindowOpened = true
    var source = engineLetter(1, date: "2026-11-02")
    source.sponsor = testSponsor
    source.fulfilledReplyId = "partner.reply"
    source.learnedTexts = testSponsor.label
    journey.letters = [source]
    CareEngine.writeWeeklyMail(journey: &journey, catalog: testCatalog, calendar: careCalendar)
    let weekly = try #require(journey.letters.last)
    #expect(weekly.kind == .weekly && !weekly.hasSponsoredContent)
    #expect(weekly.weeklySummary?.highlight == nil)
    for label in testSponsor.label.values { #expect(!(weekly.texts ?? [:]).values.contains { $0.contains(label) }) }
}
