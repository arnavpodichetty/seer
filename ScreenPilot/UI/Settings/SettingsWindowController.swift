import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, apiKeys, ai, context, privacy, about

    var title: String {
        switch self {
        case .general: "General"
        case .apiKeys: "API Keys"
        case .ai: "AI"
        case .context: "Context"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .apiKeys: "key"
        case .ai: "sparkles"
        case .context: "person.text.rectangle"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// Every pane uses the same size, so the window never resizes when switching tabs.
    static let size = CGSize(width: 620, height: 640)
}

/// Settings window with the standard toolbar of icon tabs.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(environment: AppEnvironment) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]   // switch instantly
        for tab in SettingsTab.allCases {
            let size = SettingsTab.size
            let host = NSHostingController(rootView: Self.pane(tab, environment).frame(width: size.width, height: size.height))
            host.sizingOptions = []
            host.preferredContentSize = size
            host.title = "Seer"   // the tab controller shows the selected pane's title in the title bar
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = "Seer"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    @ViewBuilder
    private static func pane(_ tab: SettingsTab, _ environment: AppEnvironment) -> some View {
        switch tab {
        case .general: GeneralSettingsView(environment: environment)
        case .apiKeys: APIKeysSettingsView(environment: environment)
        case .ai: ModelSettingsView(environment: environment)
        case .context: ContextSettingsView(environment: environment)
        case .privacy: PrivacySettingsView(environment: environment)
        case .about: AboutView()
        }
    }
}

/// Menu bar apps have no main menu, so handle ⌘W here.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
