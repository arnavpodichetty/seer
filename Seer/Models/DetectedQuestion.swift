import CoreGraphics
import Foundation

nonisolated enum QuestionKind: String, Codable, Sendable, CaseIterable {
    case multipleChoice
    case math
    case sql
    case programming
    case logic
    case personal
    case visual
    case general

    var displayName: String {
        switch self {
        case .multipleChoice: "Multiple choice"
        case .math: "Math"
        case .sql: "SQL"
        case .programming: "Programming"
        case .logic: "Logic"
        case .personal: "About you"
        case .visual: "Visual"
        case .general: "Question"
        }
    }

    var symbolName: String {
        switch self {
        case .multipleChoice: "list.bullet.circle"
        case .math: "function"
        case .sql: "cylinder.split.1x2"
        case .programming: "chevron.left.forwardslash.chevron.right"
        case .logic: "brain"
        case .personal: "person.wave.2"
        case .visual: "chart.xyaxis.line"
        case .general: "questionmark.circle"
        }
    }
}

nonisolated enum ReasoningMode: String, Codable, Sendable {
    case text
    case vision
}

/// A question found on screen by `QuestionDetector`.
nonisolated struct DetectedQuestion: Sendable, Equatable {
    /// OCR text of the question itself (stem, options, inline code/data).
    var text: String
    /// Nearby OCR text that may hold context such as a schema or a table.
    var contextText: String
    var kind: QuestionKind
    var mode: ReasoningMode
    var score: Double
    /// True when the heuristics are unsure and an AI classification should confirm.
    var isAmbiguous: Bool
    /// Normalized region in the captured image, top-left origin.
    var region: CGRect
    var options: [String]
    var fingerprint: QuestionFingerprint
    /// Manual "Solve now" with no detected question: the model must find it in the screen text.
    var findInScreen = false
    /// Found automatically in a picture: the model may reply NO_QUESTION if nothing is asked.
    var needsConfirmation = false

    /// A question that exists only as a picture (diagram, grid, chart): the model reads it
    /// from the screenshot. Identified by the frame's perceptual hash since there's no text.
    static func visual(ocrText: String, signature: FrameSignature?) -> DetectedQuestion {
        let identity = ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "visual \(String(signature?.dHash ?? 0, radix: 16))" : ocrText
        return DetectedQuestion(text: String(ocrText.prefix(3000)), contextText: "", kind: .visual, mode: .vision, score: 0,
                                isAmbiguous: false, region: .zero, options: [],
                                fingerprint: QuestionFingerprintService.make(from: identity), findInScreen: true)
    }

    var excerpt: String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Image on screen (no text)" }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 220 ? String(flat.prefix(220)) + "…" : flat
    }
}

nonisolated enum DetectionOutcome: Sendable, Equatable {
    case none(reason: String)
    case question(DetectedQuestion, candidateCount: Int)

    var question: DetectedQuestion? {
        if case let .question(q, _) = self { return q }
        return nil
    }
}
