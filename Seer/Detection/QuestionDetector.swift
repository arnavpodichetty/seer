import CoreGraphics
import Foundation

/// Cheap, heuristic first stage that finds the most prominent actionable question in OCR
/// output. Low-confidence results are flagged `isAmbiguous` so the orchestrator can ask
/// the local model to confirm before spending a full inference on them.
nonisolated struct QuestionDetector {
    struct Configuration: Sendable {
        var minLineConfidence: Float = 0.3
        var actionableScore = 3.5
        var ambiguousScore = 2.5
        var maxCandidateRows = 32
        var maxQuestionCharacters = 3000
        var maxContextCharacters = 1500
    }

    var configuration = Configuration()

    // MARK: - Layout primitives

    struct Row: Sendable {
        var text: String
        var box: CGRect          // pixels, top-left origin
        var confidence: Float
    }

    struct Block: Sendable {
        var rows: [Row]
        var box: CGRect { rows.dropFirst().reduce(rows[0].box) { $0.union($1.box) } }
    }

    struct Candidate {
        var rows: [Row]
        var region: Int
        var startRowIndex: Int   // index into region's flattened rows
        var endRowIndex: Int
        var score: Double
        var ranking: Double
        var kind: QuestionKind
        var needsVision: Bool
        var options: [String]
    }

    // MARK: - Entry point

    /// `forced` (manual "Solve now") accepts any anchored candidate, however weak.
    func detect(_ ocr: OCRResult, forced: Bool = false) -> DetectionOutcome {
        let size = ocr.imageSize.width > 0 && ocr.imageSize.height > 0 ? ocr.imageSize : CGSize(width: 1000, height: 1000)
        let lines = ocr.lines
            .filter { $0.confidence >= configuration.minLineConfidence && $0.text.count >= 2 && !Self.isChrome($0.text) }
            .map { line -> OCRLine in
                var l = line
                l.box = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                               width: line.box.width * size.width, height: line.box.height * size.height)
                return l
            }
        guard !lines.isEmpty else { return .none(reason: "No readable text") }

        let medianHeight = Self.median(lines.map(\.box.height))
        let regions = Self.splitColumns(lines, width: size.width, depth: 2)
        let chartLike = Self.looksLikeChart(lines)

        var candidates: [Candidate] = []
        var regionRows: [[Row]] = []
        for (regionIndex, regionLines) in regions.enumerated() {
            let rows = Self.makeRows(regionLines, medianHeight: medianHeight)
            regionRows.append(rows)
            let blocks = Self.makeBlocks(rows, medianHeight: medianHeight)
            var rowOffset = 0
            var blockStarts: [Int] = []
            for block in blocks {
                blockStarts.append(rowOffset)
                rowOffset += block.rows.count
            }
            for i in blocks.indices {
                if let candidate = buildCandidate(blocks: blocks, blockStarts: blockStarts, anchor: i, region: regionIndex,
                                                  medianHeight: medianHeight, imageSize: size, chartLike: chartLike) {
                    candidates.append(candidate)
                }
            }
        }

        let viable = candidates.filter { $0.score >= (forced ? 0.5 : configuration.ambiguousScore) }
        guard let best = viable.max(by: { $0.ranking < $1.ranking }) else {
            return .none(reason: "No question detected")
        }

        var text = best.rows.map(\.text).joined(separator: "\n")
        if text.count > configuration.maxQuestionCharacters {
            text = String(text.prefix(configuration.maxQuestionCharacters))
        }
        let context = Self.context(around: best, rows: regionRows[best.region], limit: configuration.maxContextCharacters)
        let unionBox = best.rows.dropFirst().reduce(best.rows[0].box) { $0.union($1.box) }
        let region = CGRect(x: unionBox.minX / size.width, y: unionBox.minY / size.height,
                            width: unionBox.width / size.width, height: unionBox.height / size.height)

        let question = DetectedQuestion(
            text: text,
            contextText: context,
            kind: best.kind,
            mode: best.needsVision ? .vision : .text,
            score: best.score,
            isAmbiguous: best.score < configuration.actionableScore,
            region: region,
            options: best.options,
            fingerprint: QuestionFingerprintService.make(from: text)
        )
        return .question(question, candidateCount: viable.count)
    }

    // MARK: - Candidates

    private func buildCandidate(blocks: [Block], blockStarts: [Int], anchor i: Int, region: Int,
                                medianHeight: CGFloat, imageSize: CGSize, chartLike: Bool) -> Candidate? {
        var anchorRows = blocks[i].rows
        var anchorOffset = 0
        // An interview prompt is just its own sentence: drop whatever shares the block
        // (an AI summary under a search box, page text, the logo beside it).
        let isInterviewPrompt = Self.matches(anchorRows.map(\.text).joined(separator: " "), Patterns.interview)
        if isInterviewPrompt {
            let texts = anchorRows.map(\.text)
            if let segment = Self.wrappedSegments(texts).first(where: { seg in
                Self.matches(seg.map { texts[$0] }.joined(separator: " "), Patterns.interview)
            }), let first = segment.first {
                // Once the prompt reads as complete, a capitalized line starts something else
                // (tabs, "AI Overview"); real wrapped continuations start lowercase.
                var kept: [Row] = []
                for index in segment {
                    let row = anchorRows[index]
                    let complete = Self.matches(kept.map(\.text).joined(separator: " "), Patterns.interview)
                    if complete, row.text.first?.isUppercase ?? false { break }
                    kept.append(row)
                }
                anchorOffset = first
                anchorRows = kept
                anchorRows[0].text = Self.dropLeadingCells(anchorRows[0].text)
            }
        }
        var rows = anchorRows
        var start = blockStarts[i] + anchorOffset
        var end = start + rows.count - 1

        // Include a "Question 3" style header directly above.
        if i > 0, anchorOffset == 0, blocks[i - 1].rows.count <= 2,
           blocks[i - 1].rows.contains(where: { Self.isHeader($0.text) }),
           blocks[i].box.minY - blocks[i - 1].box.maxY < medianHeight * 4 {
            rows = blocks[i - 1].rows + rows
            start = blockStarts[i - 1]
        }

        // Pull in supporting blocks below: answer options, code, data. Plain short lines only
        // follow an explicit question ("…?" / "which of the following"); interview prompts
        // stand alone so page furniture (tabs, AI summaries) never joins them.
        let anchorText = anchorRows.map(\.text).joined(separator: " ")
        let invitesChoices = anchorText.contains("?") || Self.matches(anchorText, Patterns.whichOfTheFollowing)
            || anchorRows.contains { Self.matches($0.text, Patterns.choiceInstruction) }
        var j = i + 1
        var appended = 0
        while j < blocks.count, appended < 4, rows.count < configuration.maxCandidateRows {
            let next = blocks[j]
            let bottom = rows.last.map(\.box.maxY) ?? 0
            if next.box.minY - bottom > medianHeight * 3.5 { break }
            if next.rows.contains(where: { Self.isNamedHeader($0.text) }) { break }
            if isInterviewPrompt { break }
            let structured = next.rows.contains { Self.isOption($0.text) || Self.isCodeLike($0.text) || Self.matches($0.text.lowercased(), Patterns.likert) }
            let shortChoices = invitesChoices && next.rows.count <= 6 && next.rows.allSatisfy { $0.text.count <= 80 }
            guard structured || shortChoices else { break }
            rows += next.rows
            end = blockStarts[j] + next.rows.count - 1
            appended += 1
            j += 1
        }
        if rows.count > configuration.maxCandidateRows { rows = Array(rows.prefix(configuration.maxCandidateRows)) }

        // A long prose block right below usually means the question is already answered (FAQ).
        var followedByProse = false
        if j < blocks.count {
            let next = blocks[j]
            let gap = next.box.minY - (rows.last.map(\.box.maxY) ?? 0)
            let words = next.rows.reduce(0) { $0 + Self.wordTokens($1.text) }
            followedByProse = gap < medianHeight * 3.5 && next.rows.count >= 3 && words >= 30
                && !next.rows.contains { Self.isOption($0.text) }
        }

        let features = Self.score(rows: rows, anchorRows: anchorRows, followedByProse: followedByProse, chartLike: chartLike)
        guard features.score > 0 else { return nil }

        // Prominence: larger text, closer to the vertical middle, higher OCR confidence.
        let avgHeight = rows.map(\.box.height).reduce(0, +) / CGFloat(rows.count)
        let heightRatio = min(2, max(0.5, avgHeight / max(medianHeight, 1)))
        let centerY = (rows.first!.box.minY + rows.last!.box.maxY) / 2 / imageSize.height
        let avgConfidence = Double(rows.map(\.confidence).reduce(0, +)) / Double(rows.count)
        let prominence = 0.4 * Double(heightRatio - 1) + 0.3 * (1 - abs(Double(centerY) - 0.5) * 2) + 0.3 * (avgConfidence - 0.5) * 2

        return Candidate(rows: rows, region: region, startRowIndex: start, endRowIndex: end,
                         score: features.score, ranking: features.score + prominence,
                         kind: features.kind,
                         // OCR that's unsure of itself often garbles symbols (÷ read as -), so let the model see the crop.
                         needsVision: features.needsVision || (features.kind != .interview && avgConfidence < 0.5),
                         options: features.options)
    }

    struct Features: Equatable {
        var score: Double
        var kind: QuestionKind
        var needsVision: Bool
        var options: [String]
    }

    /// Scores a candidate. Only `anchorRows` (the block the candidate starts from) can supply
    /// the question itself; appended rows (options, code, data) only add support. A question
    /// must be a real natural-language sentence: one ending in "?", one starting with a task
    /// verb, or an interview prompt. Code and short UI labels never count.
    static func score(rows: [Row], anchorRows: [Row]? = nil, followedByProse: Bool = false, chartLike: Bool = false) -> Features {
        let text = rows.map(\.text).joined(separator: "\n")
        let lower = text.lowercased()
        let wordCount = lower.split(whereSeparator: { $0.isWhitespace }).count
        let none = Features(score: 0, kind: .general, needsVision: false, options: [])

        let proseRows = (anchorRows ?? rows).filter { !isCodeLike($0.text) && !isOption($0.text) }
        let paragraph = proseRows.map(\.text).joined(separator: " ")
        let sentences = joinWrappedRows(proseRows.map(\.text)).flatMap(splitSentences)
        // Sentence starts: each sentence, plus each row (headings/prompts often lack punctuation).
        // Side-by-side panes share a row ("EXPLORER | Problem: Write…"), so each cell can start a sentence too.
        let starts = sentences + proseRows.flatMap { row in
            [row.text] + (row.text.contains(" | ") ? row.text.components(separatedBy: " | ") : [])
        }

        var questionSentences = 0
        var interrogative = false
        var imperative = false
        var academic = false
        var task = false
        var interview = false
        for sentence in sentences where isProse(sentence) {
            let tokens = wordTokens(sentence)
            if sentence.hasSuffix("?") && tokens >= 4 {
                questionSentences += 1
                if matches(sentence, Patterns.interrogativeStart) { interrogative = true }
            }
        }
        for start in starts where isProse(start) {
            let tokens = wordTokens(start)
            let terminated = start.last.map { ".:?".contains($0) } ?? false
            if matches(start, Patterns.interview) { interview = true }
            if (tokens >= 4 || (tokens == 3 && terminated)) && matches(start, Patterns.imperativeStart) {
                imperative = true
                if matches(start, Patterns.academicStart) { academic = true }
                if matches(start, Patterns.task) { task = true }
            }
            if matches(start, Patterns.choiceInstruction) { imperative = true; task = true }
        }

        let cells = rows.flatMap { $0.text.components(separatedBy: " | ") }
        var options = cells.filter { isOption($0) }
        let likert = matches(lower, Patterns.likert)
        if likert, options.count < 2 {
            options = cells.filter { matches($0.lowercased(), Patterns.likertAnchor) }
        }
        // "Choose the statement most like you" + a list of plain statements: the statements are the choices.
        let choiceRows = anchorRows.map { anchors in rows.dropFirst(anchors.count) } ?? []
        if options.count < 2, starts.contains(where: { matches($0, Patterns.choiceInstruction) }),
           choiceRows.count >= 2, choiceRows.allSatisfy({ $0.text.count <= 120 && !isCodeLike($0.text) }) {
            options = choiceRows.map(\.text)
        }
        let rowTexts = Set(rows.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) })
        if options.count < 2, rowTexts.contains("true"), rowTexts.contains("false") { options = ["True", "False"] }
        let whichOfFollowing = matches(lower, Patterns.whichOfTheFollowing)

        let codeRows = rows.filter { isCodeLike($0.text) }.count
        let sqlStrong = count(lower, Patterns.sqlStrong)
        let isSQL = sqlStrong >= 1 && sqlStrong + count(lower, Patterns.sqlWeak) >= 2
        let isProgramming = count(lower, Patterns.programming) >= 2 || (codeRows >= 2 && codeRows < rows.count)
        let mathSymbols = count(text, Patterns.mathSymbols)
        let isMath = mathSymbols >= 2 || (count(lower, Patterns.mathWords) >= 1 && text.contains(where: \.isNumber))
        let asksForValue = matches(text, Patterns.equalsQuestion)
        let isBareEquation = rows.count <= 5 && text.contains("=") && codeRows == 0 && (mathSymbols >= 3 || (asksForValue && mathSymbols >= 2))
        if !imperative, mathSymbols >= 1, starts.contains(where: { matches($0, Patterns.mathVerbStart) }) { imperative = true; task = true }
        let isLogic = count(lower, Patterns.logic) >= 1
        let visualHits = count(lower, Patterns.visual)
        let geometry = count(text, Patterns.geometry) >= 1

        let anchored = questionSentences > 0 || imperative || interview || (likert && options.count >= 2)
        guard anchored || isBareEquation else { return none }

        var score = 0.0
        if interview { score += 3.5 }
        if questionSentences > 0 { score += 2.0 + (interrogative ? 0.5 : 0) }
        if imperative { score += 2.0 + (academic ? 0.5 : 0) + (task ? 1.0 : 0) }
        if !anchored && isBareEquation { score += 2.5 }
        if rows.contains(where: { isNamedHeader($0.text) }) { score += 1.0 }
        if options.count >= 2 { score += 2.0 }
        if likert && options.count >= 2 { score += 1.5 }
        if whichOfFollowing { score += 1.0 }
        if isSQL || isProgramming || isMath { score += 0.5 }
        if isLogic { score += 0.5 }
        if visualHits > 0 { score += 0.5 }

        // Already-answered questions (FAQ entries, Q&A articles).
        if !interview && !imperative && options.count < 2 && (followedByProse || answeredInline(rows)) { score -= 1.5 }
        // Rhetorical questions buried in long prose.
        let proseHeavy = proseRows.count >= 5 && Double(paragraph.count) / Double(max(proseRows.count, 1)) > 45
        if proseHeavy && !interview && !imperative && options.count < 2
            && Double(questionSentences) / Double(max(sentences.count, 1)) < 0.25 { score -= 1.5 }
        if wordCount > 350 && !imperative && options.count < 2 { score -= 2.0 }
        // Screens dominated by code (editors, terminals).
        if Double(codeRows) / Double(rows.count) > 0.6 && !imperative { score -= 2.0 }

        let kind: QuestionKind
        if options.count >= 2 || whichOfFollowing { kind = .multipleChoice }
        else if interview { kind = .interview }
        else if isSQL { kind = .sql }
        else if isProgramming { kind = .programming }
        else if isMath { kind = .math }
        else if isLogic { kind = .logic }
        else if visualHits > 0 || chartLike { kind = .visual }
        else { kind = .general }

        let needsVision = kind != .interview && (visualHits > 0 || chartLike || (geometry && (kind == .math || kind == .multipleChoice)))
        return Features(score: score, kind: kind, needsVision: needsVision, options: options)
    }

    /// A question immediately followed, within the same candidate, by a long prose answer.
    private static func answeredInline(_ rows: [Row]) -> Bool {
        guard let index = rows.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") }) else { return false }
        let after = rows[(index + 1)...].filter { !isOption($0.text) && !isCodeLike($0.text) }
        let words = after.reduce(0) { $0 + wordTokens($1.text) }
        return words >= 25
    }

    /// Re-joins lines that were wrapped mid-sentence, while keeping separate labels
    /// (stacked UI text, list items) as separate segments.
    static func joinWrappedRows(_ rows: [String]) -> [String] {
        wrappedSegments(rows).map { indices in
            indices.map { rows[$0].trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
    }

    /// Groups row indices into sentences that were wrapped across lines.
    static func wrappedSegments(_ rows: [String]) -> [[Int]] {
        var segments: [[Int]] = []
        var lastText = ""
        for (index, row) in rows.enumerated() {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            // Wrapped text: the previous line has no closing punctuation and either is long
            // or is continued by a lowercase word ("…tell me about a" / "time you had…").
            let continuesLowercase = trimmed.first?.isLowercase ?? false
            if !segments.isEmpty, let end = lastText.last, !".?!:".contains(end), lastText.count >= 40 || continuesLowercase {
                segments[segments.count - 1].append(index)
                lastText = trimmed
            } else {
                segments.append([index])
                lastText = trimmed
            }
        }
        return segments
    }

    /// "Google | tell me about a time…" → "tell me about a time…": drops table-style cells
    /// (logos, labels) in front of the prompt on the same baseline.
    static func dropLeadingCells(_ text: String) -> String {
        let cells = text.components(separatedBy: " | ")
        guard cells.count > 1 else { return text }
        let index = cells.firstIndex { matches($0, Patterns.interview) } ?? cells.count - 1
        return cells[index...].joined(separator: " | ")
    }

    static func splitSentences(_ paragraph: String) -> [String] {
        let range = NSRange(paragraph.startIndex..., in: paragraph)
        var sentences: [String] = []
        var last = paragraph.startIndex
        Patterns.sentenceBreak.enumerateMatches(in: paragraph, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: paragraph) else { return }
            sentences.append(String(paragraph[last..<r.lowerBound]))
            last = r.upperBound
        }
        sentences.append(String(paragraph[last...]))
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func wordTokens(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Mostly letters: natural language rather than code, URLs, or symbol soup.
    static func isProse(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { return false }
        let letters = visible.filter(\.isLetter).count
        return Double(letters) / Double(visible.count) >= 0.55 && !isCodeLike(text)
    }

    // MARK: - Layout analysis

    /// Splits text into columns at a vertical gutter that no line crosses
    /// (e.g. problem statement beside a code editor).
    static func splitColumns(_ lines: [OCRLine], width: CGFloat, depth: Int) -> [[OCRLine]] {
        guard depth > 0, lines.count >= 10, width > 0 else { return [lines] }
        let bins = 100
        var coverage = [Int](repeating: 0, count: bins)
        for line in lines {
            let a = max(0, min(bins - 1, Int(line.box.minX / width * CGFloat(bins))))
            let b = max(0, min(bins - 1, Int(line.box.maxX / width * CGFloat(bins))))
            for k in a...b { coverage[k] += 1 }
        }
        let tolerance = max(1, lines.count / 50)
        var bestBin: Int?
        for k in 20..<80 where coverage[k] <= tolerance {
            if bestBin == nil || abs(k - 50) < abs(bestBin! - 50) { bestBin = k }
        }
        guard let gutter = bestBin else { return [lines] }
        let x = CGFloat(gutter) / CGFloat(bins) * width
        let left = lines.filter { $0.box.midX < x }
        let right = lines.filter { $0.box.midX >= x }
        let minSide = max(4, lines.count / 5)
        guard left.count >= minSide, right.count >= minSide else { return [lines] }
        return splitColumns(left, width: width, depth: depth - 1) + splitColumns(right, width: width, depth: depth - 1)
    }

    /// Merges lines sharing a baseline into rows; wide gaps become " | " so tables stay readable.
    static func makeRows(_ lines: [OCRLine], medianHeight: CGFloat) -> [Row] {
        let sorted = lines.sorted { $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY }
        var groups: [[OCRLine]] = []
        for line in sorted {
            if let last = groups.last?.last,
               abs(last.box.midY - line.box.midY) < max(last.box.height, line.box.height) * 0.5 {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            var text = ordered[0].text
            for k in ordered.indices.dropFirst() {
                let gap = ordered[k].box.minX - ordered[k - 1].box.maxX
                text += (gap > medianHeight * 2.5 ? " | " : " ") + ordered[k].text
            }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            let confidence = ordered.map(\.confidence).reduce(0, +) / Float(ordered.count)
            return Row(text: text, box: box, confidence: confidence)
        }
    }

    static func makeBlocks(_ rows: [Row], medianHeight: CGFloat) -> [Block] {
        var blocks: [Block] = []
        for row in rows {
            if var last = blocks.last {
                let box = last.box
                let gap = row.box.minY - box.maxY
                let overlapsHorizontally = row.box.maxX > box.minX && row.box.minX < box.maxX
                // Scale with the text size so large, widely spaced lines still group.
                let lineHeight = max(medianHeight, row.box.height, last.rows.last?.box.height ?? 0)
                if gap < lineHeight * 1.4 && overlapsHorizontally {
                    last.rows.append(row)
                    blocks[blocks.count - 1] = last
                    continue
                }
            }
            blocks.append(Block(rows: [row]))
        }
        return blocks
    }

    /// Many short numeric labels (axis ticks, legends) suggest a chart or plot.
    static func looksLikeChart(_ lines: [OCRLine]) -> Bool {
        let numericLabels = lines.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return t.count <= 6 && t.contains(where: \.isNumber)
                && t.allSatisfy { $0.isNumber || ".,%$-−kKmM°".contains($0) }
        }
        return numericLabels.count >= 8
    }

    private static func context(around candidate: Candidate, rows: [Row], limit: Int) -> String {
        guard !rows.isEmpty else { return "" }
        let before = rows[max(0, candidate.startRowIndex - 12)..<max(0, min(candidate.startRowIndex, rows.count))]
        let afterStart = min(rows.count, candidate.endRowIndex + 1)
        let after = rows[afterStart..<min(rows.count, afterStart + 6)]
        var parts: [String] = []
        if !before.isEmpty { parts.append(before.map(\.text).joined(separator: "\n")) }
        if !after.isEmpty { parts.append(after.map(\.text).joined(separator: "\n")) }
        let joined = parts.joined(separator: "\n…\n")
        return joined.count > limit ? String(joined.suffix(limit)) : joined
    }

    // MARK: - Line classifiers

    static func isChrome(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("://") || lower.hasPrefix("www.") || lower.range(of: #"^[a-z0-9.-]+\.(com|org|net|io|edu|dev|app)(/\S*)?$"#, options: .regularExpression) != nil
    }

    static func isOption(_ text: String) -> Bool { matches(text, Patterns.option) }
    static func isHeader(_ text: String) -> Bool { isNamedHeader(text) || matches(text, Patterns.numberedItem) }
    static func isNamedHeader(_ text: String) -> Bool { matches(text, Patterns.namedHeader) }

    static func isCodeLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if matches(t, Patterns.codeDeclaration) || matches(t, Patterns.codeControl) { return true }
        let markers = ["{", "}", ";", "=>", "->", "==", "!=", "++", "&&", "||", "#include", "console.log", "print(", "()", "//", "/*", "#\"", "\"#", "::", "</", "/>", "SELECT ", " FROM "]
        if markers.contains(where: { t.contains($0) }) { return true }
        let symbols = t.filter { "{}[]<>\"'`#\\_|&$;".contains($0) }.count
        if t.count >= 8 && Double(symbols) / Double(t.count) > 0.12 { return true }
        return count(t, Patterns.identifier) >= 2
    }

    // MARK: - Regex helpers

    enum Patterns {
        static let interrogativeStart = regex(#"^\s*(\d+[.)]\s*)?(what|which|who|whom|whose|when|where|why|how|is|are|does|do|did|can|could|should|would|will|was|were|has|have)\b"#)
        /// Sentence-initial task verbs, optionally after "3." / "a)" / "Q2:".
        static let imperativeStart = regex(#"^\s*(?:(?:\d{1,3}|[a-h])[.)]\s+|q\d*[.:)]\s*|(?:problem|question|task|exercise)\s*\d*\s*[.:]\s*)?(complete the|solve|find|calculate|compute|evaluate|determine|simplify|factor|factori[sz]e|expand|differentiate|integrate|prove|show that|implement|write|derive|estimate|convert|rewrite|explain|describe|compare|contrast|define|justify|discuss|summari[sz]e|analy[sz]e|translate|given|you are given|you're given|design|tell|introduce|walk|give)\b"#)
        static let academicStart = regex(#"^\s*(?:(?:\d{1,3}|[a-h])[.)]\s+)?(explain|describe|compare|contrast|define|justify|discuss|summari[sz]e|analy[sz]e|prove|derive|evaluate)\b"#)
        static let task = regex(#"\bwrite (a|an|the)?\s*(sql|query|function|program|method|class|script|algorithm|code|proof|essay|paragraph|equation|regex|regular expression|solution)|\bcomplete the \w+ function|\b(solve|find|calculate|compute|evaluate|determine|simplify)\b.*(\d|=|\bx\b|value|angle|area|sum|probability|derivative|integral|equation|length|perimeter|volume|limit|roots?|average|mean)|\bgiven (an?|the|two|some) (array|string|list|integer|tree|graph|number|matrix|binary|linked|table|set|sequence|function)|\bimplement (a|an|the)\b"#)
        static let choiceInstruction = regex(#"^\s*(?:(select|choose|pick|identify|mark|circle|rank) (the |all |one |an? )?(correct|best|right|true|false|most|least|following|answer|option|statement|responses?)|true or false\b)"#)
        static let likert = regex(#"strongly disagree[\s\S]*strongly agree|strongly agree[\s\S]*strongly disagree|\bdisagree\b[\s\S]*\bneutral\b[\s\S]*\bagree\b"#)
        static let likertAnchor = regex(#"^\s*(strongly (dis)?agree|(dis)?agree|neutral|neither agree nor disagree|somewhat (dis)?agree)\s*$"#)
        static let mathVerbStart = regex(#"^\s*(?:(?:\d{1,3}|[a-h])[.)]\s+)?(evaluate|simplify|solve|compute|calculate|find|factor|expand|differentiate|integrate)\b"#)
        static let equalsQuestion = regex(#"=\s*\?"#)
        static let interview = regex(#"\b(tell (me|us) (a (little|bit) )?(about|more about) (yourself|a time|an? (time|situation|experience|project|challenge|mistake|failure|conflict|accomplishment|achievement))|introduce yourself|walk (me|us) through (your|a|how)|describe (a|an) (time|situation|experience|project|challenge|moment|instance|occasion)|give (me |us )?an example of|describe how you (would|have|did|handle|approach|manage)|what did you learn from|share an? (experience|example|time|story)|why do you want (to|this)|why should we hire you|why (are you|would you be) (interested|a good fit)|what are your (greatest )?(strengths|weaknesses)|what is your (greatest )?(strength|weakness)|where do you see yourself|what motivates you|how do you (handle|deal with|prioriti[sz]e|manage)|how would you (handle|deal with|approach)|what interests you about|why are you leaving|what (are|is) your (career goals|salary expectations|biggest (achievement|accomplishment))|what makes you (a good fit|unique|qualified)|have you ever (had to|faced|dealt with|disagreed)|tell (me|us) about your (background|experience|biggest))\b"#)
        static let whichOfTheFollowing = regex(#"which (one )?of the (following|options|choices|statements)"#)
        static let namedHeader = regex(#"^\s*(question|q|problem|exercise|task|quiz|practice|example)\s*#?\s*\d+\b"#)
        static let numberedItem = regex(#"^\s*\d{1,3}[.)]\s+\S"#)
        /// Answer choices: "A)", "(b)", "c.", "(1)", "2)", or radio/checkbox glyphs. Plain "•" bullets are lists, not choices.
        static let option = regex(#"^\s*(?:[•○◯●◉o]\s+)?(\(?[A-Ha-h][).:]|\([A-Ha-h]\)|\(?[1-8]\)|[○◯●◉☐□■◻⚪])\s*\S"#)
        static let sqlStrong = regex(#"\b(sql|query|queries|select\b[\s\S]{1,200}\bfrom|group by|order by|inner join|left join|join|create table|primary key|foreign key)\b"#)
        static let sqlWeak = regex(#"\b(table|tables|column|columns|rows|database|schema|where|having|count\(|sum\(|avg\()"#)
        static let programming = regex(#"\b(function|algorithm|array|string|integer|linked list|binary tree|hash ?map|input|output|constraints|example \d|time complexity|space complexity|python|java|javascript|typescript|c\+\+|swift|rust|golang|code|program|implement|recursion|recursive|nums|stack|queue|o\(n)"#)
        static let mathSymbols = regex(#"[=+−×÷^√∫∑π≤≥≠∞²³]|\d\s*[*/x-]\s*\d|\b\d+[a-z]\b|\b(sin|cos|tan|log|ln|lim|dx|dy)\b|f\(x\)|\d+/\d+"#)
        static let mathWords = regex(#"\b(equation|solve for|derivative|integral|probability|percent|percentage|area|perimeter|volume|angle|triangle|circle|radius|diameter|slope|matrix|vector|polynomial|quadratic|expression|sum|product|mean|median|average|ratio|fraction|digits?|prime|factorial|hypotenuse|circumference|remainder|divisible)\b"#)
        static let logic = regex(#"\b(if all|must be true|cannot be true|could be true|puzzle|riddle|next number|next term|logically|conclusion|premise|syllogism|truth table|implies)\b"#)
        static let visual = regex(#"\b(graph|chart|plot|diagram|figure|fig\.|image|picture|photo|illustration|histogram|scatter|flowchart|flow chart|circuit|legend|axis|axes|screenshot|shaded|shown (below|above|here|in)|see (the )?(figure|graph|image))\b"#)
        static let geometry = regex(#"\b(triangle|angle|circle|polygon|parallel|perpendicular|rectangle|quadrilateral|hypotenuse|shaded|arc|chord|tangent line)\b|[∠△]"#)
        static let sentenceBreak = regex(#"(?<=[.?!])\s+"#)
        // Code detection is case-sensitive: keywords are lowercase, "Class 10" is prose.
        static let codeDeclaration = regex(#"^(let|var|const|func|def|class|struct|enum|import|static|private|public|protected|fileprivate|override|package|#include|#import)\s+[\w(@]"#, caseSensitive: true)
        static let codeControl = regex(#"^(if|for|while|return|switch|guard|elif|else|case)\b.*[({:;]$"#, caseSensitive: true)
        static let identifier = regex(#"\b[a-z]+[A-Z][A-Za-z0-9]*\b|\b[a-z0-9]+_[a-z0-9_]+\b|\b\w+\.\w+\("#, caseSensitive: true)

        private static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure is a programmer error.
            try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines])
        }
    }

    static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func count(_ text: String, _ regex: NSRegularExpression) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 12 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
