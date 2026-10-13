import CoreGraphics
import Foundation
import Testing
@testable import Seer

@Suite("Gemini provider", .serialized)
struct GeminiTests {
    let client = GeminiClient(apiKey: "test-key", protocolClasses: [MockOllamaProtocol.self])

    @Test func fallbackOrder() {
        #expect(AIOrchestrator.backends(provider: .gemini, hasGeminiKey: true, primary: "a", fallback: "b")
                == [.gemini("a"), .gemini("b"), .ollama])
        #expect(AIOrchestrator.backends(provider: .gemini, hasGeminiKey: true, primary: "a", fallback: "a")
                == [.gemini("a"), .ollama])
        #expect(AIOrchestrator.backends(provider: .gemini, hasGeminiKey: false, primary: "a", fallback: "b") == [.ollama])
        #expect(AIOrchestrator.backends(provider: .ollama, hasGeminiKey: true, primary: "a", fallback: "b") == [.ollama])
        #expect(AIOrchestrator.backends(provider: .gemini, hasGeminiKey: true, primary: "a", fallback: "b", vision: "v")
                == [.gemini("v"), .gemini("a"), .gemini("b"), .ollama])
        // Groq first (the default), then Gemini, then Ollama.
        #expect(AIOrchestrator.backends(provider: .groq, hasGeminiKey: true, primary: "a", fallback: "b", groqModel: "g")
                == [.groq("g"), .gemini("a"), .gemini("b"), .ollama])
        #expect(AIOrchestrator.backends(provider: .gemini, hasGeminiKey: true, primary: "a", fallback: "b", groqModel: "g")
                == [.gemini("a"), .gemini("b"), .groq("g"), .ollama])
        #expect(AIOrchestrator.backends(provider: .groq, hasGeminiKey: false, primary: "a", fallback: "b", groqModel: "g")
                == [.groq("g"), .ollama])
        #expect(AIOrchestrator.backends(provider: .ollama, hasGeminiKey: true, primary: "a", fallback: "b", groqModel: "g") == [.ollama])
        // The custom model goes first, except in Ollama-only mode.
        #expect(AIOrchestrator.backends(provider: .groq, hasGeminiKey: true, primary: "a", fallback: "b", groqModel: "g", customModel: "c")
                == [.custom("c"), .groq("g"), .gemini("a"), .gemini("b"), .ollama])
        #expect(AIOrchestrator.backends(provider: .ollama, hasGeminiKey: true, primary: "a", fallback: "b", customModel: "c") == [.ollama])
    }

    @Test func parsesInteractionsSSEStream() async throws {
        // Event shapes captured from the live API.
        MockOllamaProtocol.responder = { request in
            #expect(request.url?.absoluteString.contains("interactions?alt=sse") == true)
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
            let sse = """
            event: interaction.created
            data: {"interaction":{"id":"x","object":"interaction","model":"gemini-3.5-flash-lite"},"event_type":"interaction.created"}

            event: step.start
            data: {"index":0,"step":{"type":"thought"},"event_type":"step.start"}

            event: step.delta
            data: {"index":0,"delta":{"signature":"abc","type":"thought_signature"},"event_type":"step.delta"}

            event: step.start
            data: {"index":1,"step":{"type":"model_output"},"event_type":"step.start"}

            event: step.delta
            data: {"index":1,"delta":{"text":"**Answer:** ","type":"text"},"event_type":"step.delta"}

            event: step.delta
            data: {"index":1,"delta":{"text":"391","type":"text"},"event_type":"step.delta"}

            event: interaction.completed
            data: {"interaction":{"id":"x","status":"completed"},"event_type":"interaction.completed"}

            event: done
            data: [DONE]

            """
            return (200, Data(sse.utf8))
        }
        var events: [GeminiClient.Event] = []
        for try await event in client.stream(.init(model: "gemini-3.5-flash-lite", system: "s", text: "q")) { events.append(event) }
        #expect(events == [.thinking, .text("**Answer:** "), .text("391"), .completed(status: "completed")])
    }

    @Test func overloadedModelIsReported() async {
        MockOllamaProtocol.responder = { _ in
            (503, Data(#"{"error":{"message":"gemini-3.8-flash is currently experiencing high demand, spikes in demand are usually temporary. Please try again later.","code":"service_unavailable"}}"#.utf8))
        }
        do {
            for try await _ in client.stream(.init(model: "gemini-3.8-flash", system: nil, text: "q")) {}
            Issue.record("expected an error")
        } catch let error as CloudAIError {
            #expect(error.shortReason == "overloaded")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func errorMapping() {
        #expect(GeminiClient.error(status: 400, message: "Thinking level THINKING_LEVEL_MINIMAL is not supported for this model.", code: "invalid_request")
                == .http(status: 400, message: "Thinking level THINKING_LEVEL_MINIMAL is not supported for this model."))
        #expect(GeminiClient.error(status: 429, message: "Quota exceeded", code: nil).shortReason == "rate limited")
        #expect(GeminiClient.error(status: 401, message: "API key not valid", code: nil).shortReason == "invalid API key")
        #expect((GeminiClient.map(URLError(.notConnectedToInternet)) as? CloudAIError) == .offline)
        #expect(GeminiClient.error(status: 413, message: "Request too large for model `qwen/qwen3.8-27b` on tokens per minute (TPM)", code: nil).shortReason == "rate limited")
        #expect(AIOrchestrator.groqTokenBudget(1024) == 1536)
        #expect(AIOrchestrator.groqTokenBudget(4000) == 2048)
    }

    @Test func requestBodyMatchesInteractionsSchema() throws {
        let data = try GeminiClient.body(for: .init(model: "m", system: "sys", text: "hello", imagesBase64JPEG: ["AAAA"],
                                                    maxOutputTokens: 500, temperature: 0.3, thinkingLevel: "low"), stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "m")
        #expect(json["system_instruction"] as? String == "sys")
        #expect(json["stream"] as? Bool == true)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.first?["type"] as? String == "text")
        #expect(input.last?["type"] as? String == "image")
        #expect(input.last?["mime_type"] as? String == "image/jpeg")
        let config = try #require(json["generation_config"] as? [String: Any])
        #expect(config["thinking_level"] as? String == "low")
        #expect(config["max_output_tokens"] as? Int == 500)
    }

    @Test func classificationTranscriptEndsWithQuestion() throws {
        let q = try #require(QuestionDetector().detect(page(["Tell me about yourself."])).question)
        let transcript = PromptBuilder.classificationTranscript(for: q)
        #expect(transcript.hasSuffix("Answer:"))
        #expect(transcript.contains("Tell me about yourself."))
    }
}

/// Calls the real Gemini API with the key from the Keychain. Opt-in:
/// TEST_RUNNER_SEER_LIVE=1 xcodebuild test …
@Suite("Gemini live", .enabled(if: ProcessInfo.processInfo.environment["SEER_LIVE"] != nil))
struct GeminiLiveTests {
    @Test func answersPersonalPromptWithProfile() async throws {
        let key = try #require(KeychainStore.read())
        let q = try #require(QuestionDetector().detect(page(["in 2 minutes, tell me about a", "time you had to learn", "something quickly."])).question)
        let profile = sampleProfile
        var lastError: Error?
        for model in ["gemini-3.5-flash", "gemini-3.5-flash-lite"] {
            let start = Date()
            var firstToken: TimeInterval?
            var raw = ""
            do {
                for try await event in GeminiClient(apiKey: key).stream(.init(
                    model: model, system: PromptBuilder.systemPrompt(detail: .brief, kind: q.kind),
                    text: PromptBuilder.userPrompt(for: q, attachingImage: false, profile: profile),
                    maxOutputTokens: 2900, temperature: 0.3, thinkingLevel: "low")) {
                    if case let .text(t) = event { raw += t; if firstToken == nil { firstToken = Date().timeIntervalSince(start) } }
                }
            } catch {
                lastError = error
                print("LIVE \(model) failed: \(error.localizedDescription)")
                continue
            }
            let parsed = AnswerParser.parse(raw)
            print("LIVE \(model): first token \(String(format: "%.2f", firstToken ?? -1))s, total \(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(parsed.answer.split(separator: " ").count) words")
            print("LIVE ANSWER START\n\(raw)\nLIVE ANSWER END")
            #expect(!parsed.answer.isEmpty)
            return
        }
        Issue.record("All Gemini models failed: \(lastError?.localizedDescription ?? "?")")
    }

    @Test(arguments: ["personal", "math", "code"])
    func solvesRealQuestions(_ kind: String) async throws {
        let key = try #require(KeychainStore.read())
        let lines: [String] = switch kind {
        case "personal": [
            "Google | tell me about a time you had to make a decision with incomplete data",
            "AI Mode All Short videos Forums Videos Shopping Images More • Tools",
            "AI Overview",
            "To handle a decision with incomplete data effectively, use the STAR method:",
            "• Situation: Briefly describe the high-stakes environment or tight deadline.",
        ]
        case "math": ["Problem 4", "A rectangle has a perimeter of 46 cm and an area of 120 cm². Find its length and width."]
        default: ["Given an array of integers nums, return the length of the longest strictly increasing subsequence.",
                  "Example 1: Input: nums = [10,9,2,5,3,7,101,18] Output: 4", "Constraints: 1 <= nums.length <= 2500"]
        }
        let q = try #require(QuestionDetector().detect(page(lines, width: 0.9)).question)
        print("LIVE[\(kind)] detected \(q.kind.rawValue): \(q.text.replacingOccurrences(of: "\n", with: " / "))")
        let profile = sampleProfile
        for model in ["gemini-3.5-flash", "gemini-3.5-flash-lite"] {
            let start = Date()
            do {
                let raw = try await GeminiClient(apiKey: key).generateText(.init(
                    model: model, system: PromptBuilder.systemPrompt(detail: .brief, kind: q.kind),
                    text: PromptBuilder.userPrompt(for: q, attachingImage: false, profile: profile),
                    maxOutputTokens: 3000, temperature: 0.3, thinkingLevel: PromptBuilder.geminiThinkingLevel(kind: q.kind, preference: .faster)))
                print("LIVE[\(kind)] \(model) \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n\(raw)\nLIVE-END")
                #expect(!AnswerParser.parse(raw).answer.isEmpty)
                return
            } catch {
                print("LIVE[\(kind)] \(model) failed: \(error.localizedDescription)")
            }
        }
        Issue.record("all models failed")
    }

    @Test func picturesAreSolvedOrDeclined() async throws {
        let key = try #require(KeychainStore.read())
        let client = GeminiClient(apiKey: key)
        for (name, image, expectsQuestion) in [("grid", shadedGrid(), true), ("gradient", gradientPicture(), false)] {
            var q = DetectedQuestion.visual(ocrText: "", signature: ScreenChangeDetector.signature(for: image))
            q.needsConfirmation = true
            let encoded = try #require(ImageUtilities.jpegData(image)?.base64EncodedString())
            var answered = false
            for model in ["gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.5-flash"] {
                let start = Date()
                do {
                    let raw = try await client.generateText(.init(
                        model: model, system: PromptBuilder.systemPrompt(detail: .brief, kind: q.kind),
                        text: PromptBuilder.userPrompt(for: q, attachingImage: true), imagesBase64JPEG: [encoded],
                        maxOutputTokens: 3000, temperature: 0.2, thinkingLevel: "low"))
                    print("LIVE[\(name)] \(model) \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n\(raw)\nLIVE-END")
                    let declined = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(PromptBuilder.noQuestionToken)
                    #expect(declined != expectsQuestion, "\(name)")
                    answered = true
                    break
                } catch {
                    print("LIVE[\(name)] \(model) failed after \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(error.localizedDescription)")
                }
            }
            #expect(answered, "\(name): every model failed")
        }
    }

    @Test func chatFollowUpRewritesAnswer() async throws {
        let key = try #require(KeychainStore.read())
        let q = try #require(QuestionDetector().detect(page(["Exercise 1", "Solve for x: 2x + 3 = 11"])).question)
        let prompt = PromptBuilder.chatPrompt(message: "explain it like I'm 10, in two sentences", question: q,
                                              answer: "**Answer:** x = 4\n**Explanation:** Subtract 3, divide by 2.",
                                              history: [], profile: nil, attachingScreen: false)
        for model in ["gemini-3.5-flash-lite", "gemini-3.5-flash"] {
            let start = Date()
            do {
                let reply = try await GeminiClient(apiKey: key).generateText(.init(model: model, system: PromptBuilder.chatSystemPrompt, text: prompt,
                                                                                    maxOutputTokens: 2000, temperature: 0.4, thinkingLevel: "low"))
                print("LIVE[chat] \(model) \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n\(reply)\nLIVE-END")
                #expect(reply.contains("4"))
                return
            } catch {
                print("LIVE[chat] \(model) failed: \(error.localizedDescription)")
            }
        }
        Issue.record("all models failed")
    }

    @Test(arguments: ["math", "personal", "grid"])
    func groqAnswers(_ kind: String) async throws {
        let key = try #require(KeychainStore.read(service: KeychainStore.groqService))
        let client = GroqClient(apiKey: key)
        var q: DetectedQuestion
        var images: [String] = []
        var model = "openai/gpt-oss-120b"
        switch kind {
        case "math":
            q = try #require(QuestionDetector().detect(page(["Problem 4", "A rectangle has a perimeter of 46 cm and an area of 120 cm². Find its length and width."])).question)
        case "personal":
            q = try #require(QuestionDetector().detect(page(["tell me about a time you had to make a decision with incomplete data"])).question)
        default:
            q = DetectedQuestion.visual(ocrText: "", signature: ScreenChangeDetector.signature(for: shadedGrid()))
            images = [try #require(ImageUtilities.jpegData(ImageUtilities.downsample(shadedGrid(), maxDimension: 1024))?.base64EncodedString())]
            model = "qwen/qwen3.8-27b"
        }
        let profile = kind == "personal" ? sampleProfile : nil
        let start = Date()
        let raw = try await client.generateText(.init(model: model, system: PromptBuilder.systemPrompt(detail: .brief, kind: q.kind),
                                                      text: PromptBuilder.userPrompt(for: q, attachingImage: !images.isEmpty, profile: profile),
                                                      imagesBase64JPEG: images, maxTokens: AIOrchestrator.groqTokenBudget(1024),
                                                      temperature: kind == "personal" ? 0.2 : 0.3, reasoningEffort: "low"))
        print("LIVE[groq-\(kind)] \(model) \(String(format: "%.2f", Date().timeIntervalSince(start)))s\n\(raw)\nLIVE-END")
        let answer = AnswerParser.parse(raw).answer
        #expect(!answer.isEmpty)
        if kind == "math" { #expect(answer.contains("15") && answer.contains("8")) }
        if kind == "grid" { #expect(raw.contains("5/7") || raw.contains("25/35") || raw.contains("frac{5}{7}") || raw.contains("25 out of 35")) }
        if kind == "personal" { #expect(!raw.contains("%"), "no invented percentages") }
    }
}

/// A smooth colour gradient: a picture with nothing to solve.
func gradientPicture() -> CGImage {
    let width = 760, height = 600
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [CGColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return ctx.makeImage()!
}

/// 7×5 grid like the user's screen: left 3 columns, bottom 2 rows and part of the right column shaded (25 of 35).
func shadedGrid() -> CGImage {
    let cell = 80, cols = 7, rows = 5, margin = 100
    let width = cols * cell + margin * 2, height = rows * cell + margin * 2
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for r in 0..<rows {            // r = 0 is the top row
        for c in 0..<cols {
            let shaded = c < 3 || r >= 3 || (c == 6 && (r == 1 || r == 2))
            let rect = CGRect(x: margin + c * cell, y: height - margin - (r + 1) * cell, width: cell, height: cell)
            ctx.setFillColor(shaded ? CGColor(red: 0.78, green: 0.16, blue: 0.3, alpha: 1) : CGColor(gray: 1, alpha: 1))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
            ctx.stroke(rect, width: 2)
        }
    }
    return ctx.makeImage()!
}

@Suite("Groq client", .serialized)
struct GroqClientTests {
    let client = GroqClient(apiKey: "gsk-test", protocolClasses: [MockOllamaProtocol.self])

    @Test func parsesOpenAIStyleStream() async throws {
        MockOllamaProtocol.responder = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
            let sse = """
            data: {"id":"x","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

            data: {"id":"x","choices":[{"index":0,"delta":{"content":"**Answer:** "},"finish_reason":null}]}

            data: {"id":"x","choices":[{"index":0,"delta":{"content":"15 cm × 8 cm"},"finish_reason":null}]}

            data: {"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
            return (200, Data(sse.utf8))
        }
        var events: [GroqClient.Event] = []
        for try await event in client.stream(.init(model: "openai/gpt-oss-120b", system: "s", text: "q")) { events.append(event) }
        #expect(events == [.text("**Answer:** "), .text("15 cm × 8 cm"), .finished(reason: "stop")])
    }

    @Test func mapsRateLimit() async {
        MockOllamaProtocol.responder = { _ in
            (429, Data(#"{"error":{"message":"Rate limit reached for model openai/gpt-oss-120b","type":"tokens","code":"rate_limit_exceeded"}}"#.utf8))
        }
        do {
            for try await _ in client.stream(.init(model: "openai/gpt-oss-120b", system: nil, text: "q")) {}
            Issue.record("expected an error")
        } catch let error as CloudAIError {
            #expect(error.shortReason == "rate limited")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func retriesWithoutRejectedOptions() async throws {
        var bodies: [[String: Any]] = []
        MockOllamaProtocol.responder = { request in
            let data = request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? request.httpBody ?? Data()
            bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            if bodies.count == 1 {
                return (400, Data(#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.3 with this model."}}"#.utf8))
            }
            return (200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8))
        }
        let text = try await client.generateText(.init(model: "m", system: nil, text: "q", reasoningEffort: nil))
        #expect(text == "ok")
        #expect(bodies.count == 2)
        #expect(bodies.first?["temperature"] != nil)
        #expect(bodies.last?["temperature"] == nil)
    }

    @Test func compatibilityAdjustments() {
        let start = GroqClient.Compatibility()
        #expect(start.adjusted(forError: "Unsupported value: 'temperature'")?.omitTemperature == true)
        #expect(start.adjusted(forError: "Unrecognized request argument supplied: max_completion_tokens")?.legacyMaxTokens == true)
        #expect(start.adjusted(forError: "Invalid API key") == nil)
    }

    @Test func encodesTextAndImageMessages() throws {
        let text = try JSONSerialization.jsonObject(with: GroqClient.body(for: .init(model: "m", system: "sys", text: "hi"), stream: true)) as? [String: Any]
        let messages = try #require(text?["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[1]["content"] as? String == "hi")
        #expect(text?["reasoning_format"] as? String == "hidden")

        let image = try JSONSerialization.jsonObject(with: GroqClient.body(for: .init(model: "m", system: nil, text: "what?", imagesBase64JPEG: ["AAAA"]), stream: false)) as? [String: Any]
        let parts = try #require((image?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(parts.last?["type"] as? String == "image_url")
        #expect(((parts.last?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }
}
