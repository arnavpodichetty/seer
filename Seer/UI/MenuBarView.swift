import SwiftUI

struct MenuBarView: View {
    let environment: AppEnvironment
    private var state: AppState { environment.state }

    var body: some View {
        Button(state.isMonitoring ? "Pause Monitoring" : "Start Monitoring") {
            environment.orchestrator.setMonitoring(!state.isMonitoring)
        }
        .keyboardShortcut("m")

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
            Button("Grant Screen Recording Permission…") {
                PermissionsManager.requestScreenRecordingAccess()
                PermissionsManager.openScreenRecordingSettings()
            }
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
        Image(systemName: symbol)
            .accessibilityLabel(state.isMonitoring ? "Seer monitoring" : "Seer paused")
    }

    private var symbol: String {
        if case .solving = state.phase { return "sparkle.magnifyingglass" }
        // Hint that an answer is waiting behind the shortcut.
        if case .answer = state.phase, !state.isOverlayVisible { return "text.bubble.fill" }
        return state.isMonitoring ? "eye.circle.fill" : "eye.slash.circle"  // the seer's eye: open while watching
    }
}
