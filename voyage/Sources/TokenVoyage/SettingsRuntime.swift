import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus { case disabled, enabled, requiresApproval, unavailable }

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
struct SystemLoginItem: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
@Observable
final class LoginItemSetting {
    private let manager: (any LoginItemManaging)?
    private(set) var status: LoginItemStatus
    private(set) var failed = false
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var explanationKey: String? {
        if failed { return "settings.loginFailed" }
        switch status {
        case .requiresApproval: return "settings.loginApproval"
        case .unavailable: return "settings.loginUnavailable"
        case .disabled, .enabled: return nil
        }
    }

    init(manager: (any LoginItemManaging)?) {
        self.manager = manager
        status = manager?.status ?? .unavailable
    }

    func setEnabled(_ enabled: Bool) {
        guard let manager else { failed = true; return }
        do {
            try manager.setEnabled(enabled)
            status = manager.status
            failed = false
        } catch {
            status = manager.status
            failed = true
        }
    }
}

enum UsageDisplayState: Equatable {
    case loading, ready, noUsage, failed

    var messageKey: String? {
        switch self {
        case .noUsage: "usage.noRecords"
        case .failed: "usage.recoverableFailure"
        case .loading, .ready: nil
        }
    }
}
