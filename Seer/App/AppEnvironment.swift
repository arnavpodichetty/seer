import AppKit
import OSLog
import SwiftUI

/// Owns the long-lived objects and wires them together.
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let state: AppState
    let cache: AnswerCache
    let orchestrator: AIOrchestrator
    private(set) var overlay: OverlayWindowController!
    private var settingsWindow: SettingsWindowController?
    private var hotKey: HotKeyManager!

    private init() {
        settings = AppSettings()
        state = AppState()
        cache = AnswerCache(persist: settings.historyEnabled)
        orchestrator = AIOrchestrator(state: state, settings: settings, cache: cache)

        let actions = OverlayActions(
            toggleMonitoring: { [unowned self] in orchestrator.setMonitoring(!state.isMonitoring) },
            close: { [unowned self] in
                // In auto-open mode, closing means "don't show this question again".
                // In shortcut-only mode it just hides; the answer keeps generating.
                if settings.showOverlayForNewAnswers { orchestrator.dismissCurrentQuestion() }
                overlay.hide()
            },
            setCollapsed: { [unowned self] in overlay.setCollapsed($0) },
            retry: { [unowned self] in orchestrator.retryCurrentQuestion() },
            reset: { [unowned self] in orchestrator.resetConversation() },
            solveNow: { [unowned self] in orchestrator.solveNow() },
            sendChat: { [unowned self] text, includeScreen in orchestrator.sendChat(text, includeScreen: includeScreen) },
            stopChat: { [unowned self] in orchestrator.stopChat() },
            focusForTyping: { [unowned self] in overlay.focusForTyping() },
            openSettings: { [unowned self] in openSettings() },
            openScreenRecordingSettings: { PermissionsManager.openScreenRecordingSettings() }
        )
        overlay = OverlayWindowController(state: state, settings: settings, actions: actions)
        orchestrator.showOverlay = { [unowned self] in overlay.show() }
        hotKey = HotKeyManager()
    }

    func registerHotKeys() {
        let overlayOK = hotKey.register(id: 1, settings.overlayShortcut) { [unowned self] in overlay.toggle() }
        let resetOK = hotKey.register(id: 2, settings.resetShortcut) { [unowned self] in orchestrator.resetConversation() }
        let solveOK = hotKey.register(id: 3, settings.solveShortcut) { [unowned self] in orchestrator.solveNow() }
        let monitorOK = hotKey.register(id: 4, settings.monitorShortcut) { [unowned self] in
            orchestrator.setMonitoring(!state.isMonitoring)
        }
        state.hotKeyRegistered = overlayOK && resetOK && solveOK && monitorOK
        if !state.hotKeyRegistered {
            Log.ui.error("A global shortcut is already in use by another app")
        }
    }

    /// Pauses the global shortcuts while one is being recorded in Settings, then re-registers
    /// them (picking up the new combination).
    func setRecordingShortcut(_ recording: Bool) {
        if recording {
            (1...4).forEach { hotKey.unregister(id: $0) }
        } else {
            registerHotKeys()
        }
    }

    func start() {
        applyAppearance()
        state.screenPermissionGranted = PermissionsManager.hasScreenRecordingAccess
        orchestrator.startStatusPolling()
        registerHotKeys()
        if settings.launchAtLogin != LoginItemManager.isEnabled {
            settings.launchAtLogin = LoginItemManager.isEnabled
        }
        if settings.resumeMonitoringAtLaunch && state.screenPermissionGranted {
            orchestrator.startMonitoring()
        }
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        let firstOpen = settingsWindow == nil
        if firstOpen { settingsWindow = SettingsWindowController(environment: self) }
        if let tab { settingsWindow?.select(tab) }
        if firstOpen { settingsWindow?.window?.center() }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
    }
}
