import AppKit
import SwiftUI

struct MenuBarView: View {
    let environment: AppEnvironment
    private var state: AppState { environment.state }

    var body: some View {
        Button((state.isMonitoring ? "Pause Monitoring" : "Start Monitoring") + "  (\(environment.settings.monitorShortcut.label))") {
            environment.orchestrator.setMonitoring(!state.isMonitoring)
        }

        Button((state.isOverlayVisible ? "Hide Overlay" : "Show Overlay") + "  (\(environment.settings.overlayShortcut.label))") {
            environment.overlay.toggle()
        }

        Button("Solve Screen Now  (\(environment.settings.solveShortcut.label))") {
            environment.orchestrator.solveNow()
        }

        Button("Reset Answer  (\(environment.settings.resetShortcut.label))") {
            environment.orchestrator.resetConversation()
        }

        Divider()

        Text(state.isMonitoring ? "● \(state.captureStatus)" : "○ Monitoring off")
        Text("AI: \(environment.settings.aiProvider.label)")
        Text(state.ollamaStatus.label)
        if !state.screenPermissionGranted {
            Button("Grant Screen Recording Permission…") { PermissionsManager.openScreenRecordingSettings() }
        }

        Divider()

        Button("Settings…") { environment.openSettings() }
            .keyboardShortcut(",")

        Button("Quit Seer") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        // Matches the app icon: solid while watching the screen, hollow while paused.
        Image(nsImage: state.isMonitoring ? Self.filled : Self.hollow)
            .accessibilityLabel(state.isMonitoring ? "Seer monitoring" : "Seer paused")
    }

    private static let filled = crystalBall(filled: true)
    private static let hollow = crystalBall(filled: false)

    /// An 18-pt template crystal ball on a cradle and base, drawn in code since SF Symbols has none.
    static func crystalBall(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            // Base and cradle.
            ctx.addPath(CGPath(roundedRect: CGRect(x: 2.5, y: 1, width: 13, height: 2.4), cornerWidth: 0.9, cornerHeight: 0.9, transform: nil))
            ctx.fillPath()
            let cradle = CGMutablePath()
            cradle.move(to: CGPoint(x: 4.2, y: 3.4))
            cradle.addLine(to: CGPoint(x: 5.4, y: 6.4))
            cradle.addLine(to: CGPoint(x: 12.6, y: 6.4))
            cradle.addLine(to: CGPoint(x: 13.8, y: 3.4))
            cradle.closeSubpath()
            ctx.addPath(cradle)
            ctx.fillPath()
            // A thin gap around the ball keeps it distinct from the cradle.
            let center = CGPoint(x: 9, y: 11)
            let radius: CGFloat = 5.9
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: center.x - radius - 1, y: center.y - radius - 1, width: (radius + 1) * 2, height: (radius + 1) * 2))
            ctx.setBlendMode(.normal)
            if filled {
                ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ctx.setBlendMode(.clear)   // the shine is cut out of the solid ball
            } else {
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(x: center.x - radius + 0.75, y: center.y - radius + 0.75,
                                             width: (radius - 0.75) * 2, height: (radius - 0.75) * 2))
            }
            // Shine: a short arc in the upper left.
            ctx.setLineWidth(1.3)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: radius - 2.6, startAngle: .pi * 0.58, endAngle: .pi * 0.92, clockwise: false)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }
}
