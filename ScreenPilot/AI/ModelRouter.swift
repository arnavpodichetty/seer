import Foundation

nonisolated struct ModelChoice: Sendable, Equatable {
    var model: String
    var attachImage: Bool
    var note: String?
}

/// Picks which local model handles a question, falling back gracefully when one is missing.
nonisolated enum ModelRouter {
    /// "qwen3" and "qwen3:latest" refer to the same model.
    static func canonical(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(":") ? trimmed : trimmed + ":latest"
    }

    static func isInstalled(_ name: String, in installed: [String]) -> Bool {
        let target = canonical(name)
        return installed.contains { canonical($0) == target }
    }

    /// The installed model to use for a configured name: the exact model, otherwise a
    /// variant of the same base (e.g. "qwen3:4b-instruct" → "qwen3:4b"), preferring
    /// non-thinking "instruct" variants.
    static func resolve(_ name: String, in installed: [String]) -> String? {
        guard !name.isEmpty else { return nil }
        if let exact = installed.first(where: { canonical($0) == canonical(name) }) { return exact }
        let base = baseName(name)
        let siblings = installed.filter { baseName($0) == base }
        return siblings.first { $0.contains("instruct") } ?? siblings.first { !$0.contains("thinking") } ?? siblings.first
    }

    /// "qwen3:4b-instruct-2507-q4_K_M" → "qwen3:4b"
    static func baseName(_ name: String) -> String {
        let c = canonical(name)
        guard let colon = c.firstIndex(of: ":") else { return c }
        let tag = c[c.index(after: colon)...]
        let size = tag.split(separator: "-").first.map(String.init) ?? String(tag)
        return String(c[..<colon]) + ":" + size
    }

    enum RoutingError: Error, Equatable {
        case noModelInstalled(text: String, vision: String)
    }

    static func choose(mode: ReasoningMode, strategy: ModelStrategy, textModel: String, visionModel: String,
                       installed: [String]) -> Result<ModelChoice, RoutingError> {
        let resolvedText = resolve(textModel, in: installed)
        let resolvedVision = resolve(visionModel, in: installed)
        let hasText = resolvedText != nil
        let hasVision = resolvedVision != nil
        let textModel = resolvedText ?? textModel
        let visionModel = resolvedVision ?? visionModel
        let wantsVision = mode == .vision

        switch strategy {
        case .visionOnly:
            if hasVision { return .success(ModelChoice(model: visionModel, attachImage: wantsVision)) }
            if hasText { return .success(ModelChoice(model: textModel, attachImage: false, note: "Vision model unavailable — using OCR text")) }
        case .textOnly:
            if hasText { return .success(ModelChoice(model: textModel, attachImage: false)) }
            if hasVision { return .success(ModelChoice(model: visionModel, attachImage: false, note: "Text model unavailable — using vision model")) }
        case .automatic:
            if wantsVision {
                if hasVision { return .success(ModelChoice(model: visionModel, attachImage: true)) }
                if hasText { return .success(ModelChoice(model: textModel, attachImage: false, note: "Vision model unavailable — using OCR text only")) }
            } else {
                if hasText { return .success(ModelChoice(model: textModel, attachImage: false)) }
                if hasVision { return .success(ModelChoice(model: visionModel, attachImage: false, note: "Text model unavailable — using vision model")) }
            }
        }
        return .failure(.noModelInstalled(text: textModel, vision: visionModel))
    }
}
