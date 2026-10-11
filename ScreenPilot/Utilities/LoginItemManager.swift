import ServiceManagement

enum LoginItemManager {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the app as a login item. Returns an error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
