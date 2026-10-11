import Foundation

/// Stable, OCR-noise-tolerant identity for a question.
nonisolated struct QuestionFingerprint: Codable, Sendable, Hashable {
    /// Hex FNV-1a hash of the normalized text.
    var id: String
    var normalized: String
    /// Hashed word bigrams (unigrams for very short text).
    var shingles: Set<UInt64>
    /// Numeric tokens; questions differing only in numbers are different questions.
    var numbers: Set<String>
}

nonisolated enum QuestionFingerprintService {
    static let sameQuestionJaccard = 0.8
    static let sameQuestionContainment = 0.9

    static func make(from text: String) -> QuestionFingerprint {
        let normalized = normalize(text)
        let tokens = tokenize(normalized)
        return QuestionFingerprint(
            id: String(format: "%016llx", fnv1a(normalized)),
            normalized: normalized,
            shingles: shingles(tokens),
            numbers: Set(tokens.filter { $0.contains(where: \.isNumber) })
        )
    }

    /// Lowercases, folds diacritics and look-alike symbols, strips punctuation that OCR
    /// tends to get wrong, and collapses whitespace. Math operators are kept.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        var out = ""
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "\u{2212}", "\u{2013}", "\u{2014}": out.append("-")
            case "\u{00D7}", "\u{22C5}": out.append("*")
            case "\u{00F7}": out.append("/")
            case "+", "-", "*", "/", "=", "<", ">", "^", "%", ".", "\u{221A}", "\u{03C0}", "\u{2264}", "\u{2265}", "\u{2260}":
                out.unicodeScalars.append(scalar)
            default:
                if CharacterSet.alphanumerics.contains(scalar) {
                    out.unicodeScalars.append(scalar)
                } else {
                    out.append(" ")
                }
            }
        }
        // Drop sentence periods but keep decimal points ("3.5").
        let tokens = out.split(separator: " ").map { token -> Substring in
            var t = token
            while let last = t.last, last == "." { t = t.dropLast() }
            while let first = t.first, first == "." { t = t.dropFirst() }
            return t
        }.filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    static func tokenize(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    static func shingles(_ tokens: [String]) -> Set<UInt64> {
        guard tokens.count >= 3 else { return Set(tokens.map { fnv1a($0) }) }
        var set = Set<UInt64>()
        for i in 0..<(tokens.count - 1) {
            set.insert(fnv1a(tokens[i] + " " + tokens[i + 1]))
        }
        return set
    }

    static func jaccard(_ a: QuestionFingerprint, _ b: QuestionFingerprint) -> Double {
        let union = a.shingles.union(b.shingles).count
        guard union > 0 else { return 1 }
        return Double(a.shingles.intersection(b.shingles).count) / Double(union)
    }

    /// Share of the smaller fingerprint's shingles found in the larger one.
    static func containment(_ a: QuestionFingerprint, _ b: QuestionFingerprint) -> Double {
        let smaller = min(a.shingles.count, b.shingles.count)
        guard smaller > 0 else { return 0 }
        return Double(a.shingles.intersection(b.shingles).count) / Double(smaller)
    }

    /// True if two detections refer to the same question, tolerating OCR noise and
    /// partial visibility after scrolling, but not changed numbers.
    static func isSameQuestion(_ a: QuestionFingerprint, _ b: QuestionFingerprint) -> Bool {
        if a.id == b.id { return true }
        if a.shingles.isEmpty || b.shingles.isEmpty { return false }
        if jaccard(a, b) >= sameQuestionJaccard && a.numbers == b.numbers { return true }

        let (small, large) = a.shingles.count <= b.shingles.count ? (a, b) : (b, a)
        let sizeRatio = Double(small.shingles.count) / Double(large.shingles.count)
        // Scrolling can hide a large part of a question, so allow a small visible
        // fragment to match as long as it is substantial on its own.
        let minimumRatio = small.shingles.count >= 8 ? 0.35 : 0.5
        return small.shingles.count >= 4
            && sizeRatio >= minimumRatio
            && containment(a, b) >= sameQuestionContainment
            && small.numbers.isSubset(of: large.numbers)
    }

    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
