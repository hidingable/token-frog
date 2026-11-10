import Foundation
import Observation
@preconcurrency import UserNotifications
import VoyageCore

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, unavailable
}

struct LetterNotification: Equatable, Sendable {
    let letterID: Int
    let title: String
    let body: String
}

@MainActor
protocol LetterNotificationCenter: AnyObject {
    var onResponse: (@MainActor (Int?) -> Void)? { get set }
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func send(_ notification: LetterNotification) async throws
}

/// Keeps command-line tests and unsupported bundles away from current(), which can raise
/// an Objective-C exception when UserNotifications cannot identify the application.
@MainActor
final class SystemLetterNotificationCenter: NSObject, LetterNotificationCenter, UNUserNotificationCenterDelegate {
    var onResponse: (@MainActor (Int?) -> Void)?
    private let center: UNUserNotificationCenter?

    init(enabled: Bool = true) {
        if enabled, Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    func authorizationStatus() async -> NotificationAuthorization {
        guard let center else { return .unavailable }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let value: NotificationAuthorization
                switch settings.authorizationStatus {
                case .notDetermined: value = .notDetermined
                case .denied: value = .denied
                case .authorized, .provisional: value = .authorized
                @unknown default: value = .unavailable
                }
                continuation.resume(returning: value)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard let center else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(_ notification: LetterNotification) async throws {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = ["letterID": notification.letterID]
        let request = UNNotificationRequest(identifier: "voyage-letter-\(notification.letterID)", content: content, trigger: nil)
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let letterID = response.notification.request.content.userInfo["letterID"] as? Int
        Task { @MainActor [weak self] in self?.onResponse?(letterID) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// The morning-mail delivery gate, called by the existing 30-second tick.
@MainActor
@Observable
final class LetterNotificationService {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center: any LetterNotificationCenter
    @ObservationIgnored private var isEvaluating = false
    private(set) var authorization: NotificationAuthorization = .notDetermined
    @ObservationIgnored var onOpenLetter: (@MainActor (Int?) -> Void)?

    init(defaults: UserDefaults, center: any LetterNotificationCenter) {
        self.defaults = defaults
        self.center = center
        center.onResponse = { [weak self] id in self?.onOpenLetter?(id) }
    }

    func refreshAuthorization() async {
        authorization = await center.authorizationStatus()
        if authorization == .notDetermined, defaults.object(forKey: "notificationAuthorizationRequested") as? Bool == true {
            authorization = .denied
        }
    }

    func withSnapshotAuthorization(_ status: NotificationAuthorization, render: () -> Void) {
        let previous = authorization
        authorization = status
        defer { authorization = previous }
        render()
    }

    func evaluate(state: JourneyState, now: Date, l10n: L10n, petName: String, catalog: CityCatalog,
                  morningEnabled: Bool = true, calendar: Calendar = .current) async {
        guard !isEvaluating, morningEnabled else { return }
        let today = DayKey.string(from: now, calendar: calendar)
        guard defaults.string(forKey: "notificationLastSentDate") != today else { return }
        let journeyID = "\(state.seed):\(state.startDate)"
        let lastSentID = defaults.string(forKey: "notificationLastSentJourney") == journeyID
            ? defaults.object(forKey: "notificationLastSentLetterID") as? Int : nil
        guard let letter = state.letters.filter({ letter in
            letter.deliverAt <= now && !letter.read && letter.kind != .departure && letter.encounter == nil
                && (lastSentID == nil || letter.id > lastSentID!)
        }).max(by: { $0.deliverAt == $1.deliverAt ? $0.id < $1.id : $0.deliverAt < $1.deliverAt }) else { return }
        let text = LetterComposer.text(for: letter, l10n: l10n, petName: petName, catalog: catalog, letters: state.letters)
        let body = Self.firstSentence(text.lead ?? text.voice)
        // A newly settled letter must be composed before it can supply the promised preview.
        guard !body.isEmpty else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        await refreshAuthorization()
        if authorization == .notDetermined {
            guard defaults.object(forKey: "notificationAuthorizationRequested") as? Bool != true else { return }
            defaults.set(true, forKey: "notificationAuthorizationRequested")
            do {
                authorization = try await center.requestAuthorization() ? .authorized : .denied
            } catch {
                authorization = .unavailable
                return
            }
        }
        guard authorization == .authorized else { return }
        let title = l10n("notification.letterTitle", petName, l10n.cityName(catalog.city(letter.cityId)))
        do {
            try await center.send(LetterNotification(letterID: letter.id, title: title, body: body))
            defaults.set(today, forKey: "notificationLastSentDate")
            defaults.set(journeyID, forKey: "notificationLastSentJourney")
            defaults.set(letter.id, forKey: "notificationLastSentLetterID")
        } catch {
            // Notifications are optional, including on ad-hoc signed app bundles.
            authorization = .unavailable
        }
    }

    static func firstSentence(_ text: String) -> String {
        var first = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            first = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            stop = true
        }
        return first
    }
}
