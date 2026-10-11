import AppKit
import SwiftUI

/// Non-activating floating panel: it shows above other windows without taking focus
/// from the app the user is working in. It uses normal window-sharing behavior and is
/// visible to screenshots and screen recording like any other window; Seer only
/// leaves it out of *its own* captures through the ScreenCaptureKit content filter.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // only when the user clicks text, via becomesKeyOnlyIfNeeded
    override var canBecomeMain: Bool { false }

    /// AppKit re-creates the traffic-light buttons when the style mask changes or the
    /// window becomes key, so hide them (and their container) every time.
    func hideWindowButtons() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            button.isHidden = true
            button.superview?.isHidden = true
        }
    }

    override var styleMask: NSWindow.StyleMask {
        didSet { hideWindowButtons() }
    }

    override func becomeKey() {
        super.becomeKey()
        hideWindowButtons()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        hideWindowButtons()
    }

    /// Called for ⌘W and Esc, like closing a normal window.
    var onClose: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// The chat field's text view turns Esc into autocomplete instead of passing it on,
    /// so catch it before it reaches the field.
    override func sendEvent(_ event: NSEvent) {
        // becomesKeyOnlyIfNeeded only takes focus for text fields, so a click on the answer or a
        // button left ⌘W and Esc going to the app behind. Any click takes keyboard focus instead
        // (the panel is non-activating, so the app the user is in stays active).
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !isKeyWindow {
            makeKey()
        }
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onClose?()
            return
        }
        // Shift+Return adds a line in the chat field; plain Return still sends.
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift,
           let editor = firstResponder as? NSTextView {
            editor.insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.sendEvent(event)
    }
}

final class OverlayWindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let actions: OverlayActions
    private var panel: OverlayPanel?
    private var expandedFrame: NSRect?

    private static let frameKey = "overlayFrame"
    private static let defaultSize = NSSize(width: 580, height: 340)
    /// Smallest size that still fits the header buttons, an answer line and the chat bar.
    private static let minimumSize = NSSize(width: 440, height: 260)
    private static let collapsedSize = NSSize(width: 190, height: 40)

    init(state: AppState, settings: AppSettings, actions: OverlayActions) {
        self.state = state
        self.settings = settings
        self.actions = actions
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = ensurePanel()
        if !panel.isVisible { panel.setFrame(clamped(panel.frame), display: false) }
        panel.orderFrontRegardless()
        state.isOverlayVisible = true
    }

    /// Lets the chat field receive typing without activating Seer or switching apps.
    func focusForTyping() {
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
        state.isOverlayVisible = false
    }

    /// Opened by the shortcut or menu: take keyboard focus (without activating Seer) so
    /// Esc and ⌘W close it right away.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
            panel?.makeKey()
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard let panel = ensurePanelIfExists(), collapsed != state.isOverlayCollapsed else { return }
        state.isOverlayCollapsed = collapsed
        if collapsed {
            expandedFrame = panel.frame
            panel.styleMask.remove(.resizable)
            let frame = NSRect(x: panel.frame.maxX - Self.collapsedSize.width, y: panel.frame.maxY - Self.collapsedSize.height,
                               width: Self.collapsedSize.width, height: Self.collapsedSize.height)
            panel.contentMinSize = Self.collapsedSize
            panel.setFrame(clamped(frame), display: true)
        } else {
            panel.styleMask.insert(.resizable)
            panel.contentMinSize = Self.minimumSize
            let size = expandedFrame?.size ?? Self.defaultSize
            let frame = NSRect(x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            panel.setFrame(clamped(frame), display: true)
        }
    }

    /// Moves the panel to the configured default position.
    func resetPosition() {
        guard let panel else { return }
        panel.setFrame(defaultFrame(size: panel.frame.size), display: true)
    }

    // MARK: - Panel

    private func ensurePanelIfExists() -> OverlayPanel? { panel }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let size = Self.defaultSize
        var frame = defaultFrame(size: size)
        if settings.overlayPosition == .remembered, let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            frame = NSRectFromString(saved)
            // A frame saved before the minimum was raised could be smaller; grow it from the top-left.
            let grown = NSSize(width: max(frame.width, Self.minimumSize.width), height: max(frame.height, Self.minimumSize.height))
            frame = NSRect(x: frame.minX, y: frame.maxY - grown.height, width: grown.width, height: grown.height)
        }
        let panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Seer"
        panel.onClose = { [weak self] in self?.actions.close() }   // same as the close button
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hideWindowButtons()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Stay visible to screenshots, screen sharing and recording/proctoring tools like
        // any normal window. Seer excludes the overlay from its *own* captures via
        // the ScreenCaptureKit content filter instead.
        panel.sharingType = .readOnly
        panel.contentMinSize = Self.minimumSize
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let hosting = NSHostingView(rootView: AnswerOverlayView(state: state, settings: settings, actions: actions))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(clamped(frame), display: false)
        self.panel = panel
        return panel
    }

    private func defaultFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        let x: CGFloat
        let y: CGFloat
        switch settings.overlayPosition {
        case .topLeft, .bottomLeft: x = visible.minX + margin
        default: x = visible.maxX - size.width - margin
        }
        switch settings.overlayPosition {
        case .bottomLeft, .bottomRight: y = visible.minY + margin
        default: y = visible.maxY - size.height - margin
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps the frame fully inside the visible area of the screen it's mostly on.
    private func clamped(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.max { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        panel?.hideWindowButtons()
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) { panel?.hideWindowButtons() }

    /// Enforces the minimum size on every drag. (`contentMinSize` alone doesn't hold: the
    /// SwiftUI hosting view resets it.)
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !state.isOverlayCollapsed else { return frameSize }
        return NSSize(width: max(frameSize.width, Self.minimumSize.width), height: max(frameSize.height, Self.minimumSize.height))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel else { return }
        panel.setFrame(clamped(panel.frame), display: true)
    }

    private func saveFrame() {
        guard let panel, !state.isOverlayCollapsed else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
