import SwiftUI

@main
struct SeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var settings = AppEnvironment.shared.settings
        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarView(environment: AppEnvironment.shared)
        } label: {
            MenuBarLabel(state: AppEnvironment.shared.state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host inside the app; don't start monitoring UI there.
        guard NSClassFromString("XCTestCase") == nil else { return }
        AppEnvironment.shared.start()
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, so it stays reachable
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppEnvironment.shared.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.orchestrator.stopMonitoring()
    }
}
