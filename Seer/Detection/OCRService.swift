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

    private static func runVision(on image: CGImage) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.failed(error.localizedDescription)
        }
        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = observation.boundingBox
            // Vision uses a bottom-left origin; convert to top-left.
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return OCRLine(text: text, box: box, confidence: candidate.confidence)
        }
        return OCRResult(lines: lines, imageSize: CGSize(width: image.width, height: image.height))
    }
}
