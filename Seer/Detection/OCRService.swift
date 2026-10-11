import CoreGraphics
import Foundation
import Vision

nonisolated enum OCRError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case let .failed(message): "Text recognition failed: \(message)"
        }
    }
}

/// Apple Vision text recognition, isolated off the main thread, with a small cache
/// keyed by frame signature so revisited screens skip OCR.
actor OCRService {
    private var cache: [(signature: FrameSignature, result: OCRResult)] = []
    private let cacheLimit = 6

    func recognize(_ image: CGImage, signature: FrameSignature?) throws -> OCRResult {
        if let signature, let hit = cache.first(where: { ScreenChangeDetector.compare($0.signature, signature) == .none }) {
            return hit.result
        }
        let result = try Self.runVision(on: image)
        if let signature {
            cache.insert((signature, result), at: 0)
            if cache.count > cacheLimit { cache.removeLast() }
        }
        return result
    }

    func clearCache() { cache.removeAll() }

    /// The first Vision text request on a machine can take tens of seconds while the
    /// recognition models load; run a tiny one up front so the first real frame is fast.
    func warmUp() {
        guard !isWarm else { return }
        isWarm = true
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage() else { return }
        _ = try? Self.runVision(on: image)
    }

    private var isWarm = false

    /// Vision sometimes returns full-width forms ("（2+2）=？") for plain math; map them back to ASCII.
    static func asciiFromFullWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF01...0xFF5E).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFEE0)! : scalar
        }))
    }

    private static let recognitionLanguages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        var languages: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let match = supported.first { $0 == preferred }
                ?? supported.first { $0.split(separator: "-").first == preferred.split(separator: "-").first }
            if let match, !languages.contains(match) { languages.append(match) }
        }
        return languages
    }()

    private static func runVision(on image: CGImage) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Automatic detection sometimes picks Chinese for short math lines, which turns
        // "8 ÷ 2(2 + 2) = ?" into "8-2（2+2）=？". Use the user's languages, plus English.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = recognitionLanguages
        // Vision drops whole lines on some full-resolution Retina captures (2880 px wide) that it reads
        // fine slightly smaller; 2560 px keeps small text legible on large displays.
        let handler = VNImageRequestHandler(cgImage: ImageUtilities.downsample(image, maxDimension: 2560), options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.failed(error.localizedDescription)
        }
        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = asciiFromFullWidth(candidate.string).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = observation.boundingBox
            // Vision uses a bottom-left origin; convert to top-left.
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return OCRLine(text: text, box: box, confidence: candidate.confidence)
        }
        return OCRResult(lines: lines, imageSize: CGSize(width: image.width, height: image.height))
    }
}
