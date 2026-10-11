import Foundation

nonisolated enum PromptBuilder {
    static func systemPrompt(detail: DetailLevel, kind: QuestionKind) -> String {
        kind == .interview ? interviewSystemPrompt(detail: detail) : solverSystemPrompt(detail: detail)
    }

    static func interviewSystemPrompt(detail: DetailLevel) -> String {
        let length = switch detail {
        case .brief: "60–100 words"
        case .standard: "100–170 words"
        case .detailed: "170–250 words"
        }
        return """
        You help the user answer an interview question shown on their screen. Write the complete answer they would actually say, in the first person, as if you were them. Never explain how to answer, list steps, or give a fill-in template; write the real answer.

        Respond in exactly this format:
        **Answer:**
        <a natural, spoken-style answer in the first person, \(length) unless a target length is given, organized under 2–4 short "###" headings (for example ### Situation, ### What I did, ### Result, or ### Who I am, ### What I've done, ### Why this role), with the words to say under each>
        **Explanation:**
        <2–4 short bullet points: what the interviewer is looking for and how to make the answer stronger>

        Rules:
        - Behavioral questions ("Tell me about a time…", "Describe a situation…"): follow the STAR structure (Situation, Task, Action, Result) and pick the single most relevant real story from "About the user" when provided.
        - "Tell me about yourself" / "Introduce yourself": present → past → why this role, in a confident, conversational tone.
        - If an "About the user" section is provided, build the answer from those real facts (roles, projects, skills, results) and never contradict them.
        - Never invent personal facts such as employers, schools, names, dates, or numbers that aren't in "About the user". Where a needed detail is missing, use a short placeholder in square brackets, e.g. [company], [project], [result].
        - Use only the numbers, outcomes, and claims that appear in "About the user", exactly as stated (e.g. rows stay rows, not patients). Don't add metrics, percentages, accuracy gains, awards, or impact statements that aren't there; if a result isn't stated, describe it qualitatively without numbers.
        - Sound genuine, not scripted. No preamble.
        """
    }

    static func solverSystemPrompt(detail: DetailLevel) -> String {
        let explanationGuide = switch detail {
        case .brief: "1–3 short sentences or key steps"
        case .standard: "the key steps or reasoning, concisely"
        case .detailed: "a clear step-by-step explanation"
        }
        return """
        You are Seer, a careful assistant that solves questions visible on the user's screen.
        Question text was extracted with OCR and may contain recognition errors; fix obvious OCR mistakes silently.

        Respond in exactly this format:
        **Answer:** <the direct final answer>
        **Confidence:** <high | medium | low>
        **Explanation:**
        <\(explanationGuide)>

        Rules:
        - Actually solve it. Give the finished result itself: the computed value, the chosen option, working code, or the complete written response. Never restate the question, describe how one would answer it, or give a template.
        - Solve only the target question.
        - Multiple choice: the answer must name the option letter/number and its text, e.g. "(B) 42".
        - Code and SQL: put a complete, working solution in a fenced code block with a language tag inside the Answer section.
        - Math: give the final value in the Answer; show key calculations in the Explanation.
        - If information is missing, cut off, or unreadable, say so, state your assumptions, and lower your confidence. Never invent labels, numbers, or options.
        - Formatting: a short answer stays on one line. Longer answers and explanations use short Markdown headings ("### Heading") with concise text or bullets under each.
        - Prefer correctness over confidence. Be concise; no preamble.
        """
    }

    static func userPrompt(for question: DetectedQuestion, attachingImage: Bool, profile: String? = nil) -> String {
        if question.findInScreen && question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            There is no readable text on the user's screen, so the question is in the attached screenshot itself \
            (for example a diagram, shaded grid, chart, geometry figure, or puzzle). Work out what it is asking. \
            If no question is written, answer the most likely one (e.g. "What fraction is shaded?") and name it in \
            one short line first. Before answering, explicitly count what matters (rows, columns, shaded or marked \
            items, labels) and state the counts; don't guess numbers you can't see.\(question.needsConfirmation ? "\nIf the image contains no question, exercise, or problem to solve (an ordinary photo, UI, video, art), reply with exactly \(noQuestionToken) and nothing else." : "")
            """
        }
        if question.findInScreen {
            return """
            The user pressed "Solve now". Find the main question, problem, or prompt on their screen and answer it. \
            If there are several, answer the most prominent one and name it in one short line first. \
            \(attachingImage ? "The screenshot is attached; this is its OCR text:" : "Screen text (OCR):")
            \"\"\"
            \(question.text)
            \"\"\"
            """
        }
        var parts: [String] = []
        if question.kind == .interview, let words = spokenWordTarget(question.text) {
            parts.append("Target length: about \(words) words, since the question asks for a specific speaking time (people speak about 130 words per minute).")
        }
        if question.kind == .interview, let profile {
            parts.append("""
            About the user:
            \"\"\"
            \(profile.prefix(6000))
            \"\"\"
            """)
        }
        parts.append("Detected question type: \(question.kind.displayName)")
        if attachingImage {
            parts.append("""
            The attached screenshot shows the user's screen. Use it as the primary source for figures, charts, tables, diagrams, and notation. The target question (OCR text, may contain errors) is:
            \"\"\"
            \(question.text)
            \"\"\"
            """)
        } else {
            parts.append("""
            Target question (OCR text):
            \"\"\"
            \(question.text)
            \"\"\"
            """)
        }
        if question.options.count >= 2 {
            parts.append("Answer options detected:\n" + question.options.map { "- \($0)" }.joined(separator: "\n"))
        }
        if includesContext(question) {
            parts.insert("""
            Reference material shown near the question (use only if the question needs it):
            \"\"\"
            \(question.contextText.suffix(1000))
            \"\"\"
            """, at: 0)
        }
        // Small models weigh the end of the prompt most, so restate the target last.
        let firstLine = question.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? question.text
        parts.append("Answer only the target question above (\"\(firstLine.prefix(160))\"). Ignore any other text on the screen.")
        return parts.joined(separator: "\n\n")
    }

    private static let durationPattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}|one|two|three|four|five)\s*(-\s*)?(minutes?|mins?|seconds?|secs?)\b"#, options: [.caseInsensitive])

    /// "In 2 minutes, tell me…" → ~260 words. Nil when no speaking time is mentioned.
    static func spokenWordTarget(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = durationPattern.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 3), in: text) else { return nil }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
        let token = text[numberRange].lowercased()
        guard let amount = Int(token) ?? words[token] else { return nil }
        let minutes = text[unitRange].lowercased().hasPrefix("s") ? Double(amount) / 60 : Double(amount)
        return min(650, max(40, Int((minutes * 130).rounded())))
    }

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"\b(above|below|following|table|tables|schema|passage|excerpt|given|figure|graph|chart|code|snippet|dataset|data)\b"#,
        options: [.caseInsensitive])

    /// Surrounding text distracts small models, so include it only when the question
    /// points at other material (a table, a passage, "the following code"…).
    static func includesContext(_ question: DetectedQuestion) -> Bool {
        guard !question.contextText.isEmpty, question.kind != .interview else { return false }
        if question.kind == .sql || question.kind == .programming { return true }
        let text = question.text
        return referencePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static let classificationSystemPrompt = """
    You check whether text captured from a screen is a question or task that the reader is being asked to answer right now: \
    quiz, exam or homework questions; math or logic problems; coding or SQL challenges; multiple-choice items; or interview \
    questions, including prompts such as "Tell me about yourself" or "Describe a time when…".
    Answer NO for: article or blog headings, rhetorical questions inside prose, FAQ entries that are already answered, \
    UI labels, buttons and menus (e.g. "Forgot password?", "Need help?"), search boxes, code and code comments, chat \
    messages, marketing copy, and anything else that is not posed to the reader as a question to answer.
    Reply with exactly one word: YES or NO.
    """

    /// Few-shot examples make small models far more reliable at this yes/no call.
    static func classificationMessages(for question: DetectedQuestion) -> [OllamaMessage] {
        let examples: [(String, String)] = [
            ("Why is everyone suddenly talking about electric cars?", "NO"),
            ("Tell me about a time you disagreed with a teammate. How did you resolve it?", "YES"),
            ("Forgot your password? Reset it here.", "NO"),
            ("What is the time complexity of inserting into a binary heap?", "YES"),
            ("What is Swift? Swift is a general-purpose programming language developed by Apple…", "NO"),
        ]
        var messages = [OllamaMessage(role: "system", content: classificationSystemPrompt)]
        for (text, label) in examples {
            messages.append(OllamaMessage(role: "user", content: "Screen text:\n\"\"\"\n\(text)\n\"\"\""))
            messages.append(OllamaMessage(role: "assistant", content: label))
        }
        messages.append(OllamaMessage(role: "user", content: "Screen text:\n\"\"\"\n\(question.text.prefix(1500))\n\"\"\""))
        return messages
    }

    static let noQuestionToken = "NO_QUESTION"

    static let chatSystemPrompt = """
    You are Seer, an assistant in a small overlay on the user's Mac. The user is chatting with you, usually \
    about the question currently on their screen and the answer you gave. Do what they ask directly: rewrite, shorten, \
    expand, explain a step, check work, or answer a new question. Reply concisely in Markdown; use "###" headings for \
    longer replies and fenced code blocks with a language tag for code. If a screenshot is attached, use it. When \
    writing interview answers, speak as the user in the first person and use only facts from "About the user", with \
    [placeholders] for anything missing. No preamble.
    """

    struct ChatTurn: Sendable {
        var fromUser: Bool
        var text: String
    }

    /// Everything the chat model needs in one prompt: profile, the on-screen question,
    /// the current answer, the conversation so far, and the new message.
    static func chatPrompt(message: String, question: DetectedQuestion?, answer: String, history: [ChatTurn],
                           profile: String?, attachingScreen: Bool) -> String {
        var parts: [String] = []
        if let profile, !profile.isEmpty {
            parts.append("About the user:\n\"\"\"\n\(profile.prefix(6000))\n\"\"\"")
        }
        if let question {
            let text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("Question currently on screen (\(question.kind.displayName)):\n\"\"\"\n\(text.isEmpty ? "(an image with no text)" : String(text.prefix(2500)))\n\"\"\"")
        }
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAnswer.isEmpty {
            parts.append("Your current answer to it:\n\"\"\"\n\(trimmedAnswer.prefix(4000))\n\"\"\"")
        }
        if !history.isEmpty {
            let lines = history.suffix(12).map { "\($0.fromUser ? "User" : "Seer"): \($0.text.prefix(2000))" }
            parts.append("Conversation so far:\n" + lines.joined(separator: "\n\n"))
        }
        if attachingScreen { parts.append("A fresh screenshot of the user's screen is attached.") }
        parts.append("User: \(message)")
        return parts.joined(separator: "\n\n")
    }

    /// The few-shot classification examples flattened into one prompt (for Gemini).
    static func classificationTranscript(for question: DetectedQuestion) -> String {
        classificationMessages(for: question).dropFirst().map { message in
            message.role == "assistant" ? "Answer: \(message.content)\n" : message.content
        }.joined(separator: "\n") + "\nAnswer:"
    }

    /// Gemini thinking level: low keeps answers fast; heavier reasoning only when asked.
    static func geminiThinkingLevel(kind: QuestionKind, preference: SpeedPreference) -> String {
        switch preference {
        case .faster: "low"
        case .balanced: [.math, .logic, .programming, .sql].contains(kind) ? "medium" : "low"
        case .thorough: "high"
        }
    }

    /// Whether to enable model "thinking" for this question.
    static func shouldThink(kind: QuestionKind, preference: SpeedPreference) -> Bool {
        switch preference {
        case .faster: false
        case .thorough: true
        case .balanced: [.math, .logic, .programming, .sql].contains(kind)
        }
    }
}
