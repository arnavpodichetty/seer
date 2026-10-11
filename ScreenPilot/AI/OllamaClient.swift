import Foundation

nonisolated enum OllamaError: LocalizedError, Equatable {
    case notRunning(String)
    case modelNotFound(String)
    case server(status: Int, message: String)
    case outOfMemory(String)
    case invalidResponse
    case timedOut
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case let .notRunning(address): "Can't reach Ollama at \(address)."
        case let .modelNotFound(model): "Model “\(model)” isn't installed."
        case let .server(status, message): "Ollama error (\(status)): \(message)"
        case let .outOfMemory(message): "Not enough memory to run the model. \(message)"
        case .invalidResponse: "Ollama returned an unexpected response."
        case .timedOut: "The model took too long to respond."
        case .emptyResponse: "The model returned an empty answer."
        }
    }

    var recoveryHint: String? {
        switch self {
        case .notRunning: "Start Ollama (open the Ollama app or run `ollama serve`)."
        case let .modelNotFound(model): "Install it with: ollama pull \(model)"
        case .outOfMemory: "Quit memory-heavy apps or choose a smaller model in Settings → AI."
        case .timedOut: "Try “Faster answers” in Settings → AI, or a smaller model."
        default: nil
        }
    }
}

/// Minimal client for Ollama's local HTTP API (`/api/tags`, `/api/chat`, …).
nonisolated struct OllamaClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, idleTimeout: TimeInterval = 120, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.timeoutIntervalForRequest = idleTimeout   // max gap between bytes (covers model load)
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    func version() async throws -> String {
        let data = try await get("api/version", timeout: 4)
        return try JSONDecoder().decode(OllamaVersionResponse.self, from: data).version
    }

    func listModels() async throws -> [OllamaModelInfo] {
        let data = try await get("api/tags", timeout: 6)
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models
    }

    func runningModels() async throws -> [String] {
        let data = try await get("api/ps", timeout: 4)
        return try JSONDecoder().decode(OllamaPSResponse.self, from: data).models.map(\.name)
    }

    func capabilities(of model: String) async throws -> [String]? {
        let data = try await post("api/show", body: ["model": model], timeout: 10)
        return try JSONDecoder().decode(OllamaShowResponse.self, from: data).capabilities
    }

    /// Loads a model into memory ahead of time (an empty chat loads without generating).
    func preload(_ model: String) async {
        let request = OllamaChatRequest(model: model, messages: [], stream: false, keep_alive: OllamaDefaults.keepAlive,
                                        options: .init(num_ctx: OllamaDefaults.contextLength))
        _ = try? await post("api/chat", body: request, timeout: 120)
    }

    /// Asks Ollama to free a model's memory now.
    func unload(_ model: String) async {
        struct Body: Encodable { var model: String; var keep_alive = 0 }
        _ = try? await post("api/generate", body: Body(model: model), timeout: 10)
    }

    /// Streams `/api/chat` NDJSON chunks. Cancelling the consuming task cancels the request.
    func chat(_ request: OllamaChatRequest) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 8192 { break }
                        }
                        throw Self.error(status: http.statusCode, body: body, model: request.model)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try decoder.decode(OllamaChatChunk.self, from: data)
                        if let message = chunk.error { throw Self.error(status: 500, message: message, model: request.model) }
                        continuation.yield(chunk)
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error, address: baseURL.absoluteString))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = timeout
        return try await send(request)
    }

    private func post(_ path: String, body: some Encodable, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
            guard http.statusCode == 200 else { throw Self.error(status: http.statusCode, body: data, model: nil) }
            return data
        } catch {
            throw Self.map(error, address: baseURL.absoluteString)
        }
    }

    private static func error(status: Int, body: Data, model: String?) -> OllamaError {
        let message = (try? JSONDecoder().decode(OllamaErrorResponse.self, from: body).error)
            ?? String(data: body, encoding: .utf8) ?? "HTTP \(status)"
        return error(status: status, message: message, model: model)
    }

    static func error(status: Int, message: String, model: String?) -> OllamaError {
        let lower = message.lowercased()
        if let model, status == 404 || (lower.contains("not found") && lower.contains("model")) {
            return .modelNotFound(model)
        }
        if lower.contains("memory") || lower.contains("out of mem") || lower.contains("insufficient") {
            return .outOfMemory(message)
        }
        return .server(status: status, message: message)
    }

    static func map(_ error: Error, address: String) -> Error {
        if error is OllamaError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return OllamaError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return OllamaError.notRunning(address)
            default: return error
            }
        }
        return error
    }
}
