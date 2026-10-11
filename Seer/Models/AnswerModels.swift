import Foundation

nonisolated enum AnswerConfidence: String, Codable, Sendable {
    case high, medium, low
}

/// The model's response split into the sections the prompt asks for.
nonisolated struct ParsedAnswer: Codable, Sendable, Equatable {
    var answer: String
    var confidence: AnswerConfidence?
    var explanation: String

    static let empty = ParsedAnswer(answer: "", confidence: nil, explanation: "")
    var isEmpty: Bool { answer.isEmpty && explanation.isEmpty }
}

nonisolated struct AnswerRecord: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var fingerprint: QuestionFingerprint
    var questionExcerpt: String
    var kind: QuestionKind
    var mode: ReasoningMode
    var model: String
    var parsed: ParsedAnswer
    var raw: String
    var createdAt: Date
    var duration: TimeInterval
}

/// Lightweight description of the question currently shown in the overlay.
nonisolated struct QuestionSummary: Sendable, Equatable {
    var excerpt: String
    var kind: QuestionKind
    var mode: ReasoningMode
    var sourceApp: String?
}
