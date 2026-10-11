import CoreGraphics
import Foundation
import Testing
@testable import ScreenPilot

@Suite("Answer formatting")
struct FormattingTests {
    @Test func parsesHeadingsListsAndParagraphs() {
        let blocks = MarkdownText.parse("""
        ### Situation
        At Acme I had two weeks to learn MLflow.

        **What I did**
        - Read the docs
        1. Built a prototype
        """)
        #expect(blocks == [
            .heading(level: 3, text: "Situation"),
            .paragraph("At Acme I had two weeks to learn MLflow."),
            .heading(level: 3, text: "What I did"),
            .bullet("Read the docs"),
            .numbered("1.", "Built a prototype"),
        ])
    }

    @Test func keepsCodeBlocksIntact() {
        let blocks = MarkdownText.parse("```sql\nSELECT 1;\n# not a heading\n```")
        #expect(blocks == [.code("SELECT 1;\n# not a heading", language: "sql")])
    }

    @Test func headingsInsideAnswerDontEndIt() {
        let parsed = AnswerParser.parse("""
        **Answer:**
        ### Situation
        I joined Acme.
        ### Result
        Shipped the pipeline.
        **Explanation:**
        - Uses STAR
        """)
        #expect(parsed.answer.contains("### Result"))
        #expect(parsed.explanation == "- Uses STAR")
    }

    @Test func spokenWordTargets() {
        #expect(PromptBuilder.spokenWordTarget("in 2 minutes, tell me about a time you had to learn something quickly.") == 260)
        #expect(PromptBuilder.spokenWordTarget("Introduce yourself in 30 seconds") == 65)
        #expect(PromptBuilder.spokenWordTarget("Take two minutes to describe a project") == 260)
        #expect(PromptBuilder.spokenWordTarget("Tell me about yourself") == nil)
    }

    @Test func solveNowPromptAsksModelToFindTheQuestion() {
        let q = DetectedQuestion(text: "Google\nsome screen text", contextText: "", kind: .general, mode: .vision, score: 0,
                                 isAmbiguous: false, region: .zero, options: [], fingerprint: QuestionFingerprintService.make(from: "x"),
                                 findInScreen: true)
        let prompt = PromptBuilder.userPrompt(for: q, attachingImage: true)
        #expect(prompt.contains("Find the main question"))
        #expect(prompt.contains("some screen text"))
    }

    @Test func pictureOnlyQuestionPromptAndIdentity() throws {
        let sig = try #require(ScreenChangeDetector.signature(for: shadedGrid()))
        let q = DetectedQuestion.visual(ocrText: "", signature: sig)
        #expect(q.mode == .vision)
        #expect(q.excerpt == "Image on screen (no text)")
        #expect(PromptBuilder.userPrompt(for: q, attachingImage: true).contains("no readable text"))
        #expect(!PromptBuilder.userPrompt(for: q, attachingImage: true).contains("NO_QUESTION"))   // manual: always answer
        var auto = q
        auto.needsConfirmation = true
        #expect(PromptBuilder.userPrompt(for: auto, attachingImage: true).contains("NO_QUESTION"))
        // Same picture → same identity; a different picture → different question.
        let again = DetectedQuestion.visual(ocrText: "", signature: sig)
        #expect(QuestionFingerprintService.isSameQuestion(q.fingerprint, again.fingerprint))
        let otherSignature = ScreenChangeDetector.signature(for: makeImage(rects: textLikeRects(rows: 12)))
        let other = DetectedQuestion.visual(ocrText: "", signature: otherSignature)
        #expect(!QuestionFingerprintService.isSameQuestion(q.fingerprint, other.fingerprint))
    }

    @Test func blankFramesAreNotCheckedForPictures() throws {
        #expect(!AIOrchestrator.hasVisualContent(try #require(ScreenChangeDetector.signature(for: makeImage()))))
        #expect(AIOrchestrator.hasVisualContent(try #require(ScreenChangeDetector.signature(for: shadedGrid()))))
    }

    @Test func chatPromptCarriesContext() throws {
        let q = try #require(QuestionDetector().detect(page(["Exercise 1", "Solve for x: 2x + 3 = 11"])).question)
        let prompt = PromptBuilder.chatPrompt(message: "explain step 2", question: q, answer: "**Answer:** x = 4",
                                              history: [.init(fromUser: true, text: "why?"), .init(fromUser: false, text: "Because…")],
                                              profile: "- Studies CS", attachingScreen: false)
        #expect(prompt.contains("Solve for x"))
        #expect(prompt.contains("x = 4"))
        #expect(prompt.contains("Seer: Because…"))
        #expect(prompt.contains("Studies CS"))
        #expect(prompt.hasSuffix("User: explain step 2"))
        let bare = PromptBuilder.chatPrompt(message: "hi", question: nil, answer: "", history: [], profile: nil, attachingScreen: true)
        #expect(bare.contains("screenshot"))
        #expect(!bare.contains("Question currently on screen"))
    }
}
