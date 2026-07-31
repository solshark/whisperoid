import Foundation
import ServiceManagement

/// Login item registration via `SMAppService`, which needs no helper bundle and
/// no deprecated login-item APIs.
///
/// Registration records the app's current location. An app launched from a
/// build directory will register that path, so it should be moved to
/// /Applications before enabling this.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS has the login item registered but the user disabled it
    /// in System Settings; the app cannot override that.
    static var requiresUserApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
