import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for launch-at-login.
/// Requires the executable to run from a proper `.app` bundle (see scripts/install.sh).
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Human-readable status for diagnostics.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval (Login Items in System Settings)"
        case .notFound: return "not found (run from an installed .app bundle)"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("RazerBatteryMenuBar: login item toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}
