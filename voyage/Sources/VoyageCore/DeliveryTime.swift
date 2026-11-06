import Foundation

/// A local delivery time, persisted in preferences as an unambiguous HH:mm value.
public struct DeliveryTime: RawRepresentable, Hashable, CaseIterable, Sendable {
    public let hour: Int
    public let minute: Int

    public var rawValue: String { String(format: "%02d:%02d", hour, minute) }
    public static let standard = DeliveryTime(hour: 9, minute: 0)!
    public static let allCases = (0..<24).flatMap { hour in
        [0, 30].map { DeliveryTime(hour: hour, minute: $0)! }
    }

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), minute == 0 || minute == 30 else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              let time = DeliveryTime(hour: hour, minute: minute), time.rawValue == rawValue else { return nil }
        self = time
    }
}
