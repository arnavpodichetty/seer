import AppKit
import CoreGraphics

enum PermissionsManager {
    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS requires System Settings.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
