import AppKit
import ServiceManagement

// ---------------------------------------------------------------------------
// LoginItem — "Start at Login" via SMAppService (macOS 13+). Registers the app
// itself; no helper bundle or LaunchAgent plumbing.
// ---------------------------------------------------------------------------

public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("CoughButton: Start at Login toggle failed: \(error.localizedDescription)")
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
