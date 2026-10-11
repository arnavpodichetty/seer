import Foundation

/// Splits a (possibly still streaming) response into Answer / Confidence / Explanation.
nonisolated enum AnswerParser {
    private static let answerMarker = try! NSRegularExpression(pattern: #"^\s*(#+\s*)?\*{0,2}\s*(final\s+)?answer\s*\*{0,2}\s*:?\s*\*{0,2}[ \t]*"#, options: [.caseInsensitive, .anchorsMatchLines])
    private static let confidenceMarker = try! NSRegularExpression(pattern: #"^\s*(#+\s*)?\*{0,2}\s*confidence\s*\*{0,2}\s*:?\s*\*{0,2}\s*(high|medium|low)?\**[^\n]*$"#, options: [.caseInsensitive, .anchorsMatchLines])
    private static let explanationMarker = try! NSRegularExpression(pattern: #"^\s*(#+\s*)?\*{0,2}\s*(explanation|reasoning|why)\s*\*{0,2}\s*:?\s*\*{0,2}[ \t]*"#, options: [.caseInsensitive, .anchorsMatchLines])

    static func parse(_ raw: String) -> ParsedAnswer {
        let text = stripThinking(raw)
        guard !text.isEmpty else { return .empty }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let answerMatch = answerMarker.firstMatch(in: text, range: full)
        let confidenceMatch = confidenceMarker.firstMatch(in: text, range: full)
        let explanationMatch = explanationMarker.firstMatch(in: text, range: full)

        var confidence: AnswerConfidence?
        if let confidenceMatch, confidenceMatch.range(at: 2).location != NSNotFound {
            confidence = AnswerConfidence(rawValue: ns.substring(with: confidenceMatch.range(at: 2)).lowercased())
        }

        // Answer runs from its marker (or the start) to the next section marker.
        let answerStart = answerMatch.map { $0.range.location + $0.range.length } ?? 0
        let sectionStarts = [confidenceMatch, explanationMatch].compactMap { $0?.range.location }.filter { $0 >= answerStart }
        let answerEnd = sectionStarts.min() ?? ns.length
        var answer = ns.substring(with: NSRange(location: answerStart, length: max(0, answerEnd - answerStart)))

        var explanation = ""
        if let explanationMatch {
            let start = explanationMatch.range.location + explanationMatch.range.length
            var end = ns.length
            if let confidenceMatch, confidenceMatch.range.location > start { end = confidenceMatch.range.location }
            explanation = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
        } else if answerMatch == nil, confidenceMatch == nil {
            // Unstructured reply: first paragraph is the answer, the rest the explanation.
            let paragraphs = text.components(separatedBy: "\n\n")
            if paragraphs.count > 1, !text.contains("```") {
                answer = paragraphs[0]
                explanation = paragraphs.dropFirst().joined(separator: "\n\n")
            }
        }

        return ParsedAnswer(answer: tidy(answer), confidence: confidence, explanation: tidy(explanation))
    }

    /// Removes `<think>…</think>` blocks; an unterminated one means the model is still thinking.
    static func stripThinking(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop leftover bold markers wrapping the whole answer.
        if t.hasPrefix("**") && t.hasSuffix("**") && t.count > 4 && !t.dropFirst(2).dropLast(2).contains("**") {
            t = String(t.dropFirst(2).dropLast(2))
        }
        return t
    }
}
