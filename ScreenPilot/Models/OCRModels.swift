import CoreGraphics
import Foundation

nonisolated struct OCRLine: Sendable, Equatable {
    var text: String
    /// Normalized bounding box, top-left origin (0...1 in both axes).
    var box: CGRect
    var confidence: Float
}

nonisolated struct OCRResult: Sendable, Equatable {
    var lines: [OCRLine]
    var imageSize: CGSize

    var fullText: String { lines.map(\.text).joined(separator: "\n") }
    static let empty = OCRResult(lines: [], imageSize: .zero)
}
