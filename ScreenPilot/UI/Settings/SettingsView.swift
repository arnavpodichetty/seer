import SwiftUI

struct GeneralSettingsView: View {
    let environment: AppEnvironment
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = environment.settings
        let state = environment.state
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { state.isMonitoring },
                    set: { environment.orchestrator.setMonitoring($0) }
                )) {
                    Text("Watch screen for questions")
                    Text("Seer reads the screen only while this is on.")
                }
                Toggle("Turn on automatically at launch", isOn: $settings.resumeMonitoringAtLaunch)
                Picker("Check every", selection: $settings.captureInterval) {
                    ForEach([1.0, 1.5, 2, 3, 5, 10], id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(seconds.formatted()) seconds").tag(seconds)
                    }
                }
                Picker("Capture", selection: $settings.captureScope) {
                    ForEach(CaptureScope.allCases) { Text($0.label).tag($0) }
                }
                if settings.captureScope == .display {
                    Picker("Display", selection: $settings.displayTarget) {
                        ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text("Monitoring")
            }

            Section {
                ShortcutRow(title: "Show or hide overlay", shortcut: $settings.overlayShortcut, defaultShortcut: .defaultOverlay,
                            taken: [settings.resetShortcut, settings.solveShortcut], environment: environment)
                ShortcutRow(title: "Solve screen now", shortcut: $settings.solveShortcut, defaultShortcut: .defaultSolve,
                            taken: [settings.overlayShortcut, settings.resetShortcut], environment: environment)
                ShortcutRow(title: "Reset answer", shortcut: $settings.resetShortcut, defaultShortcut: .defaultReset,
                            taken: [settings.overlayShortcut, settings.solveShortcut], environment: environment)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                if !state.hotKeyRegistered {
                    Label("A shortcut is already used by another app or macOS. Choose a different one.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle(isOn: $settings.showOverlayForNewAnswers) {
                    Text("Open automatically for new answers")
                    Text("Otherwise the overlay only opens with the shortcut.")
                }
                LabeledContent("Background opacity") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.overlayOpacity, in: 0.1...1)
                            .frame(width: 180)
                        Text(settings.overlayOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Picker("Position", selection: $settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.overlayPosition) {
                    if settings.overlayPosition != .remembered { environment.overlay.resetPosition() }
                }
                Toggle("Expand explanations", isOn: $settings.explanationExpanded)
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.appearance) { environment.applyAppearance() }
            } header: {
                Text("Overlay")
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { enabled in
                        loginError = LoginItemManager.setEnabled(enabled)
                        settings.launchAtLogin = LoginItemManager.isEnabled
                    }
                ))
                Toggle(isOn: $settings.showInMenuBar) {
                    Text("Show in menu bar")
                    if !settings.showInMenuBar {
                        Text("To get back here, open Seer again from Finder or Spotlight.")
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Snap older free-form slider values onto the picker's choices.
            let choices = [1.0, 1.5, 2, 3, 5, 10]
            if !choices.contains(settings.captureInterval) {
                settings.captureInterval = choices.min { abs($0 - settings.captureInterval) < abs($1 - settings.captureInterval) } ?? 1.5
            }
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: KeyShortcut
    let defaultShortcut: KeyShortcut
    let taken: [KeyShortcut]
    let environment: AppEnvironment

    var body: some View {
        LabeledContent(title) {
            ShortcutRecorder(shortcut: $shortcut, defaultShortcut: defaultShortcut, taken: taken,
                             onRecording: environment.setRecordingShortcut)
                .fixedSize()
        }
    }
}
