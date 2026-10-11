import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What the main actor knows about the user's current context at capture time.
nonisolated struct CaptureRequest: Sendable {
    var scope: CaptureScope
    var maxDimension: Int
    var excludedBundleIDs: Set<String>
    var excludedWindowKeywords: [String]
    var ownBundleID: String
    var ownProcessID: pid_t
    var frontmostBundleID: String?
    var frontmostAppName: String?
    var frontmostProcessID: pid_t?
    var targetDisplayID: CGDirectDisplayID?
    var secureInputActive: Bool
}

nonisolated struct CapturedFrame: @unchecked Sendable {
    // CGImage is immutable and thread-safe.
    var image: CGImage
    var signature: FrameSignature?
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var capturedAt: Date
}

nonisolated enum CaptureOutcome: Sendable {
    case frame(CapturedFrame)
    case skipped(String)
}

nonisolated enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is required."
        case .noDisplay: "No display available to capture."
        case let .failed(message): "Screen capture failed: \(message)"
        }
    }
}

/// Takes single, downscaled screenshots with ScreenCaptureKit. Uses one-shot
/// `SCScreenshotManager` captures instead of a continuous stream, which is far cheaper
/// at the ~0.5 Hz rate ScreenPilot needs and leaves no stream to tear down.
actor ScreenCaptureManager {
    func capture(_ request: CaptureRequest) async throws -> CaptureOutcome {
        if request.secureInputActive {
            return .skipped("Secure input active (password field)")
        }
        if let bundle = request.frontmostBundleID {
            if bundle == request.ownBundleID { return .skipped("Seer is frontmost") }
            if request.excludedBundleIDs.contains(bundle) {
                return .skipped("Excluded app: \(request.frontmostAppName ?? bundle)")
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }

        let frontWindow = request.frontmostProcessID.flatMap { Self.frontWindow(of: $0, in: content) }
        let title = frontWindow?.title
        if let title, request.excludedWindowKeywords.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) {
            return .skipped("Excluded window")
        }

        let filter: SCContentFilter
        if request.scope == .frontmostWindow, let frontWindow {
            filter = SCContentFilter(desktopIndependentWindow: frontWindow)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == request.targetDisplayID }) ?? content.displays.first else {
                throw CaptureError.noDisplay
            }
            filter = Self.displayFilter(display: display, content: content, request: request)
        }

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        guard width >= 32, height >= 32 else { return .skipped("Window too small") }
        let longest = max(width, height)
        if longest > CGFloat(request.maxDimension) {
            let factor = CGFloat(request.maxDimension) / longest
            width *= factor
            height *= factor
        }
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }

        return .frame(CapturedFrame(
            image: image,
            signature: ScreenChangeDetector.signature(for: image),
            appName: request.frontmostAppName,
            bundleID: request.frontmostBundleID,
            windowTitle: title,
            capturedAt: Date()
        ))
    }

    /// Full-display filter that never includes ScreenPilot's own overlay or settings
    /// windows (so answers are never fed back into OCR or the vision model) and drops
    /// excluded apps. Window-mode captures need no extra handling: a
    /// desktop-independent window capture contains only that window's own pixels.
    static func displayFilter(display: SCDisplay, content: SCShareableContent, request: CaptureRequest) -> SCContentFilter {
        func isOwn(_ app: SCRunningApplication?) -> Bool {
            guard let app else { return false }
            return app.processID == request.ownProcessID || app.bundleIdentifier == request.ownBundleID
        }
        let excludedApps = content.applications.filter { isOwn($0) || request.excludedBundleIDs.contains($0.bundleIdentifier) }
        if excludedApps.contains(where: isOwn) {
            return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        }
        // Fallback: ScreenPilot wasn't listed as an application, so exclude its windows
        // (and excluded apps' windows) one by one.
        let excludedWindows = content.windows.filter { window in
            isOwn(window.owningApplication)
                || window.owningApplication.map { request.excludedBundleIDs.contains($0.bundleIdentifier) } == true
        }
        return SCContentFilter(display: display, excludingWindows: excludedWindows)
    }

    /// The frontmost normal window of a process, using the z-ordered CGWindowList.
    private static func frontWindow(of pid: pid_t, in content: SCShareableContent) -> SCWindow? {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  window.frame.width >= 120, window.frame.height >= 80
            else { continue }
            return window
        }
        return nil
    }
}
