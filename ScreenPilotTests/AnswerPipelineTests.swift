import Foundation
import Testing
@testable import ScreenPilot

@Suite("Answer parsing")
struct AnswerParserTests {
    @Test func parsesStructuredResponse() {
        let raw = """
        **Answer:** (B) Mercury
        **Confidence:** high
        **Explanation:**
        Mercury orbits closest to the Sun at about 0.39 AU.
        """
        let parsed = AnswerParser.parse(raw)
        #expect(parsed.answer == "(B) Mercury")
        #expect(parsed.confidence == .high)
        #expect(parsed.explanation.hasPrefix("Mercury orbits"))
    }

    @Test func keepsCodeBlocksInAnswer() {
        let raw = """
        **Answer:**
        ```sql
        SELECT e.name FROM Employee e JOIN Employee m ON e.managerId = m.id WHERE e.salary > m.salary;
        ```
        **Confidence:** medium
        **Explanation:** Self-join on managerId.
        """
        let parsed = AnswerParser.parse(raw)
        #expect(parsed.answer.contains("```sql"))
        #expect(parsed.answer.contains("JOIN Employee m"))
        #expect(parsed.confidence == .medium)
        #expect(parsed.explanation == "Self-join on managerId.")
    }

    @Test func handlesPartialStreamingText() {
        let parsed = AnswerParser.parse("**Answer:** x = 2 or x =")
        #expect(parsed.answer == "x = 2 or x =")
        #expect(parsed.confidence == nil)
        #expect(parsed.explanation.isEmpty)
    }

    @Test func stripsThinkingBlocks() {
        #expect(AnswerParser.stripThinking("<think>hmm</think>\nAnswer: 4") == "Answer: 4")
        #expect(AnswerParser.stripThinking("<think>still going") == "")
        #expect(AnswerParser.parse("<think>reasoning…").isEmpty)
    }

    @Test func unstructuredReplyFallsBack() {
        let parsed = AnswerParser.parse("The answer is 42.\n\nBecause 6 × 7 = 42.")
        #expect(parsed.answer == "The answer is 42.")
        #expect(parsed.explanation == "Because 6 × 7 = 42.")
    }
}

@Suite("Model routing")
struct ModelRouterTests {
    let installed = ["qwen3:4b", "qwen3-vl:4b"]

    @Test func automaticUsesVisionForVisualQuestions() {
        let choice = try? ModelRouter.choose(mode: .vision, strategy: .automatic, textModel: "qwen3:4b", visionModel: "qwen3-vl:4b", installed: installed).get()
        #expect(choice == ModelChoice(model: "qwen3-vl:4b", attachImage: true))
    }

    @Test func automaticUsesTextModelForText() {
        let choice = try? ModelRouter.choose(mode: .text, strategy: .automatic, textModel: "qwen3:4b", visionModel: "qwen3-vl:4b", installed: installed).get()
        #expect(choice?.model == "qwen3:4b")
        #expect(choice?.attachImage == false)
    }

    @Test func fallsBackToOCRWhenVisionMissing() {
        let choice = try? ModelRouter.choose(mode: .vision, strategy: .automatic, textModel: "qwen3:4b", visionModel: "qwen3-vl:4b", installed: ["qwen3:4b"]).get()
        #expect(choice?.model == "qwen3:4b")
        #expect(choice?.attachImage == false)
        #expect(choice?.note != nil)
    }

    @Test func visionOnlyNeverSwaps() {
        let choice = try? ModelRouter.choose(mode: .text, strategy: .visionOnly, textModel: "qwen3:4b", visionModel: "qwen3-vl:4b", installed: installed).get()
        #expect(choice?.model == "qwen3-vl:4b")
        #expect(choice?.attachImage == false)
    }

    @Test func reportsMissingModels() {
        let result = ModelRouter.choose(mode: .text, strategy: .automatic, textModel: "qwen3:4b", visionModel: "qwen3-vl:4b", installed: ["llama3:8b"])
        #expect(throws: ModelRouter.RoutingError.self) { try result.get() }
    }

    @Test func latestTagIsImplied() {
        #expect(ModelRouter.isInstalled("qwen3", in: ["qwen3:latest"]))
        #expect(!ModelRouter.isInstalled("qwen3", in: ["qwen3:4b"]))
    }

    @Test func thinkingPolicy() {
        #expect(PromptBuilder.shouldThink(kind: .math, preference: .balanced))
        #expect(!PromptBuilder.shouldThink(kind: .multipleChoice, preference: .balanced))
        #expect(!PromptBuilder.shouldThink(kind: .math, preference: .faster))
        #expect(PromptBuilder.shouldThink(kind: .general, preference: .thorough))
    }
}

@Suite("Answer cache")
struct AnswerCacheTests {
    func record(_ text: String, answer: String = "42") -> AnswerRecord {
        AnswerRecord(fingerprint: QuestionFingerprintService.make(from: text), questionExcerpt: text, kind: .math, mode: .text,
                     model: "qwen3:4b", parsed: ParsedAnswer(answer: answer, confidence: .high, explanation: ""), raw: answer,
                     createdAt: Date(), duration: 1)
    }

    @Test func storesAndLooksUpBySimilarity() async {
        let cache = AnswerCache(persist: false, directory: nil)
        await cache.store(record("What is six times seven, expressed as a whole number?"))
        let hit = await cache.lookup(QuestionFingerprintService.make(from: "what is six times seven expressed as a whole number"))
        #expect(hit?.parsed.answer == "42")
        let miss = await cache.lookup(QuestionFingerprintService.make(from: "What is the capital of France?"))
        #expect(miss == nil)
    }

    @Test func persistsWhenEnabledAndClears() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ScreenPilotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AnswerCache(persist: true, directory: dir)
        await cache.store(record("Compute 17 squared and give the result"))
        let reloaded = AnswerCache(persist: true, directory: dir)
        #expect(await reloaded.all().count == 1)
        await reloaded.clear()
        #expect(await AnswerCache(persist: true, directory: dir).all().isEmpty)
    }

    @Test func boundedSize() async {
        let cache = AnswerCache(persist: false, maxRecords: 3, directory: nil)
        for i in 0..<5 { await cache.store(record("Unique question number \(i) about topic \(i * 97)")) }
        #expect(await cache.all().count == 3)
    }
}
