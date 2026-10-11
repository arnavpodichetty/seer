import AppKit
import Testing
@testable import Seer

/// TEMPORARY evaluation harness (delete after use).
enum ZZ {
    static let dir = "/private/tmp/claude-501/-Users-arnav-Documents-seer/99ac5761-a6e8-49ac-a08c-082c46212eba/scratchpad/eval"
    struct Item: Codable { var id, category, truth, kind, image, notes, grade: String; var checks: [[String]]; var detect: Bool }
    static func items() throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/manifest.json")))
    }
    static func image(_ item: Item) -> CGImage {
        NSImage(contentsOf: URL(fileURLWithPath: dir + "/" + item.image))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    static func write(_ object: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir + "/" + name))
    }
    static func describe(_ q: DetectedQuestion?) -> [String: Any] {
        guard let q else { return ["found": false] }
        return ["found": true, "kind": "\(q.kind)", "mode": "\(q.mode)", "ambiguous": q.isAmbiguous, "score": q.score,
                "text": q.text, "context": q.contextText.prefix(400).description]
    }
}

@Suite(.serialized) struct ZZEval {
    @Test func phaseA() async throws {
        var out: [[String: Any]] = []
        for item in try ZZ.items() {
            let img = ZZ.image(item)
            let ocr = try await OCRService().recognize(img, signature: nil)
            let auto = QuestionDetector().detect(ocr)
            let forced = QuestionDetector().detect(ocr, forced: true)
            let confs = ocr.lines.map { Double($0.confidence) }
            out.append(["id": item.id, "category": item.category, "expectKind": item.kind, "expectDetect": item.detect,
                        "ocr": ocr.lines.map(\.text).joined(separator: " ⏎ "),
                        "minConf": confs.min() ?? 0, "avgConf": confs.isEmpty ? 0 : confs.reduce(0, +) / Double(confs.count),
                        "auto": ZZ.describe(auto.question), "forced": ZZ.describe(forced.question)])
        }
        try ZZ.write(out, "phaseA.json")
    }
}

@Suite struct ZZBlocks {
    @Test func dump() async throws {
        for id in ["code_vscode_todo", "pers_likert", "code_lc_maxprofit"] {
            let item = try ZZ.items().first { $0.id == id }!
            let ocr = try await OCRService().recognize(ZZ.image(item), signature: nil)
            let size = ocr.imageSize
            let lines = ocr.lines.map { l -> OCRLine in var l = l; l.box = CGRect(x: l.box.minX * size.width, y: l.box.minY * size.height, width: l.box.width * size.width, height: l.box.height * size.height); return l }
            let med = QuestionDetector.median(lines.map(\.box.height))
            for (ci, col) in QuestionDetector.splitColumns(lines, width: size.width, depth: 2).enumerated() {
                for (bi, b) in QuestionDetector.makeBlocks(QuestionDetector.makeRows(col, medianHeight: med), medianHeight: med).enumerated() {
                    print("BLK \(id) col\(ci) b\(bi) score=\(QuestionDetector.score(rows: b.rows).score): " + b.rows.map { "[\($0.text) y=\(Int($0.box.minY))-\(Int($0.box.maxY)) x=\(Int($0.box.minX))]" }.joined(separator: " "))
                }
            }
        }
    }
}

@MainActor @Suite struct ZZPhaseB {
    struct Config { var name: String; var provider: String; var model: String; var image: Bool }
    static let configs = [
        Config(name: "A_text_groq", provider: "groq", model: "openai/gpt-oss-120b", image: false),
        Config(name: "B_text_gemini", provider: "gemini", model: "gemini-3.5-flash-lite", image: false),
        Config(name: "C_vision_groq", provider: "groq", model: "qwen/qwen3.8-27b", image: true),
        Config(name: "D_vision_gemini", provider: "gemini", model: "gemini-3.6-flash", image: true),
    ]

    func call(_ c: Config, q: DetectedQuestion, images: [String], groqKey: String, geminiKey: String) async throws -> String {
        let system = PromptBuilder.systemPrompt(detail: .brief, kind: q.kind)
        let profile: String? = q.kind == .interview ? sampleProfile : nil
        let text = PromptBuilder.userPrompt(for: q, attachingImage: !images.isEmpty, profile: profile)
        let effort = PromptBuilder.geminiThinkingLevel(kind: q.kind, preference: .faster)
        if c.provider == "groq" {
            var e: String? = effort
            for _ in 0..<2 {
                do {
                    return try await GroqClient(apiKey: groqKey).generateText(.init(model: c.model, system: system, text: text, imagesBase64JPEG: images,
                        maxTokens: AIOrchestrator.groqTokenBudget(1024), temperature: q.kind == .interview ? 0.2 : 0.3, reasoningEffort: e))
                } catch let CloudAIError.http(status, message) where status == 400 && e != nil && message.lowercased().contains("reasoning") { e = nil }
            }
            throw CloudAIError.emptyResponse
        }
        return try await GeminiClient(apiKey: geminiKey).generateText(.init(model: c.model, system: system, text: text, imagesBase64JPEG: images,
            maxOutputTokens: 1024 + 2048, temperature: 0.3, thinkingLevel: effort))
    }

    @Test func run() async throws {
        let groqKey = try #require(KeychainStore.read(service: KeychainStore.groqService))
        let geminiKey = try #require(KeychainStore.read())
        let only = ProcessInfo.processInfo.environment["ZZ_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var out: [[String: Any]] = []
        for item in try ZZ.items() where item.detect && (only == nil || only!.contains(item.id)) {
            let img = ZZ.image(item)
            let ocr = try await OCRService().recognize(img, signature: nil)
            var q = QuestionDetector().detect(ocr, forced: true).question ?? .visual(ocrText: ocr.fullText, signature: nil)
            q.isAmbiguous = false
            let crop = AIOrchestrator.visionCrop(for: q.region).flatMap { ImageUtilities.crop(img, normalized: $0) } ?? img
            for c in Self.configs {
                let images = c.image ? [ImageUtilities.jpegData(ImageUtilities.downsample(crop, maxDimension: c.provider == "groq" ? 1024 : 1536))!.base64EncodedString()] : []
                let start = Date()
                var raw = "", error = ""
                for attempt in 0..<5 {
                    do { raw = try await call(c, q: q, images: images, groqKey: groqKey, geminiKey: geminiKey); error = ""; break }
                    catch { let e = error as? CloudAIError
                        if case .rateLimited = e { try await Task.sleep(for: .seconds(15 * (attempt + 1))); continue }
                        if case .overloaded = e { try await Task.sleep(for: .seconds(10)); continue }
                        raw = ""; let msg = error.localizedDescription; print("ZZB ERR \(item.id) \(c.name): \(msg)"); out.append(["id": item.id, "config": c.name, "error": msg]); break }
                }
                if raw.isEmpty { continue }
                let parsed = AnswerParser.parse(raw)
                out.append(["id": item.id, "config": c.name, "seconds": Date().timeIntervalSince(start), "kind": "\(q.kind)",
                            "question": q.text, "answer": parsed.answer, "raw": raw])
                print("ZZB \(item.id) \(c.name) \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                try ZZ.write(out, "phaseB.json")
            }
        }
        try ZZ.write(out, "phaseB.json")
    }
}
