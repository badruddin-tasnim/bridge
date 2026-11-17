import Foundation
import ServiceManagement

/// Represents the current macOS Login Item registration state for Bridge.
enum LaunchAtLoginState: Equatable {
    case enabled
    case requiresApproval
    case disabled

    var isEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }
}

/// Abstraction over SMAppService.mainApp so BridgeModel can be unit-tested cleanly.
protocol LaunchAtLoginControlling {
    func currentState() -> LaunchAtLoginState
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

/// Production controller backed by macOS 13+ SMAppService.mainApp.
struct SMAppServiceLaunchAtLoginController: LaunchAtLoginControlling {
    func currentState() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
