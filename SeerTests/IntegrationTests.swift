import AppKit
import CoreText
import Foundation
import Testing
@testable import Seer

/// Renders text lines into an image the way a web page would show them.
private func renderPage(_ lines: [String], width: Int = 1400, height: Int = 900, fontSize: CGFloat = 26) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    var y = CGFloat(height) - 120
    for line in lines {
        if line.isEmpty { y -= fontSize; continue }
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 80, y: y)
        CTLineDraw(ctLine, context)
        y -= fontSize * 1.6
    }
    return context.makeImage()!
}

@Suite("Vision OCR → detection (integration)", .serialized, .timeLimit(.minutes(1)))
struct OCRIntegrationTests {
    @Test func ocrAndDetectMultipleChoice() async throws {
        let image = renderPage([
            "Question 7",
            "Which of the following is the time complexity of binary search?",
            "",
            "A) O(n)",
            "B) O(log n)",
            "C) O(n log n)",
            "D) O(1)",
        ])
        let ocr = try await OCRService().recognize(image, signature: nil)
        #expect(ocr.lines.count >= 5)
        #expect(ocr.fullText.localizedCaseInsensitiveContains("binary search"))
        let question = try #require(QuestionDetector().detect(ocr).question)
        #expect(question.kind == .multipleChoice)
        #expect(!question.isAmbiguous)
        #expect(question.options.count >= 3)
    }

    @Test func ocrDetectsLargeWrappedPersonalPrompt() async throws {
        let image = renderPage(["Google", "", "in 2 minutes, tell me about a", "time you had to learn", "something quickly.", "", "AI Overview"],
                               width: 1600, height: 1000, fontSize: 64)
        let ocr = try await OCRService().recognize(image, signature: nil)
        let question = try #require(QuestionDetector().detect(ocr).question)
        #expect(question.kind == .personal)
        #expect(!question.isAmbiguous)
    }

    @Test func blankPageHasNoQuestion() async throws {
        let ocr = try await OCRService().recognize(renderPage([]), signature: nil)
        #expect(QuestionDetector().detect(ocr).question == nil)
    }
}

// MARK: - Ollama streaming against a mocked /api/chat

final class MockOllamaProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.responder?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Ollama client", .serialized)
struct OllamaClientTests {
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!, protocolClasses: [MockOllamaProtocol.self])

    @Test func streamsChatChunks() async throws {
        MockOllamaProtocol.responder = { request in
            let lines = [
                #"{"message":{"role":"assistant","content":"","thinking":"Let me think"},"done":false}"#,
                #"{"message":{"role":"assistant","content":"**Answer:** "},"done":false}"#,
                #"{"message":{"role":"assistant","content":"(B) O(log n)"},"done":false}"#,
                #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
            ]
            return (200, Data(lines.joined(separator: "\n").utf8))
        }
        var content = ""
        var thinking = ""
        var done = false
        for try await chunk in client.chat(OllamaChatRequest(model: "qwen3:4b", messages: [OllamaMessage(role: "user", content: "hi")])) {
            content += chunk.message?.content ?? ""
            thinking += chunk.message?.thinking ?? ""
            done = chunk.done ?? false
        }
        #expect(done)
        #expect(thinking == "Let me think")
        #expect(AnswerParser.parse(content).answer == "(B) O(log n)")
    }

    @Test func mapsMissingModelError() async {
        MockOllamaProtocol.responder = { _ in (404, Data(#"{"error":"model \"qwen3:4b\" not found, try pulling it first"}"#.utf8)) }
        await #expect(throws: OllamaError.modelNotFound("qwen3:4b")) {
            for try await _ in client.chat(OllamaChatRequest(model: "qwen3:4b", messages: [])) {}
        }
    }

    @Test func listsModels() async throws {
        MockOllamaProtocol.responder = { _ in
            (200, Data(#"{"models":[{"name":"qwen3:4b","size":2500000000,"details":{"family":"qwen3"}},{"name":"qwen3-vl:4b","size":3300000000}]}"#.utf8))
        }
        let models = try await client.listModels()
        #expect(models.map(\.name) == ["qwen3:4b", "qwen3-vl:4b"])
        #expect(models[1].looksVisionCapable)
    }

    @Test func requestEncodingOmitsNilFields() throws {
        let request = OllamaChatRequest(model: "m", messages: [OllamaMessage(role: "user", content: "x")], think: nil, keep_alive: "10m")
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!json.contains("think"))
        #expect(!json.contains("images"))
        #expect(json.contains(#""keep_alive":"10m""#))
    }
}
