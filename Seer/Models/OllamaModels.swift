import Foundation

nonisolated struct OllamaModelInfo: Decodable, Sendable, Equatable, Hashable, Identifiable {
    struct Details: Decodable, Sendable, Equatable, Hashable {
        var family: String?
        var families: [String]?
        var parameter_size: String?
        var quantization_level: String?
    }

    var name: String
    var size: Int64?
    var details: Details?

    var id: String { name }

    var sizeDescription: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Heuristic used only when `/api/show` capabilities are unavailable.
    var looksVisionCapable: Bool {
        let lower = name.lowercased()
        if lower.contains("vl") || lower.contains("vision") || lower.contains("llava") || lower.contains("gemma3") || lower.contains("minicpm-v") { return true }
        return (details?.families ?? []).contains { $0.lowercased().contains("clip") || $0.lowercased().contains("vl") }
    }
}

nonisolated struct OllamaTagsResponse: Decodable, Sendable {
    var models: [OllamaModelInfo]
}

nonisolated struct OllamaVersionResponse: Decodable, Sendable {
    var version: String
}

nonisolated struct OllamaShowResponse: Decodable, Sendable {
    var capabilities: [String]?
}

nonisolated struct OllamaPSResponse: Decodable, Sendable {
    struct Running: Decodable, Sendable { var name: String; var size_vram: Int64? }
    var models: [Running]
}

nonisolated struct OllamaMessage: Codable, Sendable, Equatable {
    var role: String
    var content: String
    var images: [String]? = nil
    var thinking: String? = nil
}

/// Values that must be identical on every request: Ollama reloads a model whenever the
/// context length changes, which costs seconds per question.
nonisolated enum OllamaDefaults {
    static let contextLength = 8192
    static let keepAlive = "30m"
}

nonisolated struct OllamaChatRequest: Encodable, Sendable {
    struct Options: Encodable, Sendable {
        var num_predict: Int?
        var temperature: Double?
        var num_ctx: Int?
        var top_p: Double?
    }

    var model: String
    var messages: [OllamaMessage]
    var stream: Bool = true
    var think: Bool?
    var keep_alive: String?
    var options: Options?
}

nonisolated struct OllamaChatChunk: Decodable, Sendable {
    var model: String?
    var message: OllamaMessage?
    var done: Bool?
    var done_reason: String?
    var error: String?
}

nonisolated struct OllamaErrorResponse: Decodable, Sendable {
    var error: String
}

nonisolated enum OllamaStatus: Sendable, Equatable {
    case unknown
    case checking
    case connected(version: String, modelCount: Int)
    case unreachable(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unknown: "Ollama: not checked"
        case .checking: "Ollama: checking…"
        case let .connected(version, count): "Ollama \(version) · \(count) model\(count == 1 ? "" : "s")"
        case .unreachable: "Ollama: not running"
        }
    }
}
