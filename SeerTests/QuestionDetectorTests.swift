import CoreGraphics
import Foundation
import Testing
@testable import Seer

@Suite("Question detection decisions")
struct QuestionDetectorTests {
    let detector = QuestionDetector()

    @Test func detectsMultipleChoice() throws {
        let ocr = page([
            "Question 4 of 10",
            "Which of the following planets is closest to the Sun?",
            "",
            "A) Venus",
            "B) Mercury",
            "C) Earth",
            "D) Mars",
        ])
        let q = try #require(detector.detect(ocr).question)
        #expect(q.kind == .multipleChoice)
        #expect(!q.isAmbiguous)
        #expect(q.options.count == 4)
        #expect(q.text.contains("closest to the Sun"))
        #expect(q.mode == .text)
    }

    @Test func detectsMathWithoutQuestionMark() throws {
        let ocr = page(["Exercise 2", "Solve for x: 3x² − 5x + 2 = 0"])
        let q = try #require(detector.detect(ocr).question)
        #expect(q.kind == .math)
        #expect(!q.isAmbiguous)
    }

    @Test func detectsSQL() throws {
        let ocr = page([
            "Table: Employee",
            "id | name | salary | managerId",
            "",
            "Write a SQL query to find the employees who earn more than their managers.",
            "Return the result table in any order.",
        ])
        let q = try #require(detector.detect(ocr).question)
        #expect(q.kind == .sql)
        #expect(!q.isAmbiguous)
    }

    @Test func detectsProgrammingProblem() throws {
        let ocr = page([
            "1. Two Sum",
            "Given an array of integers nums and an integer target, return indices of the two numbers such that they add up to target.",
            "",
            "Example 1:",
            "Input: nums = [2,7,11,15], target = 9",
            "Output: [0,1]",
            "Constraints:",
        ])
        let q = try #require(detector.detect(ocr).question)
        #expect(q.kind == .programming)
        #expect(!q.isAmbiguous)
    }

    @Test func chartQuestionUsesVision() throws {
        var ocr = page(["Based on the bar chart shown below, which year had the highest revenue?"])
        // Axis tick labels scattered over the chart area.
        let ticks = ["0", "10", "20", "30", "40", "50", "2019", "2020", "2021", "2022"]
        for (i, tick) in ticks.enumerated() {
            ocr.lines.append(OCRLine(text: tick, box: CGRect(x: 0.15 + CGFloat(i) * 0.05, y: 0.6 + CGFloat(i % 3) * 0.08, width: 0.02, height: 0.015), confidence: 0.9))
        }
        let q = try #require(detector.detect(ocr).question)
        #expect(q.mode == .vision)
    }

    @Test func geometryQuestionUsesVision() throws {
        let ocr = page(["In the triangle shown, angle A is 40° and angle B is 65°. Find angle C."])
        let q = try #require(detector.detect(ocr).question)
        #expect(q.mode == .vision)
    }

    @Test func plainProseIsNotAQuestion() {
        let ocr = page([
            "The history of the Roman Empire spans more than a thousand years.",
            "It began with the founding of Rome and ended with the fall of Constantinople.",
            "Historians continue to debate the causes of its decline.",
        ])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func navigationIsNotAQuestion() {
        let ocr = page(["Home", "Products", "Pricing", "Blog", "About", "Contact", "Sign in"])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func rhetoricalHeadingIsAmbiguous() {
        let ocr = page(["Why is everyone talking about electric cars?"])
        let outcome = detector.detect(ocr)
        #expect(outcome.question?.isAmbiguous ?? true)
    }

    @Test func urlWithQueryStringIsIgnored() {
        let ocr = page(["https://example.com/search?q=what+is+swift", "example.com/watch?v=123"])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func emptyOCRReturnsNone() {
        #expect(detector.detect(.empty) == .none(reason: "No readable text"))
    }

    @Test func picksTheQuestionNotTheSidebar() throws {
        // Problem on the left, unrelated code editor content on the right.
        var lines = page([
            "Problem 3",
            "Find the sum of all even numbers between 1 and 100.",
            "Show your work.",
        ], x: 0.05, width: 0.35).lines
        let code = ["func main() {", "    let x = 10", "    print(x)", "}", "// TODO", "struct App {}", "var y = 2;", "return y;", "}", "{ }", "let z = 3;", "print(z);"]
        for (i, text) in code.enumerated() {
            lines.append(OCRLine(text: text, box: CGRect(x: 0.6, y: 0.1 + CGFloat(i) * 0.04, width: 0.2, height: 0.02), confidence: 0.95))
        }
        let q = try #require(detector.detect(OCRResult(lines: lines, imageSize: CGSize(width: 1600, height: 1000))).question)
        #expect(q.text.contains("sum of all even numbers"))
        #expect(!q.text.contains("print(x)"))
    }

    // MARK: Interview prompts

    @Test(arguments: [
        "Tell me about yourself.",
        "Please introduce yourself",
        "Tell us about a time you had to meet a tight deadline.",
        "Describe a situation where you disagreed with your manager",
        "Why should we hire you?",
        "What is your greatest weakness?",
        "Walk me through your resume",
        "Give an example of a time you showed leadership.",
    ])
    func detectsInterviewPrompts(_ prompt: String) throws {
        let q = try #require(detector.detect(page(["Question 2 of 5", "", prompt, "", "Record your answer"])).question, "\(prompt)")
        #expect(q.kind == .interview, "\(prompt)")
        #expect(!q.isAmbiguous, "\(prompt)")
        #expect(q.mode == .text)
    }

    /// Reproduces a Google search box with large text wrapping mid-phrase.
    @Test func interviewPromptWrappedAcrossShortLines() throws {
        var lines: [OCRLine] = []
        lines.append(OCRLine(text: "Google", box: CGRect(x: 0.38, y: 0.12, width: 0.23, height: 0.07), confidence: 0.9))
        let rows = ["in 2 minutes, tell me about a", "time you had to learn", "something quickly."]
        for (i, text) in rows.enumerated() {
            lines.append(OCRLine(text: text, box: CGRect(x: 0.2, y: 0.36 + CGFloat(i) * 0.085, width: CGFloat(text.count) * 0.018, height: 0.055), confidence: 0.95))
        }
        lines.append(OCRLine(text: "AI Overview", box: CGRect(x: 0.16, y: 0.85, width: 0.2, height: 0.04), confidence: 0.9))
        let q = try #require(detector.detect(OCRResult(lines: lines, imageSize: CGSize(width: 3164, height: 2070))).question)
        #expect(q.kind == .interview)
        #expect(!q.isAmbiguous)
        #expect(q.text.contains("something quickly"))
    }

    /// Google results page: search text beside the logo, tabs, then an AI Overview with bullets.
    @Test func googleSearchWithAIOverviewIsInterviewNotMultipleChoice() throws {
        let ocr = page([
            "Google | tell me about a time you had to make a decision with incomplete data",
            "AI Mode All Short videos Forums Videos Shopping Images More • Tools",
            "AI Overview",
            "To handle a decision with incomplete data effectively, use the STAR method:",
            "• Situation: Briefly describe the high-stakes environment or tight deadline.",
            "• Task: Explain the decision you needed to make.",
            "• Action: Walk through how you gathered what data you could.",
            "• Result: Share the outcome and what you learned.",
        ], width: 0.9)
        let q = try #require(detector.detect(ocr).question)
        #expect(q.kind == .interview)
        #expect(q.options.isEmpty)
        #expect(!q.text.contains("AI Overview"))
        #expect(!q.text.contains("Situation:"))
    }

    @Test func bulletsAreNotAnswerOptions() {
        #expect(!QuestionDetector.isOption("• Situation: describe the context"))
        #expect(QuestionDetector.isOption("A) Venus"))
        #expect(QuestionDetector.isOption("(b) Mercury"))
        #expect(QuestionDetector.isOption("○ Paris"))
    }

    @Test func forcedDetectionAcceptsWeakCandidates() {
        let ocr = page(["What is the capital of Australia?"])
        #expect(detector.detect(ocr, forced: true).question != nil)
    }

    @Test func labelStacksStayUnjoined() {
        #expect(QuestionDetector.joinWrappedRows(["Sign in", "Email", "Forgot password?"]).count == 3)
        #expect(QuestionDetector.joinWrappedRows(["in 2 minutes, tell me about a", "time you had to learn"]).count == 1)
    }

    // MARK: False positives

    @Test func uiLabelsAreNotQuestions() {
        let ocr = page(["Sign in", "Email", "Password", "Forgot password?", "Need help?", "Find in page", "Select a file", "Create account"])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func codeInAnEditorIsNotAQuestion() {
        let ocr = page([
            "static let whichOfTheFollowing = regex(#\"which (one )?of the (following|options)\"#)",
            "let prompt = \"Which of the following is true?\"",
            "// TODO: find the bug in the parser?",
            "func solve(_ x: Int) -> Int {",
            "    return x * 2",
            "}",
            "if question.isAmbiguous {",
            "guard let answer = parsedAnswer else { return }",
        ])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func answeredFAQIsNotAQuestion() {
        let ocr = page([
            "What is Swift and who maintains it?",
            "",
            "Swift is a general-purpose, multi-paradigm programming language developed by Apple and the open-source community.",
            "It was first released in 2014 and is used to build apps for iOS, macOS, watchOS and tvOS as well as server software.",
            "The language is maintained by the Swift project on GitHub with contributions from many companies.",
        ])
        let outcome = detector.detect(ocr)
        #expect(outcome.question == nil || outcome.question?.isAmbiguous == true)
    }

    @Test func rhetoricalQuestionInArticleIsIgnored() {
        let ocr = page([
            "Electric vehicles have grown rapidly over the past decade as battery prices have fallen sharply.",
            "But what does this mean for drivers who live in apartments without a garage or a driveway?",
            "Cities are responding by installing curbside chargers and requiring new buildings to include them.",
            "Analysts expect the number of public chargers to triple by the end of the decade in most markets.",
            "Automakers, meanwhile, are investing billions in new factories and battery supply chains worldwide.",
        ])
        #expect(detector.detect(ocr).question == nil)
    }

    @Test func plainTriviaQuestionIsSentForConfirmation() throws {
        let q = try #require(detector.detect(page(["What is the capital of Australia?"])).question)
        #expect(q.isAmbiguous)
    }

    @Test func tableRowsAreJoined() {
        let lines = [
            OCRLine(text: "id", box: CGRect(x: 0.1, y: 0.1, width: 0.03, height: 0.02), confidence: 1),
            OCRLine(text: "name", box: CGRect(x: 0.3, y: 0.1, width: 0.05, height: 0.02), confidence: 1),
            OCRLine(text: "salary", box: CGRect(x: 0.5, y: 0.101, width: 0.06, height: 0.02), confidence: 1),
        ].map { line -> OCRLine in
            var l = line
            l.box = CGRect(x: l.box.minX * 1000, y: l.box.minY * 1000, width: l.box.width * 1000, height: l.box.height * 1000)
            return l
        }
        let rows = QuestionDetector.makeRows(lines, medianHeight: 20)
        #expect(rows.count == 1)
        #expect(rows[0].text == "id | name | salary")
    }

    @Test func sameQuestionAfterScrollHasMatchingFingerprint() throws {
        let lines = [
            "Which of the following data structures uses LIFO ordering?",
            "",
            "A) Queue",
            "B) Stack",
            "C) Heap",
            "D) Graph",
        ]
        let before = try #require(detector.detect(page(lines, startY: 0.5)).question)
        let after = try #require(detector.detect(page(lines, startY: 0.2)).question)
        #expect(QuestionFingerprintService.isSameQuestion(before.fingerprint, after.fingerprint))
    }

    @Test func garbledDivisionIsMathAndShowsTheScreenshot() throws {
        // Vision read "8 ÷ 2(2 + 2) = ?" as full-width "8-2（2+2）=？" at 0.3 confidence.
        let text = OCRService.asciiFromFullWidth("8-2（2+2）=？")
        #expect(text == "8-2(2+2)=?")
        let ocr = OCRResult(lines: [OCRLine(text: text, box: CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.06), confidence: 0.3)],
                            imageSize: CGSize(width: 1600, height: 1000))
        let q = try #require(QuestionDetector().detect(ocr).question)
        #expect(q.kind == .math)
        #expect(q.mode == .vision)
    }

    @Test func leetCodeStatementBeatsConstraints() throws {
        func column(_ lines: [(String, CGFloat)], x: CGFloat) -> [OCRLine] {
            lines.map { OCRLine(text: $0.0, box: CGRect(x: x, y: $0.1, width: 0.42, height: 0.018), confidence: 0.95) }
        }
        let left = column([("1. Two Sum", 0.165),
            ("You are given an array of integers nums and an integer target, return indices of the two", 0.255),
            ("numbers such that they add up to target.", 0.278),
            ("You may assume that each input would have exactly one solution, and you may not use the", 0.318),
            ("same element twice.", 0.341),
            ("Example 1:", 0.46), ("Input: nums = [2,7,11,15], target = 9", 0.50), ("Output: [0,1]", 0.522),
            ("Constraints:", 0.825), ("2 <= nums.length <= 104", 0.865)], x: 0.06)
        let right = column([("1 class Solution:", 0.18), ("2 def twoSum(self, nums: list[int], target: int) -> list[int]:", 0.20)], x: 0.52)
        let q = try #require(QuestionDetector().detect(OCRResult(lines: left + right, imageSize: CGSize(width: 2380, height: 1540))).question)
        #expect(q.kind == .programming)
        #expect(q.text.contains("return indices of the two"))
        #expect(!q.text.contains("Constraints"))
    }
}
