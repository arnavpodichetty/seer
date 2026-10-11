import Foundation

/// Client for OpenAI-compatible chat completions APIs (Groq by default, or the user's own
/// custom provider), streaming server-sent events.
nonisolated struct GroqClient: Sendable {
    static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    struct Request: Sendable {
        var model: String
        var system: String?
        var text: String
        var imagesBase64JPEG: [String] = []
        var maxTokens: Int = 2048
        var temperature: Double = 0.3
        /// "low", "medium" or "high" for reasoning models; nil uses the model default.
        var reasoningEffort: String? = "low"
    }

    let apiKey: String
    let session: URLSession
    let endpoint: URL

    init(apiKey: String, endpoint: URL = GroqClient.groqEndpoint, protocolClasses: [AnyClass]? = nil) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Request body

    private enum Content: Encodable {
        case text(String)
        case parts([Part])

        struct Part: Encodable {
            struct ImageURL: Encodable { var url: String }
            var type: String
            var text: String?
            var image_url: ImageURL?
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .text(text): try container.encode(text)
            case let .parts(parts): try container.encode(parts)
            }
        }
    }

    private struct Body: Encodable {
        struct Message: Encodable { var role: String; var content: Content }
        var model: String
        var messages: [Message]
        var stream: Bool
        var max_completion_tokens: Int?
        var max_tokens: Int?
        var temperature: Double?
        var reasoning_effort: String?
        var reasoning_format: String?
    }

    /// Request options some providers reject; dropped or swapped on a 400 that names them.
    struct Compatibility: Equatable, Sendable {
        var omitTemperature = false
        var legacyMaxTokens = false

        func adjusted(forError message: String) -> Compatibility? {
            let lower = message.lowercased()
            var next = self
            if lower.contains("temperature") { next.omitTemperature = true }
            if lower.contains("max_completion_tokens") { next.legacyMaxTokens = true }
            return next == self ? nil : next
        }
    }

    static func body(for request: Request, stream: Bool, compatibility: Compatibility = .init()) throws -> Data {
        var messages: [Body.Message] = []
        if let system = request.system { messages.append(.init(role: "system", content: .text(system))) }
        if request.imagesBase64JPEG.isEmpty {
            messages.append(.init(role: "user", content: .text(request.text)))
        } else {
            var parts = [Content.Part(type: "text", text: request.text)]
            parts += request.imagesBase64JPEG.map {
                Content.Part(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\($0)"))
            }
            messages.append(.init(role: "user", content: .parts(parts)))
        }
        // Reasoning stays hidden so only the answer streams back.
        let body = Body(model: request.model, messages: messages, stream: stream,
                        max_completion_tokens: compatibility.legacyMaxTokens ? nil : request.maxTokens,
                        max_tokens: compatibility.legacyMaxTokens ? request.maxTokens : nil,
                        temperature: compatibility.omitTemperature ? nil : request.temperature,
                        reasoning_effort: request.reasoningEffort,
                        reasoning_format: request.reasoningEffort == nil ? nil : "hidden")
        return try JSONEncoder().encode(body)
    }

    // MARK: - Streaming

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
            var finish_reason: String?
        }
        struct ErrorBody: Decodable { var message: String?; var code: String? }
        var choices: [Choice]?
        var error: ErrorBody?
    }

    enum Event: Sendable, Equatable {
        case text(String)
        case finished(reason: String?)
    }

    func stream(_ request: Request) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw CloudAIError.missingKey }
                    var compatibility = Compatibility()
                    var attempt = 0
                    var stream: URLSession.AsyncBytes
                    while true {
                        var urlRequest = URLRequest(url: endpoint)
                        urlRequest.httpMethod = "POST"
                        urlRequest.timeoutInterval = request.imagesBase64JPEG.isEmpty ? 15 : 25
                        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        urlRequest.httpBody = try Self.body(for: request, stream: true, compatibility: compatibility)

                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        guard let http = response as? HTTPURLResponse else { throw CloudAIError.http(status: 0, message: "No response") }
                        if http.statusCode == 200 { stream = bytes; break }
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 8192 { break }
                        }
                        // Retry once or twice without options this model rejects (e.g. temperature on reasoning models).
                        if http.statusCode == 400, attempt < 2,
                           let next = compatibility.adjusted(forError: String(decoding: body, as: UTF8.self)) {
                            compatibility = next
                            attempt += 1
                            continue
                        }
                        throw GeminiClient.error(status: http.statusCode, body: body)
                    }
                    let bytes = stream
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let chunk = try? decoder.decode(Chunk.self, from: data) else { continue }
                        if let error = chunk.error { throw GeminiClient.error(status: 500, message: error.message ?? "Unknown error", code: error.code) }
                        for choice in chunk.choices ?? [] {
                            if let text = choice.delta?.content, !text.isEmpty { continuation.yield(.text(text)) }
                            if let reason = choice.finish_reason { continuation.yield(.finished(reason: reason)) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: GeminiClient.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the HTTPS connection ahead of a request so the first answer starts sooner.
    /// The unauthenticated request just gets a 401; the connection is what's reused.
    func preconnect() {
        var request = URLRequest(url: endpoint.deletingLastPathComponent().deletingLastPathComponent().appending(path: "models"))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }

    func generateText(_ request: Request) async throws -> String {
        var output = ""
        for try await event in stream(request) {
            if case let .text(text) = event { output += text }
        }
        return output
    }
}
