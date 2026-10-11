import Foundation
import Observation

enum OverlayPhase: Equatable {
    /// Nothing to show yet; `message` explains why (monitoring off, no question, …).
    case idle(String)
    case solving
    case answer
    case error(title: String, detail: String, hint: String?)
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var model: String?
    var isStreaming = false
    var isError = false
    var attachedScreen = false
}

enum ErrorAction: Equatable {
    case openScreenRecordingSettings
    case openAISettings
    case retry
}

/// Observable UI state shared by the overlay, menu bar, and settings.
///
/// Values the monitoring loop and streaming set over and over only notify observers
/// when they actually change, so views don't redraw for nothing.
@Observable
final class AppState {
    // Monitoring
    var isMonitoring = false
    var captureStatus: String {
        get { captureStatusValue }
        set { if newValue != captureStatusValue { captureStatusValue = newValue } }
    }
    private var captureStatusValue: String = "Monitoring is off"
    var lastCaptureAt: Date?
    var lastCaptureApp: String? {
        get { lastCaptureAppValue }
        set { if newValue != lastCaptureAppValue { lastCaptureAppValue = newValue } }
    }
    private var lastCaptureAppValue: String? = nil
    var detectionStatus: String {
        get { detectionStatusValue }
        set { if newValue != detectionStatusValue { detectionStatusValue = newValue } }
    }
    private var detectionStatusValue: String = ""

    // Environment
    var screenPermissionGranted = false
    var ollamaStatus: OllamaStatus {
        get { ollamaStatusValue }
        set { if newValue != ollamaStatusValue { ollamaStatusValue = newValue } }
    }
    private var ollamaStatusValue: OllamaStatus = .unknown
    var installedModels: [OllamaModelInfo] = []
    var visionModelCapable: Bool?

    // Overlay content
    var phase: OverlayPhase = .idle("Turn on monitoring to start detecting questions.")
    var errorAction: ErrorAction?
    var question: QuestionSummary?
    var rawResponse = ""
    var parsed = ParsedAnswer.empty
    var isThinking: Bool {
        get { isThinkingValue }
        set { if newValue != isThinkingValue { isThinkingValue = newValue } }
    }
    private var isThinkingValue: Bool = false
    var thinkingCharacters = 0
    var activeModel: String?
    var modelNote: String?
    var answerFromCache = false
    var answerStartedAt: Date?
    var answerDuration: TimeInterval?

    // Chat
    var chat: [ChatMessage] = []
    var isChatting = false

    // Overlay window
    var isOverlayVisible = false
    var isOverlayCollapsed = false
    /// False if another app already owns the chosen show/hide shortcut.
    var hotKeyRegistered = true

    var installedModelNames: [String] { installedModels.map(\.name) }

    func resetAnswer() {
        rawResponse = ""
        parsed = .empty
        isThinking = false
        thinkingCharacters = 0
        modelNote = nil
        answerFromCache = false
        answerDuration = nil
        errorAction = nil
    }
}
