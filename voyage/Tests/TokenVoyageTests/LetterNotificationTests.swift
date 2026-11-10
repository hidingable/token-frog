import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private final class NotificationDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class NotificationProbe: LetterNotificationCenter {
    enum Failure: Error { case unavailable }
    var onResponse: (@MainActor (Int?) -> Void)?
    var status: NotificationAuthorization = .authorized
    var grantsAuthorization = true
    var failsRequest = false
    var failsSend = false
    private(set) var requests = 0
    private(set) var sent: [LetterNotification] = []

    func authorizationStatus() async -> NotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        if failsRequest { throw Failure.unavailable }
        return grantsAuthorization
    }
    func send(_ notification: LetterNotification) async throws {
        if failsSend { throw Failure.unavailable }
        sent.append(notification)
    }
}

private let notificationCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func notificationDate(_ day: Int = 2, hour: Int = 9, minute: Int = 0) -> Date {
    notificationCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func notificationJourney(ids: [Int] = [1], countries: [String] = []) -> JourneyState {
    var state = JourneyState(seed: 7, startCityId: "shanghai", date: "2026-11-01", now: .distantPast, catalog: localizationCatalog)
    var template = state.letters[0]
    template.kind = .daily
    template.read = false
    template.texts = ["zh-Hans": "我在河边停了一会儿。这里的风很轻。", "en": "I paused by the river. The breeze is gentle."]
    template.newCountries = countries
    state.letters = ids.map { id in
        var letter = template
        letter.id = id
        letter.deliverAt = id < 3 ? notificationDate(hour: id == 1 ? 9 : 10) : notificationDate(3)
        return letter
    }
    return state
}

@MainActor
private func evaluate(_ service: LetterNotificationService, _ state: JourneyState, at now: Date = notificationDate(),
                      language: Language = .en, morning: Bool = true) async {
    await service.evaluate(state: state, now: now, l10n: L10n(language: language), petName: "Ginkgo", catalog: localizationCatalog,
                           morningEnabled: morning, calendar: notificationCalendar)
}

@Test @MainActor func notificationsRequireAnUnreadDeliveredLetterAndEnabledSetting() async {
    let center = NotificationProbe()
    center.status = .notDetermined
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
    await evaluate(service, notificationJourney(ids: []))
    await evaluate(service, notificationJourney(), at: notificationDate(hour: 8, minute: 59))
    var read = notificationJourney()
    read.letters[0].read = true
    await evaluate(service, read)
    await evaluate(service, notificationJourney(), morning: false)
    #expect(center.requests == 0)
    #expect(center.sent.isEmpty)
}

@Test @MainActor func notificationsSendAtDeliveryOncePerDayAndNeverRepeatAnOldLetter() async {
    let defaults = NotificationDefaults()
    let center = NotificationProbe()
    var service = LetterNotificationService(defaults: defaults, center: center)
    let state = notificationJourney(ids: [1, 2, 3])
    await evaluate(service, state)
    #expect(center.sent.map(\.letterID) == [1])
    #expect(defaults.string(forKey: "notificationLastSentDate") == "2026-11-02")
    await evaluate(service, state, at: notificationDate(hour: 10))
    #expect(center.sent.map(\.letterID) == [1])
    // Restarting the process keeps the same daily gate.
    service = LetterNotificationService(defaults: defaults, center: center)
    await evaluate(service, state, at: notificationDate(hour: 11))
    #expect(center.sent.count == 1)
    await evaluate(service, state, at: notificationDate(3))
    #expect(center.sent.map(\.letterID) == [1, 3])
    await evaluate(service, state, at: notificationDate(4))
    #expect(center.sent.map(\.letterID) == [1, 3])
}

@Test @MainActor func notificationUsesNewestLetterAndFirstSentenceInCurrentLanguage() async throws {
    for language in Language.allCases {
        let center = NotificationProbe()
        let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
        await evaluate(service, notificationJourney(ids: [1, 2, 3]), at: notificationDate(3), language: language)
        let sent = try #require(center.sent.first)
        #expect(sent.letterID == 3)
        #expect(sent.body == (language == .zhHans ? "我在河边停了一会儿。" : "I paused by the river."))
        #expect(sent.title == (language == .zhHans ? "Ginkgo从上海来信" : "Ginkgo writes from Shanghai"))
    }
}

@Test @MainActor func notificationPreviewStartsWithDisplayedLeadAndLeavesItUnchanged() async {
    var state = notificationJourney()
    state.letters[0].leadTexts = ["en": "I brought your scarf! It kept me warm."]
    let center = NotificationProbe()
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
    await evaluate(service, state)
    #expect(center.sent.first?.body == "I brought your scarf!")
    #expect(LetterNotificationService.firstSentence("A quiet morning") == "A quiet morning")
    #expect(LetterNotificationService.firstSentence("  第一声问好？后面还有故事。") == "第一声问好？")
}

@Test @MainActor func notificationPermissionIsRequestedOnlyOnceWhenAnActualLetterNeedsDelivery() async {
    let defaults = NotificationDefaults()
    let center = NotificationProbe()
    center.status = .notDetermined
    center.grantsAuthorization = false
    let service = LetterNotificationService(defaults: defaults, center: center)
    await evaluate(service, notificationJourney())
    #expect(center.requests == 1)
    #expect(service.authorization == .denied)
    #expect(center.sent.isEmpty)
    // Even if an unsupported runtime continues reporting notDetermined, do not ask again.
    let reloaded = LetterNotificationService(defaults: defaults, center: center)
    await evaluate(reloaded, notificationJourney(), at: notificationDate(3))
    #expect(center.requests == 1)
    #expect(reloaded.authorization == .denied)
}

@Test @MainActor func notificationPermissionGrantSendsAndDeniedStatusNeverRequestsAgain() async {
    let granted = NotificationProbe()
    granted.status = .notDetermined
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: granted)
    await evaluate(service, notificationJourney())
    #expect(granted.requests == 1 && granted.sent.count == 1)
    #expect(service.authorization == .authorized)
    let denied = NotificationProbe()
    denied.status = .denied
    let deniedService = LetterNotificationService(defaults: NotificationDefaults(), center: denied)
    await evaluate(deniedService, notificationJourney())
    await evaluate(deniedService, notificationJourney(), at: notificationDate(3))
    #expect(denied.requests == 0 && denied.sent.isEmpty)
    #expect(deniedService.authorization == .denied)
}

@Test @MainActor func unavailableNotificationServicesAndAdHocFailuresAreSilent() async {
    let unavailable = NotificationProbe()
    unavailable.status = .unavailable
    let unavailableService = LetterNotificationService(defaults: NotificationDefaults(), center: unavailable)
    await evaluate(unavailableService, notificationJourney())
    #expect(unavailable.requests == 0 && unavailable.sent.isEmpty)
    let failsRequest = NotificationProbe()
    failsRequest.status = .notDetermined
    failsRequest.failsRequest = true
    let requestService = LetterNotificationService(defaults: NotificationDefaults(), center: failsRequest)
    await evaluate(requestService, notificationJourney())
    await evaluate(requestService, notificationJourney(), at: notificationDate(3))
    #expect(failsRequest.requests == 1 && failsRequest.sent.isEmpty)
    let failsSend = NotificationProbe()
    failsSend.failsSend = true
    let defaults = NotificationDefaults()
    let sendService = LetterNotificationService(defaults: defaults, center: failsSend)
    await evaluate(sendService, notificationJourney())
    #expect(sendService.authorization == .unavailable)
    #expect(defaults.string(forKey: "notificationLastSentDate") == nil)
}

@Test @MainActor func newCountriesDoNotNotifyIndependentlyOfMorningMail() async {
    let center = NotificationProbe()
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
    let state = notificationJourney(ids: [1, 2, 3], countries: ["JP"])
    await evaluate(service, state, morning: false)
    #expect(center.sent.isEmpty)
    await evaluate(service, state, at: notificationDate(3), morning: false)
    #expect(center.sent.isEmpty)
    await evaluate(service, state, at: notificationDate(3))
    #expect(center.sent.map(\.letterID) == [3])
    #expect(center.sent.first?.title == "Ginkgo writes from Shanghai")
}

@Test @MainActor func phaseChangesAndLegacyDepartureLettersDoNotNotify() async {
    let center = NotificationProbe()
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
    var state = notificationJourney(ids: [])
    for phase in [JourneyState.Phase.pending, .outbound, .staying, .returning, .home] {
        state.phase = phase
        await evaluate(service, state)
    }
    #expect(center.sent.isEmpty)
    state = notificationJourney(countries: ["JP"])
    state.letters[0].kind = .departure
    await evaluate(service, state)
    #expect(center.sent.isEmpty)
}

@Test @MainActor func notificationResponseForwardsRequestedLetterOrMissingIdentifierWithoutCrashing() {
    let center = NotificationProbe()
    let service = LetterNotificationService(defaults: NotificationDefaults(), center: center)
    var responses: [Int?] = []
    service.onOpenLetter = { responses.append($0) }
    center.onResponse?(42)
    center.onResponse?(nil)
    #expect(responses.count == 2)
    #expect(responses[0] == 42)
    #expect(responses[1] == nil)
}

@Test @MainActor func encounterPostcardsStayQuietAndCannotSuppressLaterMorningMail() async {
    let center = NotificationProbe()
    let defaults = NotificationDefaults()
    let service = LetterNotificationService(defaults: defaults, center: center)
    var state = notificationJourney(ids: [1, 3])
    var photo = state.letters[0]
    photo.id = Int.max - 1
    photo.kind = .postcard
    photo.encounter = .init(cityId: "quanzhou", partner: .init(species: "snail", stage: "teen"),
                            localDate: "2026-11-01", own: .init(species: "pigeon", stage: "hatchling"))
    state.letters.append(photo)
    var onlyPhoto = state
    onlyPhoto.letters = [photo]
    await evaluate(service, onlyPhoto)
    #expect(center.sent.isEmpty)
    await evaluate(service, state)
    await evaluate(service, state, at: notificationDate(3))
    #expect(center.sent.map(\.letterID) == [1, 3])
}
