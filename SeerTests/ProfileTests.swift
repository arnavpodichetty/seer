import Foundation
import Testing
@testable import Seer

@Suite("User context") @MainActor
struct ProfileTests {
    @Test func contextStartsEmpty() throws {
        let suite = try #require(UserDefaults(suiteName: "SeerContextTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: suite)
        #expect(settings.profileSummary.isEmpty)
        #expect(settings.activeProfile == nil)
    }

    @Test func profileIsOnlyAddedToInterviewPrompts() throws {
        let detector = QuestionDetector()
        let interview = try #require(detector.detect(page(["Tell me about yourself."])).question)
        let math = try #require(detector.detect(page(["Exercise 1", "Solve for x: 2x + 3 = 11"])).question)
        let profile = "- Built a budgeting app used by 2,000 students"
        #expect(PromptBuilder.userPrompt(for: interview, attachingImage: false, profile: profile).contains("budgeting app"))
        #expect(!PromptBuilder.userPrompt(for: math, attachingImage: false, profile: profile).contains("budgeting app"))
        #expect(PromptBuilder.systemPrompt(detail: .standard, kind: .interview).contains("STAR"))
    }

    @Test func activeProfileRespectsToggle() {
        let defaults = UserDefaults(suiteName: "ProfileTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.profileSummary = ""
        #expect(settings.activeProfile == nil)
        settings.profileSummary = "  - Studies CS  "
        #expect(settings.activeProfile == "- Studies CS")
        settings.useProfileInAnswers = false
        #expect(settings.activeProfile == nil)
    }

    @Test func clearingInterviewAnswersKeepsOthers() async {
        let cache = AnswerCache(persist: false, directory: nil)
        func record(_ text: String, _ kind: QuestionKind) -> AnswerRecord {
            AnswerRecord(fingerprint: QuestionFingerprintService.make(from: text), questionExcerpt: text, kind: kind, mode: .text,
                         model: "m", parsed: .empty, raw: "", createdAt: Date(), duration: 0)
        }
        await cache.store(record("Tell me about yourself and your background", .interview))
        await cache.store(record("Solve for x when two x plus three equals eleven", .math))
        await cache.removeAll(kind: .interview)
        #expect(await cache.all().map(\.kind) == [.math])
    }
}

@Suite("Reset") @MainActor
struct ResetTests {
    @Test func resetClearsAnswerAndCachedEntry() async throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ResetTests-\(UUID().uuidString)")!)
        let state = AppState()
        let cache = AnswerCache(persist: false, directory: nil)
        let orchestrator = AIOrchestrator(state: state, settings: settings, cache: cache)
        state.phase = .answer
        state.parsed = ParsedAnswer(answer: "(B) Stack", confidence: .high, explanation: "LIFO")
        state.question = QuestionSummary(excerpt: "Which structure is LIFO?", kind: .multipleChoice, mode: .text, sourceApp: nil)

        orchestrator.resetConversation()

        #expect(state.phase == .idle("Monitoring paused."))
        #expect(state.parsed.isEmpty)
        #expect(state.question == nil)
    }

    @Test func defaultShortcutsAreDistinct() {
        let defaults: Set<KeyShortcut> = [.defaultOverlay, .defaultReset, .defaultSolve]
        #expect(defaults.count == 3)
        #expect(KeyShortcut.defaultOverlay.label == "⌃⌥Space")
        #expect(KeyShortcut(keyCode: 40, carbonModifiers: CarbonModifier.command | CarbonModifier.shift, keyName: "K").label == "⇧⌘K")
    }

    @Test func customEndpointNormalization() throws {
        let suite = try #require(UserDefaults(suiteName: "SeerCustomTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: suite)
        settings.customBaseURL = "https://api.openai.com/v1/"
        #expect(settings.customEndpoint?.absoluteString == "https://api.openai.com/v1/chat/completions")
        settings.customBaseURL = "openrouter.ai/api/v1"
        #expect(settings.customEndpoint?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        settings.customBaseURL = "https://api.deepseek.com/v1/chat/completions"
        #expect(settings.customEndpoint?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        settings.customBaseURL = ""
        #expect(settings.customEndpoint == nil)
        settings.customEnabled = false
        #expect(settings.activeCustomModel == nil)
    }

    @Test func recordedShortcutPersists() throws {
        let suite = try #require(UserDefaults(suiteName: "SeerShortcutTest-\(UUID().uuidString)"))
        let custom = KeyShortcut(keyCode: 122, carbonModifiers: 0, keyName: "F1")
        AppSettings(defaults: suite).solveShortcut = custom
        #expect(AppSettings(defaults: suite).solveShortcut == custom)
        #expect(custom.isFunctionKey)
    }
}
