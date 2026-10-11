import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press any key combination to set a global shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    let defaultShortcut: KeyShortcut
    /// Shortcuts used by the other actions, which this one can't reuse.
    let taken: [KeyShortcut]
    /// Called with true while recording so the app's own hot keys don't swallow the keys.
    let onRecording: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if shortcut != defaultShortcut && !recording {
                    Button {
                        shortcut = defaultShortcut
                        onRecording(false)   // re-registers with the restored combination
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultShortcut.label)")
                }
                Button(action: toggle) {
                    Text(recording ? "Type shortcut…" : shortcut.label)
                        .monospacedDigit()
                        .frame(minWidth: 96)
                        .foregroundStyle(recording ? Color.accentColor : .primary)
                }
                .buttonStyle(.bordered)
                .help(recording ? "Press a key combination, or Esc to cancel" : "Click to record a new shortcut")
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        message = nil
        recording = true
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // swallow the keystroke while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            onRecording(false)
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            stop()
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= CarbonModifier.command }
        if flags.contains(.shift) { modifiers |= CarbonModifier.shift }
        if flags.contains(.option) { modifiers |= CarbonModifier.option }
        if flags.contains(.control) { modifiers |= CarbonModifier.control }

        let name = KeyShortcut.specialKeyName(event.keyCode)
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            message = "That key can't be used."
            return
        }
        let candidate = KeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyName: name)
        let strongModifiers = CarbonModifier.command | CarbonModifier.option | CarbonModifier.control
        guard candidate.isFunctionKey || modifiers & strongModifiers != 0 else {
            message = "Include ⌘, ⌃ or ⌥ so it doesn't clash with typing."
            return
        }
        guard !taken.contains(candidate) else {
            message = "\(candidate.label) is already used by another Seer shortcut."
            return
        }
        message = nil
        shortcut = candidate
        stop()
    }
}
