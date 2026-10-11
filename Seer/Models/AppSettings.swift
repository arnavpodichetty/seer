import Foundation
import Observation

nonisolated enum OverlayPosition: String, CaseIterable, Sendable, Identifiable {
    case topRight, bottomRight, topLeft, bottomLeft, remembered
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topRight: "Top right"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .bottomLeft: "Bottom left"
        case .remembered: "Last position"
        }
    }
}

nonisolated enum AppearancePreference: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum CaptureScope: String, CaseIterable, Sendable, Identifiable {
    case frontmostWindow, display
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frontmostWindow: "Frontmost window"
        case .display: "Entire display"
        }
    }
}

nonisolated enum DisplayTarget: String, CaseIterable, Sendable, Identifiable {
    case underMouse, primary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .underMouse: "Display under the pointer"
        case .primary: "Primary display"
        }
    }
}

nonisolated protocol GlobalShortcut {
    var label: String { get }
    var keyCode: UInt32 { get }
    var carbonModifiers: UInt32 { get }
}

/// Carbon modifier flags.
nonisolated enum CarbonModifier {
    static let command: UInt32 = 1 << 8, shift: UInt32 = 1 << 9, option: UInt32 = 1 << 11, control: UInt32 = 1 << 12
}

/// A global shortcut the user records in Settings: a virtual key code plus Carbon modifiers.
nonisolated struct KeyShortcut: Codable, Hashable, Sendable, GlobalShortcut {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// How the key is shown, e.g. "R" or "Space".
    var keyName: String

    static let defaultOverlay = KeyShortcut(keyCode: 49, carbonModifiers: CarbonModifier.control | CarbonModifier.option, keyName: "Space")
    static let defaultReset = KeyShortcut(keyCode: 15, carbonModifiers: CarbonModifier.control | CarbonModifier.option, keyName: "R")
    static let defaultSolve = KeyShortcut(keyCode: 1, carbonModifiers: CarbonModifier.control | CarbonModifier.option, keyName: "S")

    var label: String {
        var glyphs = ""
        if carbonModifiers & CarbonModifier.control != 0 { glyphs += "⌃" }
        if carbonModifiers & CarbonModifier.option != 0 { glyphs += "⌥" }
        if carbonModifiers & CarbonModifier.shift != 0 { glyphs += "⇧" }
        if carbonModifiers & CarbonModifier.command != 0 { glyphs += "⌘" }
        return glyphs + keyName
    }

    /// Names for keys whose characters don't print well.
    static func specialKeyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 49: "Space"
        case 36: "Return"
        case 48: "Tab"
        case 51: "Delete"
        case 117: "⌦"
        case 53: "Esc"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 115: "Home"
        case 119: "End"
        case 116: "Page Up"
        case 121: "Page Down"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 105: "F13"
        case 107: "F14"
        case 113: "F15"
        case 106: "F16"
        case 64: "F17"
        case 79: "F18"
        case 80: "F19"
        default: nil
        }
    }

    /// Function keys can be used without modifiers; everything else needs ⌘, ⌃ or ⌥.
    var isFunctionKey: Bool { keyName.count > 1 && keyName.hasPrefix("F") && Int(keyName.dropFirst()) != nil }
}

nonisolated enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    /// Gemini first, then Groq, then local Ollama.
    case gemini
    /// Groq first, then Gemini, then local Ollama.
    case groq
    /// Local Ollama only; nothing leaves the Mac.
    case ollama
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gemini: "Gemini → Groq → Ollama"
        case .groq: "Groq → Gemini → Ollama"
        case .ollama: "Ollama only (local, private)"
        }
    }
}

nonisolated enum ModelStrategy: String, CaseIterable, Sendable, Identifiable {
    /// Text model for OCR-only questions, vision model for visual ones.
    case automatic
    /// One multimodal model for everything; avoids model swaps.
    case visionOnly
    /// Never send screenshots; OCR text only.
    case textOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic (text + vision)"
        case .visionOnly: "Vision model only"
        case .textOnly: "Text model only (OCR)"
        }
    }
}

nonisolated enum DetailLevel: String, CaseIterable, Sendable, Identifiable {
    case brief, standard, detailed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum SpeedPreference: String, CaseIterable, Sendable, Identifiable {
    /// No model "thinking"; quickest answers.
    case faster
    /// Thinking only for math, logic and programming.
    case balanced
    /// Thinking for every question.
    case thorough
    var id: String { rawValue }
    var label: String {
        switch self {
        case .faster: "Faster answers"
        case .balanced: "Balanced"
        case .thorough: "More thorough (slower)"
        }
    }
}

/// User preferences, persisted to `UserDefaults`.
@Observable
final class AppSettings {
    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
    ]
    static let defaultExcludedKeywords = ["Private Browsing", "Incognito", "InPrivate", "Password"]

    @ObservationIgnored private let defaults: UserDefaults

    // General
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    var resumeMonitoringAtLaunch: Bool { didSet { defaults.set(resumeMonitoringAtLaunch, forKey: "resumeMonitoringAtLaunch") } }
    var captureInterval: Double { didSet { defaults.set(captureInterval, forKey: "captureInterval") } }
    var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") } }
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") } }
    var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: "overlayPosition") } }
    var appearance: AppearancePreference { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var showOverlayForNewAnswers: Bool { didSet { defaults.set(showOverlayForNewAnswers, forKey: "showOverlayForNewAnswers") } }
    var overlayShortcut: KeyShortcut { didSet { store(overlayShortcut, "overlayHotKey") } }
    var resetShortcut: KeyShortcut { didSet { store(resetShortcut, "resetHotKey") } }
    var solveShortcut: KeyShortcut { didSet { store(solveShortcut, "solveHotKey") } }
    var explanationExpanded: Bool { didSet { defaults.set(explanationExpanded, forKey: "explanationExpanded") } }
    var captureScope: CaptureScope { didSet { defaults.set(captureScope.rawValue, forKey: "captureScope") } }
    var displayTarget: DisplayTarget { didSet { defaults.set(displayTarget.rawValue, forKey: "displayTarget") } }
    /// Screenshots are read at up to 3000 px so small text stays legible (the AI gets its own resized copy).
    let captureMaxDimension = 3000

    // AI
    var aiProvider: AIProvider { didSet { defaults.set(aiProvider.rawValue, forKey: "aiProvider") } }
    var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }
    var geminiFallbackModel: String { didSet { defaults.set(geminiFallbackModel, forKey: "geminiFallbackModel") } }
    var geminiVisionModel: String { didSet { defaults.set(geminiVisionModel, forKey: "geminiVisionModel") } }
    var groqModel: String { didSet { defaults.set(groqModel, forKey: "groqModel") } }
    var groqVisionModel: String { didSet { defaults.set(groqVisionModel, forKey: "groqVisionModel") } }
    /// Optional OpenAI-compatible provider the user pays for; tried before everything else.
    var customEnabled: Bool { didSet { defaults.set(customEnabled, forKey: "customEnabled") } }
    var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: "customBaseURL") } }
    var customModel: String { didSet { defaults.set(customModel, forKey: "customModel") } }
    var customSendsImages: Bool { didSet { defaults.set(customSendsImages, forKey: "customSendsImages") } }
    var ollamaAddress: String { didSet { defaults.set(ollamaAddress, forKey: "ollamaAddress") } }
    var textModel: String { didSet { defaults.set(textModel, forKey: "textModel") } }
    var visionModel: String { didSet { defaults.set(visionModel, forKey: "visionModel") } }
    var modelStrategy: ModelStrategy { didSet { defaults.set(modelStrategy.rawValue, forKey: "modelStrategy") } }
    var maxResponseTokens: Int { didSet { defaults.set(maxResponseTokens, forKey: "maxResponseTokens") } }
    var detailLevel: DetailLevel { didSet { defaults.set(detailLevel.rawValue, forKey: "detailLevel") } }
    var speedPreference: SpeedPreference { didSet { defaults.set(speedPreference.rawValue, forKey: "speedPreference") } }
    var useAIClassification: Bool { didSet { defaults.set(useAIClassification, forKey: "useAIClassification") } }
    var keepSingleModelLoaded: Bool { didSet { defaults.set(keepSingleModelLoaded, forKey: "keepSingleModelLoaded") } }
    var requestTimeout: Double { didSet { defaults.set(requestTimeout, forKey: "requestTimeout") } }
    /// Longest edge of images sent to the AI: sharp enough for diagrams and small labels
    /// without the token cost of larger images. (Groq gets 1024 px; its per-minute limit is tight.)
    let visionMaxDimension = 1536

    // Profile
    var profileSummary: String { didSet { defaults.set(profileSummary, forKey: "profileSummary") } }
    var useProfileInAnswers: Bool { didSet { defaults.set(useProfileInAnswers, forKey: "useProfileInAnswers") } }

    // Privacy
    var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    var excludedWindowKeywords: [String] { didSet { defaults.set(excludedWindowKeywords, forKey: "excludedWindowKeywords") } }
    var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }

    private func store(_ shortcut: KeyShortcut, _ key: String) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        func raw<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
            defaults.string(forKey: key).flatMap(E.init(rawValue:)) ?? fallback
        }
        launchAtLogin = value("launchAtLogin", false)
        resumeMonitoringAtLaunch = value("resumeMonitoringAtLaunch", false)
        captureInterval = value("captureInterval", 1.5)
        showInMenuBar = value("showInMenuBar", true)
        overlayOpacity = value("overlayOpacity", 0.6)
        overlayPosition = raw("overlayPosition", .topRight)
        appearance = raw("appearance", .system)
        showOverlayForNewAnswers = value("showOverlayForNewAnswers", false)
        func shortcut(_ key: String, _ fallback: KeyShortcut) -> KeyShortcut {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) } ?? fallback
        }
        overlayShortcut = shortcut("overlayHotKey", .defaultOverlay)
        resetShortcut = shortcut("resetHotKey", .defaultReset)
        solveShortcut = shortcut("solveHotKey", .defaultSolve)
        explanationExpanded = value("explanationExpanded", true)
        captureScope = raw("captureScope", .frontmostWindow)
        displayTarget = raw("displayTarget", .underMouse)

        aiProvider = raw("aiProvider", .groq)
        // Flash-Lite answered real questions correctly in ~2 s; 3.5 Flash is the backup.
        geminiModel = value("geminiModel", "gemini-3.5-flash-lite")
        geminiFallbackModel = value("geminiFallbackModel", "gemini-3.5-flash")
        // Read a diagram correctly in ~10 s while Flash-Lite stalled on images.
        geminiVisionModel = value("geminiVisionModel", "gemini-3.6-flash")
        // ~0.3 s answers; gpt-oss-120b got the test math right, qwen3.8-27b reads images.
        groqModel = value("groqModel", "openai/gpt-oss-120b")
        groqVisionModel = value("groqVisionModel", "qwen/qwen3.8-27b")
        customEnabled = value("customEnabled", false)
        customBaseURL = value("customBaseURL", "https://api.openai.com/v1")
        customModel = value("customModel", "")
        customSendsImages = value("customSendsImages", true)
        ollamaAddress = value("ollamaAddress", "http://127.0.0.1:11434")
        // Instruct variants never "think", so they answer fastest. If they aren't installed,
        // ModelRouter falls back to an installed sibling such as qwen3:4b.
        textModel = value("textModel", "qwen3:4b-instruct")
        visionModel = value("visionModel", "qwen3-vl:4b-instruct")
        modelStrategy = raw("modelStrategy", .automatic)
        maxResponseTokens = value("maxResponseTokens", 1024)
        detailLevel = raw("detailLevel", .brief)
        speedPreference = raw("speedPreference", .faster)
        useAIClassification = value("useAIClassification", true)
        // Two 4B models fit in 16 GB; unloading between them forces slow reloads.
        keepSingleModelLoaded = value("keepSingleModelLoaded", false)
        requestTimeout = value("requestTimeout", 180.0)

        profileSummary = value("profileSummary", "")
        useProfileInAnswers = value("useProfileInAnswers", true)

        excludedBundleIDs = value("excludedBundleIDs", Self.defaultExcludedApps)
        excludedWindowKeywords = value("excludedWindowKeywords", Self.defaultExcludedKeywords)
        historyEnabled = value("historyEnabled", true)
    }

    static let geminiModelChoices = ["gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash"]

    static let groqModelChoices = ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b"]
    static let groqVisionModelChoices = ["qwen/qwen3.8-27b"]

    /// API keys live in the Keychain and are read once at launch: the monitoring loop and
    /// every answer check for them, and a Keychain lookup each time is slow.
    private(set) var groqAPIKey: String? = KeychainStore.read(service: KeychainStore.groqService)
    private(set) var geminiAPIKey: String? = KeychainStore.read()

    /// Saves (or, with an empty string, removes) the Groq key.
    func setGroqAPIKey(_ key: String) {
        KeychainStore.write(key, service: KeychainStore.groqService)
        groqAPIKey = KeychainStore.read(service: KeychainStore.groqService)
    }

    func setGeminiAPIKey(_ key: String) {
        KeychainStore.write(key)
        geminiAPIKey = KeychainStore.read()
    }

    private(set) var customAPIKey: String? = KeychainStore.read(service: KeychainStore.customService)

    func setCustomAPIKey(_ key: String) {
        KeychainStore.write(key, service: KeychainStore.customService)
        customAPIKey = KeychainStore.read(service: KeychainStore.customService)
    }

    /// The custom provider's chat completions URL, from a base like "https://api.openai.com/v1"
    /// (a full ".../chat/completions" URL is accepted too).
    var customEndpoint: URL? {
        var base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), url.host != nil else { return nil }
        return url
    }

    /// The custom model name when it's switched on and fully set up.
    var activeCustomModel: String? {
        let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard customEnabled, !model.isEmpty, customAPIKey != nil, customEndpoint != nil else { return nil }
        return model
    }

    /// The user's context, if the Context switch is on.
    var activeProfile: String? {
        let trimmed = profileSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return useProfileInAnswers && !trimmed.isEmpty ? trimmed : nil
    }

    var ollamaURL: URL {
        var address = ollamaAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        return URL(string: address) ?? URL(string: "http://127.0.0.1:11434")!
    }
}
