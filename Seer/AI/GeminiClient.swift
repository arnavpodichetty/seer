import Foundation

/// Errors from cloud providers (Gemini, Groq).
nonisolated enum CloudAIError: LocalizedError, Equatable {
    case missingKey
    case invalidKey(String)
    case overloaded(String)
    case rateLimited(String)
    case http(status: Int, message: String)
    case timedOut
    case offline
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key is set."
        case let .invalidKey(message): "The API key was rejected. \(message)"
        case let .overloaded(message): "The model is overloaded right now. \(message)"
        case let .rateLimited(message): "Rate limit reached. \(message)"
        case let .http(status, message): "Cloud AI error (\(status)): \(message)"
        case .timedOut: "The model took too long to respond."
        case .offline: "Can't reach the AI service (no internet connection?)."
        case .emptyResponse: "The model returned an empty answer."
        }
    }

    /// Short reason for the "answered by fallback" note.
    var shortReason: String {
        switch self {
        case .missingKey: "no API key"
        case .invalidKey: "invalid API key"
        case .overloaded: "overloaded"
        case .rateLimited: "rate limited"
        case let .http(status, _): "error \(status)"
        case .timedOut: "timed out"
        case .offline: "offline"
        case .emptyResponse: "empty answer"
        }
    }
}

/// Client for the Gemini Interactions API (`POST /v1beta/interactions`), streaming
/// server-sent events. Text arrives in `step.delta` events whose `delta.type` is "text".
nonisolated struct GeminiClient: Sendable {
    struct Request: Sendable {
        var model: String
        var system: String?
        var text: String
        var imagesBase64JPEG: [String] = []
        var maxOutputTokens: Int = 2048
        var temperature: Double = 0.3
        /// "low", "medium" or "high"; nil leaves the model default.
        var thinkingLevel: String?
        /// Offer the Google Search tool; the model decides whether to use it.
        var webSearch = false
    }

    enum Event: Sendable, Equatable {
        case thinking
        /// The model ran a Google search.
        case searching
        case text(String)
        case completed(status: String?)
    }

    let apiKey: String
    let session: URLSession
    let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    init(apiKey: String, protocolClasses: [AnyClass]? = nil) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.timeoutIntervalForRequest = 25    // upper bound; each request sets its own
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Request body

    private struct Body: Encodable {
        struct Part: Encodable {
            var type: String
            var text: String?
            var data: String?
            var mime_type: String?
        }
        struct Tool: Encodable { var type: String }
        struct Config: Encodable {
            var max_output_tokens: Int
            var temperature: Double
            var thinking_level: String?
        }
        var model: String
        var input: [Part]
        var system_instruction: String?
        var stream: Bool
        var generation_config: Config
        var tools: [Tool]?
    }

    static func body(for request: Request, stream: Bool) throws -> Data {
        var parts = [Body.Part(type: "text", text: request.text)]
        parts += request.imagesBase64JPEG.map { Body.Part(type: "image", data: $0, mime_type: "image/jpeg") }
        let body = Body(model: request.model, input: parts, system_instruction: request.system, stream: stream,
                        generation_config: .init(max_output_tokens: request.maxOutputTokens, temperature: request.temperature,
                                                 thinking_level: request.thinkingLevel),
                        tools: request.webSearch ? [.init(type: "google_search")] : nil)
        return try JSONEncoder().encode(body)
    }

    // MARK: - Streaming

    private struct Payload: Decodable {
        struct Delta: Decodable { var type: String?; var text: String? }
        struct Step: Decodable { var type: String? }
        struct Interaction: Decodable { var status: String? }
        struct ErrorBody: Decodable { var message: String?; var code: String? }
        var event_type: String?
        var delta: Delta?
        var step: Step?
        var interaction: Interaction?
        var error: ErrorBody?
    }

    func stream(_ request: Request) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw CloudAIError.missingKey }
                    var urlRequest = URLRequest(url: baseURL.appending(path: "interactions").appending(queryItems: [URLQueryItem(name: "alt", value: "sse")]))
                    urlRequest.httpMethod = "POST"
                    // Max silence before failing over; models think quietly for longer on images.
                    urlRequest.timeoutInterval = request.imagesBase64JPEG.isEmpty && !request.webSearch ? 12 : 25
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    urlRequest.httpBody = try Self.body(for: request, stream: true)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw CloudAIError.http(status: 0, message: "No response") }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 8192 { break }
                        }
                        throw Self.error(status: http.statusCode, body: body)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let event = try? decoder.decode(Payload.self, from: data) else { continue }
                        if let error = event.error { throw Self.error(status: 500, message: error.message ?? "Unknown error", code: error.code) }
                        switch event.event_type {
                        case "step.start" where event.step?.type == "thought":
                            continuation.yield(.thinking)
                        case "step.start" where event.step?.type == "google_search_call":
                            continuation.yield(.searching)
                        case "step.delta":
                            if event.delta?.type == "text", let text = event.delta?.text, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                        case "interaction.completed":
                            continuation.yield(.completed(status: event.interaction?.status))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the HTTPS connection ahead of a request so the first answer starts sooner.
    func preconnect() {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }

    /// Collects a whole (short) response as text.
    func generateText(_ request: Request) async throws -> String {
        var output = ""
        for try await event in stream(request) {
            if case let .text(text) = event { output += text }
        }
        return output
    }

    // MARK: - Errors

    static func error(status: Int, body: Data) -> CloudAIError {
        struct Envelope: Decodable { struct E: Decodable { var message: String?; var code: String? }; var error: E }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: body)
        let message = decoded?.error.message ?? String(data: body, encoding: .utf8) ?? "HTTP \(status)"
        return error(status: status, message: message, code: decoded?.error.code)
    }

    static func error(status: Int, message: String, code: String?) -> CloudAIError {
        let lower = message.lowercased() + " " + (code ?? "").lowercased()
        if status == 401 || status == 403 || lower.contains("api key") || lower.contains("unauthenticated") { return .invalidKey(message) }
        if status == 429 || status == 413 || lower.contains("quota") || lower.contains("rate limit")
            || lower.contains("resource_exhausted") || lower.contains("request too large") { return .rateLimited(message) }
        if status == 503 || lower.contains("high demand") || lower.contains("overloaded") || lower.contains("unavailable") { return .overloaded(message) }
        return .http(status: status, message: message.isEmpty ? "HTTP \(status)" : message)
    }

    static func map(_ error: Error) -> Error {
        if error is CloudAIError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return CloudAIError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return CloudAIError.offline
            default: return CloudAIError.http(status: 0, message: urlError.localizedDescription)
            }
        }
        return error
    }
}
